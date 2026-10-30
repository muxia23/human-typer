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
    var front: Int32? = 1
    var lastInputAt = -100.0
    var cancelled = false
    var overshootMs = 0
    var hooks: [Int: (FakeEnvironment) -> Void] = [:]

    func sendText(_ value: String) {
        log.append("text:\(value)")
        hooks[log.count]?(self)
    }
    func sendBackspace() {
        log.append("backspace")
        hooks[log.count]?(self)
    }
    func sleep(ms: Int) { clock += Double(ms + overshootMs) / 1000 }
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
    #"{"v":1,"cmd":"start","startDelayMs":0,"actions":[{"type":"text","value":"a","style":"bold"}]}"#,
    #"{"v":1,"cmd":"start","startDelayMs":0,"actions":[{"type":"wait","ms":true}]}"#,
    #"{"v":true,"cmd":"cancel"}"#,
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
do {
    let env = FakeEnvironment()
    env.overshootMs = 5
    let waits = StartCommand(startDelayMs: 0, actions: Array(repeating: .wait(20), count: 50))
    check(runTyping(waits, env: env) == .done, "睡眠超时时仍能完成")
    check(env.clock < 1.02, "睡眠超时不会累积拉长总时长")
}
do {
    let env = FakeEnvironment()
    env.front = nil
    check(runTyping(command, env: env) == .stopped(.appSwitched), "读不到前台应用时不打字")
    check(env.log.isEmpty, "读不到前台应用时不发送按键")
}
do {
    let env = FakeEnvironment()
    env.hooks[4] = { $0.lastInputAt = $0.clock + 0.01 }
    check(runTyping(command, env: env) == .done, "全部发送后才有操作时仍算完成")
}

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("all passed")
