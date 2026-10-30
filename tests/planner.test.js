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
