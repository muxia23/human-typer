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

function savePending(actions) {
  return chrome.storage.local.set({ pending: actions });
}

function start({ text, settings }) {
  if (port) return;
  run(plan(textToDoc(text), {
    ...settings,
    seed: Math.floor(Math.random() * 2 ** 32),
  }));
}

async function resume() {
  if (port) return;
  const { pending } = await chrome.storage.local.get('pending');
  if (pending?.length) run(pending);
}

function run(actions) {
  const current = chrome.runtime.connectNative(HOST_NAME);
  port = current;
  let finished = false;

  current.onMessage.addListener((message) => {
    finished = true;
    if (message.event === 'done') {
      savePending([]);
      setStatus({ state: 'done' });
    }
    if (message.event === 'stopped') {
      savePending(actions.slice(message.completed));
      setStatus({ state: 'stopped', reason: message.reason, resumable: true });
    }
    if (message.event === 'error') {
      // 本地程序在打字前才会报错，所有动作都还没执行
      savePending(actions);
      setStatus({ state: 'error', code: message.code, resumable: true });
    }
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
  if (message.type === 'resume') resume();
  if (message.type === 'cancel') port?.postMessage({ v: 1, cmd: 'cancel' });
});
