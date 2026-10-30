// 端到端测试：向独立的临时 Chrome 发送真实按键。运行期间不要操作键盘和鼠标。
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { plan, textToDoc } from '../../extension/planner.js';

const ROOT = new URL('../..', import.meta.url).pathname;
const HOST = join(ROOT, 'build/human-typer-host');
const HELPER = join(ROOT, 'build/e2e-helper');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const ABC = 'com.apple.keylayout.ABC';
const PINYIN = 'com.apple.inputmethod.SCIM.ITABC';

const LINE = 'Hello, world! This is a demo.';
const TEXT = `${LINE}\n今天在公司做演示，效果很好。`;
const OPTIONS = { wpm: 200, errorRate: 0.1, pauseStrength: 0.2 };

const PAGE = `<!doctype html><meta charset="utf-8"><title>e2e</title>
<input id="input" size="60"><br><textarea id="textarea" rows="4" cols="60"></textarea>
<div id="editable" contenteditable="true" style="border:1px solid #888;min-height:5em"></div>
<div style="height:300px"></div>
<script>
let id = 0, target = null;
const read = (t) => t.id === 'editable' ? t.innerText : t.value;
async function tick() {
  const { commandId, name } = await (await fetch('/command')).json();
  if (commandId !== id) {
    id = commandId;
    target = document.getElementById(name);
    if (target.id === 'editable') target.textContent = ''; else target.value = '';
  }
  if (target && document.activeElement !== target) target.focus();
  await fetch('/state', { method: 'POST', body: JSON.stringify({
    commandId: id,
    focused: document.hasFocus() && document.activeElement === target,
    value: target ? read(target) : '',
    clickX: Math.round(screenX + innerWidth / 2),
    clickY: Math.round(screenY + outerHeight - 40),
  }) });
}
setInterval(tick, 50);
</script>`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const helper = (...args) => execFileSync(HELPER, args, { encoding: 'utf8' }).trim();

let command = { commandId: 0, name: 'textarea' };
let state = null;

const server = http.createServer((req, res) => {
  if (req.url === '/command') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(command));
    return;
  }
  if (req.url === '/state') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      state = JSON.parse(body);
      res.end();
    });
    return;
  }
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.end(PAGE);
});

async function waitFor(condition, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return;
    await sleep(25);
  }
  throw new Error(`超时：${label}`);
}

function runHost(actions, startDelayMs = 300) {
  const child = spawn(HOST, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const frame = (message) => {
    const body = Buffer.from(JSON.stringify(message));
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length);
    return Buffer.concat([header, body]);
  };
  child.stdin.write(frame({ v: 1, cmd: 'start', startDelayMs, actions }));
  const result = new Promise((resolve) => {
    let output = Buffer.alloc(0);
    child.stdout.on('data', (chunk) => { output = Buffer.concat([output, chunk]); });
    child.on('close', () => resolve(output.length > 4 ? JSON.parse(output.subarray(4)) : null));
  });
  return { result, cancel: () => child.stdin.write(frame({ v: 1, cmd: 'cancel' })) };
}

async function prepare(name, chromePid) {
  command = { commandId: command.commandId + 1, name };
  helper('activate', String(chromePid));
  await waitFor(
    () => state?.commandId === command.commandId && state.focused && state.value === '',
    8000,
    '测试页没有获得焦点，未发送任何按键',
  );
}

const results = [];
function record(name, passed, detail = '') {
  results.push({ name, passed, detail });
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`);
}

const normalize = (value) => value.replaceAll(' ', ' ').replace(/\n+$/, '');
const makePlan = (text, seed) => plan(textToDoc(text), { ...OPTIONS, seed });

function applyActions(actions) {
  const buffer = [];
  for (const action of actions) {
    if (action.type === 'text') buffer.push(...action.value);
    if (action.type === 'key') buffer.pop();
  }
  return buffer.join('');
}

async function typingScene(name, targetName, text, sourceId, chromePid) {
  helper('source-set', sourceId);
  await prepare(targetName, chromePid);
  const event = await runHost(makePlan(text, 7)).result;
  await sleep(200);
  const actual = normalize(state.value);
  record(name, event?.event === 'done' && actual === text, actual === text ? '' : JSON.stringify({ event, actual }));
}

async function stopScene(name, reason, trigger, chromePid) {
  await prepare('textarea', chromePid);
  const actions = makePlan(TEXT, 11);
  const run = runHost(actions);
  await waitFor(() => state.value.length >= 8, 8000, '打字没有开始');
  trigger();
  const event = await run.result;
  await sleep(300);
  const expected = applyActions(actions.slice(0, event?.completed));
  const matches = state.value === expected;
  record(
    name,
    event?.event === 'stopped' && event.reason === reason && matches,
    JSON.stringify({ event, value: matches ? undefined : state.value, expected: matches ? undefined : expected }),
  );
  return { actions, event };
}

async function main() {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const profile = mkdtempSync(join(tmpdir(), 'human-typer-e2e-'));
  const chrome = spawn(CHROME, [
    `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--new-window', url,
  ], { stdio: 'ignore' });
  const originalSource = helper('source-get');

  try {
    await waitFor(() => state, 20000, 'Chrome 没有打开测试页');

    for (const [label, sourceId] of [['英文输入法', ABC], ['拼音输入法', PINYIN]]) {
      await typingScene(`${label} input`, 'input', LINE, sourceId, chrome.pid);
      await typingScene(`${label} textarea`, 'textarea', TEXT, sourceId, chrome.pid);
      await typingScene(`${label} contenteditable`, 'editable', TEXT, sourceId, chrome.pid);
    }
    helper('source-set', ABC);

    await prepare('textarea', chrome.pid);
    const cancelled = runHost(makePlan(TEXT, 3), 2000);
    await sleep(500);
    cancelled.cancel();
    const cancelEvent = await cancelled.result;
    await sleep(300);
    record('倒计时内取消', cancelEvent?.reason === 'user_cancel' && state.value === '', JSON.stringify(cancelEvent));

    await stopScene('按下 Cmd 后停止', 'user_input', () => helper('post-cmd'), chrome.pid);

    for (let round = 1; round <= 5; round += 1) {
      await switchScene(round, chrome.pid);
    }
  } finally {
    helper('source-set', originalSource);
    chrome.kill();
    server.close();
    server.closeAllConnections();
    await sleep(500);
    rmSync(profile, { recursive: true, force: true });
  }

  const failed = results.filter((result) => !result.passed).length;
  console.log(`${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
}

async function switchScene(round, chromePid) {
  const switched = await stopScene(
    `切换应用后停止 #${round}`,
    'app_switched',
    () => execFileSync('open', ['-b', 'com.apple.finder']),
    chromePid,
  );
  const typedBefore = state.value;
  helper('activate', String(chromePid));
  await waitFor(() => state.focused, 8000, '切回后测试页没有获得焦点');
  const remaining = switched.actions.slice(switched.event.completed);
  const resumed = await runHost(remaining).result;
  await sleep(200);
  record(
    `切换应用后继续 #${round}`,
    resumed?.event === 'done' && state.value === TEXT,
    state.value === TEXT ? `中断时已输入 ${typedBefore.length} 个字符` : JSON.stringify({ resumed, typedBefore, value: state.value }),
  );
}

main().catch((error) => {
  console.error(error.message);
  process.exit(2);
});
