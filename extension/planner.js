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
