const $ = (id) => document.getElementById(id);
const DEFAULTS = { text: '', wpm: 60, error: 3, pause: 1 };

const STATUS_TEXT = {
  running: '已开始：请在 5 秒内点进目标输入框，之后不要操作键盘和鼠标。',
  done: '已完成。',
};
const REASON_TEXT = {
  app_switched: '已停止：前台应用发生变化。点继续后，5 秒内把光标放回原位。',
  user_input: '已停止：检测到键盘或鼠标操作。点继续后，5 秒内把光标放回原位。',
  user_cancel: '已取消。点继续后，5 秒内把光标放回原位。',
};
const ERROR_TEXT = {
  no_accessibility_permission: '缺少权限：请在系统设置的“辅助功能”中允许 human-typer-host，然后点继续。',
  host_unavailable: '无法连接本地程序：请按 README 运行安装命令后重试。',
  unsupported_protocol: '本地程序版本不匹配：请重新运行安装命令。',
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
  $('resume').disabled = !status.resumable;
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

$('resume').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'resume' });
});

$('cancel').addEventListener('click', () => {
  chrome.runtime.sendMessage({ type: 'cancel' });
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.status) renderStatus(changes.status.newValue);
});
