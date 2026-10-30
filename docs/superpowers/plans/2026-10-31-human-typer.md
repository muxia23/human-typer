# Human Typer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建 macOS 浏览器插件，通过本地程序发送系统按键，以接近真人的节奏输入文本，并偶尔打错再改正。

**Architecture:** 插件的 `planner.js` 把文本转成动作序列，后台脚本通过 Native Messaging 交给 Swift 本地程序。本地程序校验协议后逐条发送系统按键，并在用户操作或切换应用时停止。协议和 planner 输入结构为后续的格式升级预留扩展。

**Tech Stack:** Chrome Manifest V3、JavaScript（ES Modules）、Node 内置测试、Swift 6.3 工具链（Swift 5 语言模式）、CoreGraphics、AppKit。本机 `swiftc` 无法直接导入 XCTest，host 测试使用独立的测试可执行文件。

**Spec:** `docs/superpowers/specs/2026-10-31-human-typer-design.md`

---

## 文件结构

```
human-typer/
├── .gitignore
├── package.json              # Node 测试入口
├── install.sh                # 编译、签名、注册本地程序
├── extension/
│   ├── manifest.json         # MV3 清单，含固定 key
│   ├── extension-id.txt      # 由 key 计算出的扩展 ID，供 install.sh 读取
│   ├── planner.js            # 文本 → 动作序列（纯函数）
│   ├── background.js         # 连接本地程序，记录状态
│   ├── popup.html
│   ├── popup.css
│   └── popup.js
├── host/
│   ├── Core.swift            # 协议、分帧、运行逻辑（不依赖系统按键）
│   ├── main.swift            # 真实环境实现和程序入口
│   └── tests/main.swift      # Core 的测试
└── tests/
    ├── planner.test.js
    └── manual/test.html      # 真实环境测试页
```

---

### Task 1: 初始化项目

**Files:**
- Create: `.gitignore`, `package.json`

- [ ] **Step 1: 初始化 git 并写入配置**

```bash
cd ~/human-typer && git init -b main
```

`.gitignore`：

```gitignore
build/
node_modules/
```

`package.json`：

```json
{
  "name": "human-typer",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test tests/planner.test.js"
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore package.json docs
git commit -m "chore: initialize project with design docs"
```

---

### Task 2: planner

**Files:**
- Create: `extension/planner.js`
- Test: `tests/planner.test.js`

- [ ] **Step 1: 写失败的测试**

`tests/planner.test.js`：

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { plan, textToDoc } from '../extension/planner.js';

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const graphemes = (s) => Array.from(segmenter.segment(s), (x) => x.segment);

function simulate(actions) {
  const buffer = [];
  for (const action of actions) {
    if (action.type === 'text') buffer.push(...graphemes(action.value));
    if (action.type === 'key') buffer.pop();
  }
  return buffer.join('');
}

const DEFAULTS = { wpm: 60, errorRate: 0.03, pauseStrength: 1, seed: 1 };
const mixed = 'Hello, world!\n今天在公司做演示，效果很好。\n\nEmoji 👨‍👩‍👧 ok';

test('textToDoc 按换行拆分段落，每段一个无样式片段', () => {
  assert.deepEqual(textToDoc('a\r\nb'), {
    paragraphs: [{ runs: [{ text: 'a' }] }, { runs: [{ text: 'b' }] }],
  });
});

test('多个种子下最终文本都与原文一致', () => {
  for (let seed = 0; seed < 200; seed += 1) {
    const actions = plan(textToDoc(mixed), { ...DEFAULTS, errorRate: 0.3, seed });
    assert.equal(simulate(actions), mixed);
  }
});

test('相同种子结果相同，不同种子结果不同', () => {
  const doc = textToDoc(mixed);
  assert.deepEqual(plan(doc, DEFAULTS), plan(doc, DEFAULTS));
  assert.notDeepEqual(plan(doc, DEFAULTS), plan(doc, { ...DEFAULTS, seed: 2 }));
});

test('出错率为 0 时没有退格', () => {
  const actions = plan(textToDoc(mixed), { ...DEFAULTS, errorRate: 0 });
  assert.equal(actions.some((a) => a.type === 'key'), false);
});

test('实测速度接近设定值', () => {
  const actions = plan(textToDoc('a'.repeat(5000)), {
    ...DEFAULTS, errorRate: 0, pauseStrength: 0,
  });
  const totalMs = actions
    .filter((a) => a.type === 'wait')
    .reduce((sum, a) => sum + a.ms, 0);
  const wpm = (5000 / 5) / (totalMs / 60000);
  assert.ok(Math.abs(wpm - 60) < 3, `wpm=${wpm}`);
});

test('实测出错率接近设定值', () => {
  const text = 'the quick brown fox '.repeat(500);
  const actions = plan(textToDoc(text), { ...DEFAULTS, errorRate: 0.1 });
  let mistakes = 0;
  let previous = null;
  for (const action of actions) {
    if (action.type === 'wait') continue;
    if (action.type === 'key' && previous !== 'key') mistakes += 1;
    previous = action.type;
  }
  const rate = mistakes / 8000;
  assert.ok(rate > 0.05 && rate < 0.12, `rate=${rate}`);
});

test('退格动作符合协议结构', () => {
  const actions = plan(textToDoc('the quick brown fox'), {
    ...DEFAULTS, errorRate: 1,
  });
  const backspace = actions.find((a) => a.type === 'key');
  assert.deepEqual(backspace, { type: 'key', key: 'backspace', modifiers: [] });
});

test('出错和退格不跨样式片段', () => {
  const doc = { paragraphs: [{ runs: [{ text: 'abc' }, { text: '在在在在' }] }] };
  for (let seed = 0; seed < 100; seed += 1) {
    const actions = plan(doc, { ...DEFAULTS, errorRate: 1, seed });
    const firstHan = actions.findIndex((a) => a.type === 'text' && /\p{Script=Han}/u.test(a.value));
    assert.equal(simulate(actions.slice(0, firstHan)), 'abc');
    assert.equal(simulate(actions), 'abc在在在在');
  }
});
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `npm test`
Expected: FAIL，提示找不到 `extension/planner.js`

- [ ] **Step 3: 实现 planner**

`extension/planner.js`：

```js
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const graphemes = (s) => Array.from(segmenter.segment(s), (x) => x.segment);

const HAN = /^\p{Script=Han}$/u;
const LETTER = /^[a-zA-Z]$/;
const PUNCTUATION = /^[,.;:!?，。；：！？、]$/;
const SIGMA = 0.35;
const THINK_CHANCE = 0.02;

const ADJACENT = {
  a: 'qwsz', b: 'vghn', c: 'xdfv', d: 'serfcx', e: 'wsdr', f: 'drtgvc',
  g: 'ftyhbv', h: 'gyujnb', i: 'ujko', j: 'huikmn', k: 'jiolm', l: 'kop',
  m: 'njk', n: 'bhjm', o: 'iklp', p: 'ol', q: 'wa', r: 'edft', s: 'awedxz',
  t: 'rfgy', u: 'yhji', v: 'cfgb', w: 'qase', x: 'zsdc', y: 'tghu', z: 'asx',
};

const HOMOPHONES = {
  在: '再', 再: '在', 的: '得', 得: '的', 他: '她', 她: '他', 做: '作', 作: '做',
  已: '以', 以: '已', 那: '哪', 哪: '那', 是: '事', 事: '是', 时: '十', 和: '合',
  有: '又', 又: '有', 到: '道', 道: '到', 见: '件', 件: '见', 进: '近', 近: '进',
  果: '过', 过: '果', 很: '狠', 好: '号', 天: '田', 今: '金', 公: '工', 工: '公',
  司: '思', 演: '眼', 示: '是', 效: '校',
};

function createRng(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function sampleDelay(meanMs, rng) {
  const normal = Math.sqrt(-2 * Math.log(1 - rng())) * Math.cos(2 * Math.PI * rng());
  const mu = Math.log(meanMs) - (SIGMA * SIGMA) / 2;
  return Math.max(1, Math.round(Math.exp(mu + SIGMA * normal)));
}

function toUnits(text, rng) {
  const units = [];
  const chars = graphemes(text);
  let i = 0;
  while (i < chars.length) {
    if (!HAN.test(chars[i])) {
      units.push(chars[i]);
      i += 1;
      continue;
    }
    const size = 2 + Math.floor(rng() * 3);
    let group = '';
    for (let n = 0; n < size && i < chars.length && HAN.test(chars[i]); n += 1) {
      group += chars[i];
      i += 1;
    }
    units.push(group);
  }
  return units;
}

function canMistake(unit) {
  return LETTER.test(unit) || graphemes(unit).some((c) => HOMOPHONES[c]);
}

function makeMistake(units, i, rng) {
  const unit = units[i];
  if (!LETTER.test(unit)) {
    const chars = graphemes(unit);
    const at = chars.findIndex((c) => HOMOPHONES[c]);
    chars[at] = HOMOPHONES[chars[at]];
    return { typed: [chars.join('')], consumed: 1 };
  }
  const next = units[i + 1];
  if (next && LETTER.test(next) && next.toLowerCase() !== unit.toLowerCase() && rng() < 0.25) {
    return { typed: [next, unit], consumed: 2 };
  }
  const options = ADJACENT[unit.toLowerCase()];
  const wrong = options[Math.floor(rng() * options.length)];
  return { typed: [unit === unit.toUpperCase() ? wrong.toUpperCase() : wrong], consumed: 1 };
}

function createWriter(options, rng) {
  const meanMs = 60000 / (options.wpm * 5);
  const actions = [];
  const wait = (ms) => {
    if (ms > 0) actions.push({ type: 'wait', ms: Math.round(ms) });
  };

  const type = (value) => {
    wait(sampleDelay(meanMs * graphemes(value).length, rng));
    actions.push({ type: 'text', value });
  };

  const pauseAfter = (value) => {
    const last = graphemes(value).at(-1);
    if (PUNCTUATION.test(last)) wait(meanMs * 2 * options.pauseStrength);
    if ((last === ' ' || HAN.test(last)) && rng() < THINK_CHANCE * options.pauseStrength) {
      wait(800 + rng() * 600);
    }
  };

  const backspace = (count) => {
    for (let n = 0; n < count; n += 1) {
      wait(sampleDelay(meanMs * 0.6, rng));
      actions.push({ type: 'key', key: 'backspace', modifiers: [] });
    }
  };

  return { actions, wait, type, pauseAfter, backspace, meanMs };
}

function planRun(text, writer, options, rng) {
  const units = toUnits(text, rng);
  let i = 0;
  let safeUntil = 0;
  while (i < units.length) {
    if (i >= safeUntil && canMistake(units[i]) && rng() < options.errorRate) {
      const { typed, consumed } = makeMistake(units, i, rng);
      let wrongCount = 0;
      for (const value of typed) {
        writer.type(value);
        wrongCount += graphemes(value).length;
      }
      let j = i + consumed;
      const extra = Math.floor(rng() * 4);
      for (let n = 0; n < extra && j < units.length; n += 1) {
        writer.type(units[j]);
        wrongCount += graphemes(units[j]).length;
        j += 1;
      }
      writer.wait(300 + rng() * 500);
      writer.backspace(wrongCount);
      safeUntil = j;
      continue;
    }
    writer.type(units[i]);
    writer.pauseAfter(units[i]);
    i += 1;
  }
}

export function textToDoc(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  return { paragraphs: lines.map((line) => ({ runs: [{ text: line }] })) };
}

export function plan(doc, options) {
  const rng = createRng(options.seed);
  const writer = createWriter(options, rng);
  doc.paragraphs.forEach((paragraph, index) => {
    if (index > 0) {
      writer.type('\n');
      writer.wait(writer.meanMs * 4 * options.pauseStrength);
    }
    for (const run of paragraph.runs) planRun(run.text, writer, options, rng);
  });
  return writer.actions;
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `npm test`
Expected: 8 个测试全部 PASS。如果速度或出错率断言失败，先打印实测值再调整实现，不要放宽断言。

- [ ] **Step 5: Commit**

```bash
git add extension/planner.js tests/planner.test.js
git commit -m "feat: add typing action planner"
```

---

### Task 3: host 核心逻辑

**Files:**
- Create: `host/Core.swift`
- Test: `host/tests/main.swift`

- [ ] **Step 1: 写失败的测试**

`host/tests/main.swift`：

```swift
import Foundation

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok - \(name)")
    } else {
        failures += 1
        print("FAIL - \(name)")
    }
}

final class FakeEnvironment: TypingEnvironment {
    var clock = 0.0
    var log: [String] = []
    var front: Int32 = 1
    var lastInputAt = -100.0
    var cancelled = false
    var hooks: [Int: (FakeEnvironment) -> Void] = [:]

    func sendText(_ value: String) {
        log.append("text:\(value)")
        hooks[log.count]?(self)
    }
    func sendBackspace() {
        log.append("backspace")
        hooks[log.count]?(self)
    }
    func sleep(ms: Int) { clock += Double(ms) / 1000 }
    func frontmostPID() -> Int32? { front }
    func secondsSinceUserInput() -> Double { clock - lastInputAt }
    func now() -> Double { clock }
}

func data(_ json: String) -> Data { json.data(using: .utf8)! }

let validStart = #"{"v":1,"cmd":"start","startDelayMs":5000,"actions":[{"type":"text","value":"H"},{"type":"wait","ms":120},{"type":"key","key":"backspace","modifiers":[]}]}"#

check(
    (try? parseCommand(data(validStart))) == .start(StartCommand(
        startDelayMs: 5000,
        actions: [.text("H"), .wait(120), .backspace]
    )),
    "解析合法的 start 命令"
)
check((try? parseCommand(data(#"{"v":1,"cmd":"cancel"}"#))) == .cancel, "解析 cancel 命令")

let invalid = [
    #"{"v":2,"cmd":"cancel"}"#,
    #"{"v":1,"cmd":"start","startDelayMs":0,"actions":[{"type":"style","value":"bold"}]}"#,
    #"{"v":1,"cmd":"start","startDelayMs":0,"actions":[{"type":"key","key":"b","modifiers":["cmd"]}]}"#,
    #"{"v":1,"cmd":"start","startDelayMs":0,"actions":[{"type":"key","key":"backspace","modifiers":["cmd"]}]}"#,
    "not json",
]
for json in invalid {
    check((try? parseCommand(data(json))) == nil, "拒绝不支持的内容: \(json)")
}

let pipe = Pipe()
let payload = data(#"{"v":1,"event":"done"}"#)
pipe.fileHandleForWriting.write(encodeFrame(payload))
pipe.fileHandleForWriting.closeFile()
check(readFrame(pipe.fileHandleForReading) == payload, "分帧编码后可读回")
check(readFrame(pipe.fileHandleForReading) == nil, "EOF 时返回 nil")

let command = StartCommand(
    startDelayMs: 1000,
    actions: [.text("a"), .wait(100), .text("b"), .backspace, .text("c")]
)

do {
    let env = FakeEnvironment()
    check(runTyping(command, env: env) == .done, "正常完成")
    check(env.log == ["text:a", "text:b", "backspace", "text:c"], "动作按顺序执行")
    check(env.clock >= 1.1, "启动延迟和等待都生效")
}
do {
    let env = FakeEnvironment()
    env.lastInputAt = 0.5
    check(runTyping(command, env: env) == .done, "倒计时内点击输入框不触发停止")
}
do {
    let env = FakeEnvironment()
    env.hooks[1] = { $0.front = 2 }
    check(runTyping(command, env: env) == .stopped(.appSwitched), "切换应用后停止")
    check(env.log == ["text:a"], "切换应用后不再发送按键")
}
do {
    let env = FakeEnvironment()
    env.hooks[1] = { $0.lastInputAt = $0.clock + 0.01 }
    check(runTyping(command, env: env) == .stopped(.userInput), "真实操作后停止")
    check(env.log == ["text:a"], "真实操作后不再发送按键")
}
do {
    let env = FakeEnvironment()
    env.hooks[1] = { $0.cancelled = true }
    check(runTyping(command, env: env) == .stopped(.userCancel), "取消后停止")
}
do {
    let env = FakeEnvironment()
    env.cancelled = true
    check(runTyping(command, env: env) == .stopped(.userCancel), "倒计时内取消")
    check(env.log.isEmpty, "倒计时内取消时不发送按键")
}

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("all passed")
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `mkdir -p build && swiftc host/tests/main.swift host/Core.swift -o build/host-tests`
Expected: 编译失败，提示 `host/Core.swift` 不存在

- [ ] **Step 3: 实现核心逻辑**

`host/Core.swift`：

```swift
import Foundation

enum Action: Equatable {
    case text(String)
    case wait(Int)
    case backspace
}

struct StartCommand: Equatable {
    let startDelayMs: Int
    let actions: [Action]
}

enum Command: Equatable {
    case start(StartCommand)
    case cancel
}

enum ProtocolError: Error {
    case unsupported
}

enum StopReason: String, Equatable {
    case appSwitched = "app_switched"
    case userInput = "user_input"
    case userCancel = "user_cancel"
}

enum RunResult: Equatable {
    case done
    case stopped(StopReason)
}

protocol TypingEnvironment {
    var cancelled: Bool { get }
    func sendText(_ value: String)
    func sendBackspace()
    func sleep(ms: Int)
    func frontmostPID() -> Int32?
    func secondsSinceUserInput() -> Double
    func now() -> Double
}

private func parseAction(_ raw: Any) throws -> Action {
    guard let object = raw as? [String: Any], let type = object["type"] as? String else {
        throw ProtocolError.unsupported
    }
    switch type {
    case "text":
        guard let value = object["value"] as? String, !value.isEmpty else {
            throw ProtocolError.unsupported
        }
        return .text(value)
    case "wait":
        guard let ms = object["ms"] as? Int, ms >= 0 else {
            throw ProtocolError.unsupported
        }
        return .wait(ms)
    case "key":
        guard object["key"] as? String == "backspace",
              let modifiers = object["modifiers"] as? [Any], modifiers.isEmpty else {
            throw ProtocolError.unsupported
        }
        return .backspace
    default:
        throw ProtocolError.unsupported
    }
}

func parseCommand(_ data: Data) throws -> Command {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["v"] as? Int == 1,
          let cmd = object["cmd"] as? String else {
        throw ProtocolError.unsupported
    }
    switch cmd {
    case "cancel":
        return .cancel
    case "start":
        guard let startDelayMs = object["startDelayMs"] as? Int, startDelayMs >= 0,
              let rawActions = object["actions"] as? [Any] else {
            throw ProtocolError.unsupported
        }
        return .start(StartCommand(
            startDelayMs: startDelayMs,
            actions: try rawActions.map(parseAction)
        ))
    default:
        throw ProtocolError.unsupported
    }
}

func encodeFrame(_ payload: Data) -> Data {
    var length = UInt32(payload.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    return frame
}

func readFrame(_ handle: FileHandle) -> Data? {
    guard let header = readExactly(handle, count: 4) else { return nil }
    let length = header.reduce(UInt32(0)) { partial, byte in partial >> 8 | UInt32(byte) << 24 }
    return readExactly(handle, count: Int(length))
}

private func readExactly(_ handle: FileHandle, count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        guard let chunk = try? handle.read(upToCount: count - result.count), !chunk.isEmpty else {
            return nil
        }
        result.append(chunk)
    }
    return result
}

private let sliceMs = 20

func runTyping(_ command: StartCommand, env: TypingEnvironment) -> RunResult {
    var remaining = command.startDelayMs
    while remaining > 0 {
        if env.cancelled { return .stopped(.userCancel) }
        let slice = min(sliceMs, remaining)
        env.sleep(ms: slice)
        remaining -= slice
    }

    let targetPID = env.frontmostPID()
    let startedAt = env.now()

    func stopReason() -> StopReason? {
        if env.cancelled { return .userCancel }
        if env.frontmostPID() != targetPID { return .appSwitched }
        if env.secondsSinceUserInput() < env.now() - startedAt { return .userInput }
        return nil
    }

    for action in command.actions {
        if let reason = stopReason() { return .stopped(reason) }
        switch action {
        case .text(let value):
            env.sendText(value)
        case .backspace:
            env.sendBackspace()
        case .wait(let ms):
            var left = ms
            while left > 0 {
                let slice = min(sliceMs, left)
                env.sleep(ms: slice)
                left -= slice
                if let reason = stopReason() { return .stopped(reason) }
            }
        }
    }
    return stopReason().map(RunResult.stopped) ?? .done
}
```

- [ ] **Step 4: 编译并运行测试，确认通过**

Run: `swiftc host/tests/main.swift host/Core.swift -o build/host-tests && build/host-tests`
Expected: 所有行为 `ok`，最后输出 `all passed`

- [ ] **Step 5: Commit**

```bash
git add host/Core.swift host/tests/main.swift
git commit -m "feat: add native host protocol and typing runner"
```

---

### Task 4: host 程序入口和安装脚本

**Files:**
- Create: `host/main.swift`, `install.sh`, `extension/manifest.json`, `extension/extension-id.txt`

- [ ] **Step 1: 实现真实环境和入口**

`host/main.swift`：

```swift
import AppKit
import ApplicationServices
import Foundation

private let returnKeyCode: CGKeyCode = 36
private let backspaceKeyCode: CGKeyCode = 51

final class SystemEnvironment: TypingEnvironment {
    private let source = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var isCancelled = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    private func post(keyCode: CGKeyCode, text: String? = nil) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            event.flags = []
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    func sendText(_ value: String) {
        if value == "\n" {
            post(keyCode: returnKeyCode)
        } else {
            post(keyCode: 0, text: value)
        }
    }

    func sendBackspace() {
        post(keyCode: backspaceKeyCode)
    }

    // 泵主线程 RunLoop，否则 NSWorkspace 的前台应用信息不会更新
    func sleep(ms: Int) {
        RunLoop.main.run(until: Date().addingTimeInterval(Double(ms) / 1000))
    }

    func frontmostPID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
    }

    func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

func send(_ message: [String: Any]) {
    var body = message
    body["v"] = 1
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
    try? FileHandle.standardOutput.write(contentsOf: encodeFrame(payload))
}

signal(SIGPIPE, SIG_IGN)

let input = FileHandle.standardInput
guard let firstFrame = readFrame(input) else { exit(0) }
guard let firstCommand = try? parseCommand(firstFrame) else {
    send(["event": "error", "code": "unsupported_protocol"])
    exit(1)
}
guard case .start(let startCommand) = firstCommand else { exit(0) }

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
    send(["event": "error", "code": "no_accessibility_permission"])
    exit(1)
}

let environment = SystemEnvironment()
let reader = Thread {
    while let frame = readFrame(input) {
        if (try? parseCommand(frame)) == .cancel { break }
    }
    environment.cancel()
}
reader.start()

switch runTyping(startCommand, env: environment) {
case .done:
    send(["event": "done"])
case .stopped(let reason):
    send(["event": "stopped", "reason": reason.rawValue])
}
exit(0)
```

- [ ] **Step 2: 写插件清单并生成固定 ID**

`extension/manifest.json`：

```json
{
  "manifest_version": 3,
  "name": "Human Typer",
  "version": "0.1.0",
  "description": "以接近真人的节奏输入文本，用于演示和录屏。",
  "permissions": ["nativeMessaging", "storage"],
  "background": { "service_worker": "background.js", "type": "module" },
  "action": { "default_popup": "popup.html" }
}
```

运行以下命令，写入 `key` 并生成 `extension/extension-id.txt`（私钥不保存，本项目不需要打包发布）：

```bash
node -e "
const c=require('crypto'),fs=require('fs');
const {publicKey}=c.generateKeyPairSync('rsa',{modulusLength:2048});
const der=publicKey.export({type:'spki',format:'der'});
const m=JSON.parse(fs.readFileSync('extension/manifest.json'));
m.key=der.toString('base64');
fs.writeFileSync('extension/manifest.json',JSON.stringify(m,null,2)+'\n');
const id=[...c.createHash('sha256').update(der).digest('hex').slice(0,32)].map(h=>String.fromCharCode(97+parseInt(h,16))).join('');
fs.writeFileSync('extension/extension-id.txt',id+'\n');
"
cat extension/extension-id.txt
```

Expected: 输出 32 个 `a` 到 `p` 之间的小写字母。

- [ ] **Step 3: 写安装脚本**

`install.sh`：

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="$ROOT/build/human-typer-host"
EXTENSION_ID="$(tr -d '[:space:]' < "$ROOT/extension/extension-id.txt")"
HOST_NAME="com.humantyper.host"

mkdir -p "$ROOT/build"
swiftc -O "$ROOT/host/main.swift" "$ROOT/host/Core.swift" -o "$BINARY"
codesign --force --sign - --identifier "$HOST_NAME" "$BINARY"

register() {
  local browser_dir="$1"
  [ -d "$browser_dir" ] || return 0
  mkdir -p "$browser_dir/NativeMessagingHosts"
  cat > "$browser_dir/NativeMessagingHosts/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Human Typer native host",
  "path": "$BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF
  echo "registered: $browser_dir"
}

register "$HOME/Library/Application Support/Google/Chrome"
register "$HOME/Library/Application Support/Arc/User Data"
```

- [ ] **Step 4: 安装并验证协议路径**

```bash
chmod +x install.sh && ./install.sh
node -e "
const b=Buffer.from('{\"v\":2,\"cmd\":\"cancel\"}');const h=Buffer.alloc(4);h.writeUInt32LE(b.length);
process.stdout.write(Buffer.concat([h,b]));
" | build/human-typer-host | tail -c +5
```

Expected: 显示已注册 Chrome 和 Arc，最后输出包含 `"code":"unsupported_protocol"` 的 JSON。

- [ ] **Step 5: Commit**

```bash
git add host/main.swift install.sh extension/manifest.json extension/extension-id.txt
git commit -m "feat: add native host entrypoint and installer"
```

---

### Task 5: 插件后台脚本和弹窗

**Files:**
- Create: `extension/background.js`, `extension/popup.html`, `extension/popup.css`, `extension/popup.js`

- [ ] **Step 1: 实现后台脚本**

`extension/background.js`：

```js
import { plan, textToDoc } from './planner.js';

const HOST_NAME = 'com.humantyper.host';
const START_DELAY_MS = 5000;

let port = null;

function setStatus(status) {
  return chrome.storage.local.set({ status });
}

// 本地连接会让后台脚本保持存活，脚本重新启动说明之前的任务已不在运行
chrome.storage.local.get('status').then(({ status }) => {
  if (status?.state === 'running' && !port) setStatus({ state: 'idle' });
});

function start({ text, settings }) {
  if (port) return;
  const actions = plan(textToDoc(text), {
    ...settings,
    seed: Math.floor(Math.random() * 2 ** 32),
  });
  const current = chrome.runtime.connectNative(HOST_NAME);
  port = current;
  let finished = false;

  current.onMessage.addListener((message) => {
    finished = true;
    if (message.event === 'done') setStatus({ state: 'done' });
    if (message.event === 'stopped') setStatus({ state: 'stopped', reason: message.reason });
    if (message.event === 'error') setStatus({ state: 'error', code: message.code });
  });

  current.onDisconnect.addListener(() => {
    port = null;
    if (!finished) setStatus({ state: 'error', code: 'host_unavailable' });
  });

  current.postMessage({ v: 1, cmd: 'start', startDelayMs: START_DELAY_MS, actions });
  setStatus({ state: 'running' });
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === 'start') start(message);
  if (message.type === 'cancel') port?.postMessage({ v: 1, cmd: 'cancel' });
});
```

- [ ] **Step 2: 实现弹窗**

`extension/popup.html`：

```html
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8" />
    <link rel="stylesheet" href="popup.css" />
  </head>
  <body>
    <textarea id="text" rows="8" placeholder="粘贴要输入的文本"></textarea>
    <label>速度 <output id="wpmValue"></output> WPM
      <input id="wpm" type="range" min="20" max="150" step="5" />
    </label>
    <label>出错率 <output id="errorValue"></output>%
      <input id="error" type="range" min="0" max="15" step="1" />
    </label>
    <label>停顿强度 <output id="pauseValue"></output>
      <input id="pause" type="range" min="0" max="2" step="0.5" />
    </label>
    <div class="actions">
      <button id="start">开始</button>
      <button id="cancel">取消</button>
    </div>
    <p id="status" role="status"></p>
    <script type="module" src="popup.js"></script>
  </body>
</html>
```

`extension/popup.css`：

```css
body { width: 320px; margin: 12px; font: 13px system-ui, sans-serif; }
textarea { box-sizing: border-box; width: 100%; resize: vertical; }
label { display: block; margin-top: 10px; }
input[type="range"] { display: block; width: 100%; }
.actions { display: flex; gap: 8px; margin-top: 12px; }
button { flex: 1; padding: 6px; }
#status { min-height: 1.4em; margin: 10px 0 0; }
```

`extension/popup.js`：

```js
const $ = (id) => document.getElementById(id);
const DEFAULTS = { text: '', wpm: 60, error: 3, pause: 1 };

const STATUS_TEXT = {
  running: '已开始：请在 5 秒内点进目标输入框，之后不要操作键盘和鼠标。',
  done: '已完成。',
};
const REASON_TEXT = {
  app_switched: '已停止：前台应用发生变化。',
  user_input: '已停止：检测到键盘或鼠标操作。',
  user_cancel: '已取消。',
};
const ERROR_TEXT = {
  no_accessibility_permission: '缺少权限：请在系统设置的“辅助功能”中允许后重试。',
  host_unavailable: '无法连接本地程序：请运行 install.sh 后重试。',
  unsupported_protocol: '本地程序版本不匹配：请重新运行 install.sh。',
};

function renderStatus(status) {
  if (!status) return;
  $('status').textContent = STATUS_TEXT[status.state]
    ?? REASON_TEXT[status.reason]
    ?? ERROR_TEXT[status.code]
    ?? '';
  const running = status.state === 'running';
  $('start').disabled = running;
  $('cancel').disabled = !running;
}

function renderValues() {
  $('wpmValue').textContent = $('wpm').value;
  $('errorValue').textContent = $('error').value;
  $('pauseValue').textContent = $('pause').value;
}

function save() {
  renderValues();
  chrome.storage.local.set({
    settings: {
      text: $('text').value,
      wpm: Number($('wpm').value),
      error: Number($('error').value),
      pause: Number($('pause').value),
    },
  });
}

const { settings, status } = await chrome.storage.local.get(['settings', 'status']);
const initial = { ...DEFAULTS, ...settings };
$('text').value = initial.text;
$('wpm').value = initial.wpm;
$('error').value = initial.error;
$('pause').value = initial.pause;
renderValues();
renderStatus(status ?? { state: 'idle' });

for (const id of ['text', 'wpm', 'error', 'pause']) {
  $(id).addEventListener('input', save);
}

$('start').addEventListener('click', () => {
  const text = $('text').value;
  if (!text) {
    $('status').textContent = '请先输入文本。';
    return;
  }
  chrome.runtime.sendMessage({
    type: 'start',
    text,
    settings: {
      wpm: Number($('wpm').value),
      errorRate: Number($('error').value) / 100,
      pauseStrength: Number($('pause').value),
    },
  });
});

$('cancel').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'cancel' });
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.status) renderStatus(changes.status.newValue);
});
```

- [ ] **Step 3: 确认语法正确且没有回归**

Run: `node --check extension/background.js && node --check extension/popup.js && npm test`
Expected: 无语法错误，8 个测试 PASS

- [ ] **Step 4: Commit**

```bash
git add extension/background.js extension/popup.html extension/popup.css extension/popup.js
git commit -m "feat: add extension popup and background worker"
```

---

### Task 6: 真实环境验证

需要用户在场：加载插件、授予辅助功能权限，并在打字过程中配合操作。

**Files:**
- Create: `tests/manual/test.html`

- [ ] **Step 1: 写测试页**

`tests/manual/test.html`：

```html
<!doctype html>
<html lang="zh-CN">
  <head><meta charset="utf-8" /><title>Human Typer 测试页</title></head>
  <body>
    <p><input id="input" size="60" placeholder="input" /></p>
    <p><textarea id="textarea" rows="6" cols="60" placeholder="textarea"></textarea></p>
    <div id="editable" contenteditable="true" style="border:1px solid #888;min-height:6em;padding:4px"></div>
  </body>
</html>
```

- [ ] **Step 2: 用户加载插件并授权**

1. 在 `chrome://extensions` 打开开发者模式，选择“加载已解压的扩展程序”，选中 `~/human-typer/extension`。
2. 确认显示的扩展 ID 与 `extension/extension-id.txt` 一致。
3. 打开测试页，第一次点开始时按系统提示授予“辅助功能”权限，然后重试。
4. 记录系统设置中被授权的主体是 `human-typer-host` 还是 Chrome，写入 `WORKLOG.md`。

- [ ] **Step 3: 逐项验证**

测试文本：

```text
Hello, world! This is a demo.
今天在公司做演示，效果很好。
```

| 场景 | 预期 |
|---|---|
| `input`（只输入第一行） | 文本正确，能看到打错再改正 |
| `textarea` | 两行文本都正确 |
| `contenteditable` | 两行文本都正确 |
| Google Docs | 两行文本都正确 |
| 打字中切到其他应用 | 立即停止，状态显示前台应用变化 |
| 打字中按一个键 | 立即停止，状态显示检测到操作 |
| 打字中点击鼠标 | 立即停止，状态显示检测到操作 |
| 倒计时内点取消 | 不输入任何字符，状态显示已取消 |
| 中文输入法开启时输入 | 文本正确，或记录下实际行为 |

**重点风险：** 如果刚开始打字就显示“检测到键盘或鼠标操作”，说明模拟按键被 `hidSystemState` 计入了。此时不要关闭该检测，按 superpowers:systematic-debugging 排查，并把结论写入 spec。

- [ ] **Step 4: 记录结果并提交**

把结果和发现的限制写入 `WORKLOG.md`，有偏差时同步更新 spec。

```bash
git add tests/manual/test.html docs
git commit -m "test: add manual verification page"
```

---

### Task 7: 更新索引

**Files:**
- Modify: `CLAUDE.md`、`WORKLOG.md`（均被全局 gitignore，不提交）、`~/kb/projects.md`

- [ ] **Step 1: 更新项目 `CLAUDE.md`**

把 Structure 更新为本计划的文件结构，并在 Notes 写明运行方式：`./install.sh` 安装本地程序，`npm test` 和 `swiftc host/tests/main.swift host/Core.swift -o build/host-tests && build/host-tests` 运行测试。

- [ ] **Step 2: 在 `~/kb/projects.md` 添加一行并提交**

```markdown
| human-typer | `~/human-typer` | 演示和录屏用的拟人打字插件（Chrome/Arc 扩展 + Swift 本地程序） |
```

```bash
git -C ~/kb add projects.md
git -C ~/kb commit -m "docs: add human-typer to project index"
```
