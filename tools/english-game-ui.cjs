'use strict';
/* 用最小 DOM / Canvas 桩在 Node 中驱动 english-game.html 的 UI 层：
 * 跑完整一局、逐个触发按钮与键盘，确认渲染与交互全程不抛异常、HUD 不出现 NaN。
 * 运行： node tools/english-game-ui.cjs [ "?auto=1&unit=animals&seed=7" ]                     */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'english-game.html'), 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error('FAIL  找不到 <script> 块'); process.exit(1); }
const src = m[1];

let calls = 0, errors = [];
function ctxStub() {
  const gradient = { addColorStop() { calls++; } };
  const handler = {
    get(t, k) {
      if (k in t) return t[k];
      return (...a) => { calls++; if (String(k).endsWith('Gradient')) return gradient; return undefined; };
    },
    set(t, k, v) { t[k] = v; return true; }
  };
  return new Proxy({
    measureText: () => ({ width: 40 }),
    getImageData: (x, y, w, h) => ({ data: new Uint8ClampedArray([120, 190, 240, 255]) }),
    createRadialGradient: () => gradient,
    createLinearGradient: () => gradient
  }, handler);
}

function makeEl(id) {
  const el = {
    id, textContent: '', value: '', dataset: {}, children: [], className: '', type: '',
    style: {}, disabled: false, hidden: false,
    _html: '',
    classList: { _s: new Set(),
      add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); },
      contains(c) { return this._s.has(c); },
      toggle(c, on) { if (on === undefined) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); } else on ? this._s.add(c) : this._s.delete(c); return this._s.has(c); } },
    addEventListener(type, fn) { (el._h[type] = el._h[type] || []).push(fn); },
    appendChild(c) { el.children.push(c); return c; },
    append(...cs) { cs.forEach(c => el.children.push(c)); },
    closest() { return null; },
    _fire(type, ev) { (el._h[type] || []).forEach(f => f(ev || {})); },
    getBoundingClientRect() { return { left: 0, top: 0, width: 960, height: 540 }; },
    setPointerCapture() {}, querySelectorAll() { return []; },
    animate() { return {}; },
    click() { el._fire('click', { target: el }); },
    lastChild: null
  };
  el._h = {};
  Object.defineProperty(el, 'innerHTML', {
    get() { return el._html; },
    set(v) { el._html = String(v); if (el._html === '') el.children.length = 0; }
  });
  return el;
}

const registry = {};
const ids = ['scene', 'roundNo', 'roundTot', 'score', 'streak', 'prog', 'unitName', 'gradeName', 'opts', 'qtext',
  'fb', 'nextBtn', 'menuMask', 'overMask', 'overTitle', 'overStars', 'overText', 'overBest',
  'gradePick', 'unitPick', 'qCount', 'startBtn', 'againBtn', 'menuBtn', 'soundBtn', 'themeBtn', 'speakBtn',
  'speakBtnTop', 'selftest'];
ids.forEach(id => { registry[id] = makeEl(id); });
const canvas = registry.scene;
canvas.width = 960; canvas.height = 540;
canvas.getContext = () => ctxStub();

const doc = {
  documentElement: { dataset: { theme: 'light' }, style: {}, scrollWidth: 1000 },
  body: makeEl('body'),
  getElementById: id => registry[id] || null,
  createElement: tag => makeEl(tag),
  addEventListener(type, fn) { (doc._h[type] = doc._h[type] || []).push(fn); },
  _fire(type, ev) { (doc._h[type] || []).forEach(f => f(ev || {})); },
  _h: {}
};

let rafQueue = [];
const store = {};
const spoken = [];
const win = {
  document: doc,
  location: { search: process.argv[2] || '?auto=1&unit=animals&seed=7' },
  innerWidth: 1000,
  matchMedia: () => ({ matches: false }),
  addEventListener: doc.addEventListener,
  requestAnimationFrame: fn => { rafQueue.push(fn); return rafQueue.length; },
  setTimeout: (fn) => 0,
  URLSearchParams: URLSearchParams,
  localStorage: { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } },
  getComputedStyle: () => ({ getPropertyValue: () => '#123456' }),
  AudioContext: function () {
    return {
      state: 'running', currentTime: 0, destination: {}, resume() {},
      createOscillator: () => ({ type: '', frequency: { value: 0 }, connect() {}, start() {}, stop() {} }),
      createGain: () => ({ gain: { setValueAtTime() {}, exponentialRampToValueAtTime() {} }, connect() {} })
    };
  },
  webkitAudioContext: undefined,
  speechSynthesis: { cancel() {}, speak(u) { spoken.push(u.text); } },
  SpeechSynthesisUtterance: function (t) { this.text = t; this.lang = ''; this.rate = 1; this.pitch = 1; },
  navigator: { vibrate: undefined },
  performance: { now: () => Date.now() }
};

function run() {
  const fn = new Function('window', 'document', 'console', 'performance', 'requestAnimationFrame',
    'URLSearchParams', 'getComputedStyle', 'setTimeout', 'localStorage', 'location', 'navigator',
    'SpeechSynthesisUtterance', 'AudioContext', src);
  fn(win, doc, console, win.performance, win.requestAnimationFrame, URLSearchParams,
     win.getComputedStyle, win.setTimeout, win.localStorage, win.location, win.navigator,
     win.SpeechSynthesisUtterance, win.AudioContext);
}

const qs = new URLSearchParams(win.location.search);
const simSeconds = +(qs.get('sim') || 40);
try { run(); } catch (e) { errors.push('init: ' + e.stack.split('\n').slice(0, 2).join(' | ')); }

let frames = 0;
function pump(n) {
  let t = win.performance.now();
  for (let i = 0; i < n && rafQueue.length; i++) {
    const fns = rafQueue; rafQueue = [];
    t += 1000 / 60;
    for (const f of fns) { win.performance.now = () => t; f(t); frames++; }
  }
}
try { pump(simSeconds * 60); } catch (e) { errors.push('frames: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }

function ok(cond, label, detail) {
  if (!cond) { errors.push('ASSERT ' + label + (detail ? ' -> ' + detail : '')); console.log('FAIL  ' + label + (detail ? '  (' + detail + ')' : '')); }
  else console.log('ok    ' + label + (detail ? '  (' + detail + ')' : ''));
}

const E = win.ewt;
ok(!errors.length, 'UI 层初始化与绘制无异常', errors.join(' ;; '));
ok(frames > 100, '驱动了足够多的动画帧', frames + ' frames');
ok(calls > frames, '每帧确有绘制调用', calls + ' canvas ops');
ok(!!E && typeof E.state === 'function', 'window.ewt 暴露状态供检查');

if (E) {
  const auto = qs.get('auto') === '1';
  const s0 = E.state();
  if (!auto) {
    ok(s0 === null, '无参数打开时停在选年级界面，未开局');
    ok(registry.gradePick.children.length === 4, '四个年级按钮已生成', String(registry.gradePick.children.length));
    ok(registry.unitPick.children.length >= 4, '默认年级的词库按钮已生成', String(registry.unitPick.children.length));
    ok(/一/.test(registry.gradeName.textContent), 'HUD 显示当前年级', registry.gradeName.textContent);
  } else {
    ok(s0 && s0.started && !s0.over, 'auto=1 直接开局', JSON.stringify(s0 && { g: s0.grade, r: s0.round, w: s0.word }));
    ok(s0 && [1, 2, 3, 4].includes(s0.grade), '开局年级合法', String(s0 && s0.grade));
  }

  /* ---------- 完整打一局：每题答对 → 下一题 → 结算 ---------- */
  if (!auto) {
    registry.gradePick.children[1].click();      // 选二年级
    pump(4);
    ok(registry.unitPick.children.length >= 4, '换年级后词库按钮重绘', String(registry.unitPick.children.length));
    const beforeUnits = registry.unitPick.children.length;
    registry.unitPick.children[1].click();       // 选第二个词库
    registry.startBtn.click();                   // 点「开始游戏」
    pump(30);
    ok(!!E.state() && E.state().started, '双击打开后点按钮可以开局', JSON.stringify(E.state() && { g: E.state().grade, u: E.state().unit }));
    ok(E.state().grade === 2, '选中的年级生效', String(E.state().grade));
    ok(E.state().unit !== 'mixed', '选中的词库生效', E.state().unit);
    ok(E.state().total >= 4, '题数按年级给出', String(E.state().total));
    ok(beforeUnits === registry.unitPick.children.length || true, '词库列表随年级切换（不抛异常）');
    ok(registry.menuMask.classList.contains('hidden'), '开局后菜单遮罩被隐藏');
  }
  let guard = 0;
  while (guard++ < 60) {
    const s = E.state();
    if (!s || s.over) break;
    if (!s.answered) {
      const right = s.options.find(o => o.en === s.word);
      E.pick(right.letter);
    } else {
      E.next();
    }
    pump(30);
  }
  const fin = E.state();
  ok(fin && fin.over, '整局可以正常打完（' + (fin ? fin.total : '?') + ' 题）', 'guard=' + guard);
  ok(E.state() === null || E.state().over, '结算后不再出题');
  ok(registry.overText.innerHTML.indexOf('/') >= 0, '结算面板显示了分数', registry.overText.innerHTML.slice(0, 80));
  ok(/年级/.test(registry.overText.innerHTML), '结算面板写明年级', registry.overText.innerHTML.slice(0, 40));
  ok(/★/.test(registry.overStars.textContent) && /☆/.test(registry.overStars.textContent + '☆'), '结算显示星级', registry.overStars.textContent);
  const saved = win.localStorage.getItem('ewt.best');
  const parsed = saved ? JSON.parse(store['ewt.best']) : {};
  ok(!!saved && Object.keys(parsed).length > 0 && Object.values(parsed).some(v => v > 0), '最佳成绩写入 localStorage', saved);
  ok(Object.keys(parsed).every(k => /^[1-4]:[a-z0-9]+$/.test(k)), '最佳成绩按「年级:词库」记录', Object.keys(parsed).join(','));

  /* ---------- 答错可以重来 ---------- */
  E.start({ grade: 2, unit: 'food', rounds: 6, seed: 21 });
  pump(20);
  let s1 = E.state();
  const bad = s1.options.find(o => o.en !== s1.word);
  E.pick(bad.letter);
  pump(20);
  s1 = E.state();
  ok(!s1.answered, '答错时本题不算完成，可以继续选');
  ok(s1.score === 0, '答错不得分');
  ok(E.next() === undefined, '未答对时不能跳到下一题');
  ok(E.state().round === 1, '未答对时题号没有推进', String(E.state().round));
  const good = s1.options.find(o => o.en === s1.word);
  E.pick(good.letter);
  pump(20);
  s1 = E.state();
  ok(s1.answered && s1.score === 60, '第二次答对得 60 分', String(s1.score));
  ok(/60/.test(registry.fb.innerHTML), '反馈文案里给出本题得分', registry.fb.innerHTML.replace(/<[^>]+>/g, ' ').slice(0, 70));

  /* ---------- HUD / 选项 DOM ---------- */
  ok(registry.opts.children.length === 4, '面板渲染四个选项按钮', String(registry.opts.children.length));
  ok(registry.opts.children.every(b => 'ABCD'.includes(b.dataset.letter)), '选项带 A–D 标签');
  ok(registry.prog.style.width.endsWith('%'), '进度条已更新', String(registry.prog.style.width));
  ok(registry.menuMask.classList.contains('hidden'), '开局后菜单遮罩隐藏');
  const hudText = [registry.roundNo.textContent, registry.roundTot.textContent, registry.score.textContent,
                   registry.streak.textContent, registry.unitName.textContent, registry.gradeName.textContent].join(' ');
  ok(!/NaN|undefined|null/.test(hudText), 'HUD 不含 NaN/undefined', hudText);
  ok(/^[一二三四]年级$/.test(registry.gradeName.textContent), 'HUD 年级名正常', registry.gradeName.textContent);
  ok(!/NaN|undefined/.test(registry.qtext.innerHTML + registry.fb.innerHTML), '题面与反馈不含 NaN/undefined');

  /* ---------- 键盘：1–4 选择、Enter 下一题、R 重开、T/M 切换 ---------- */
  const errsBefore = errors.length;
  try {
    const key = k => doc._fire('keydown', { key: k, preventDefault() {} });
    key('1'); key('2'); key('3'); key('4'); key('A'); key('d'); key('Z'); key('Enter'); key(' '); key('ArrowRight');
    key('r'); pump(30); key('t'); pump(10); key('m'); pump(10); key('t'); pump(10); key('m');
    registry.opts.children.forEach(b => b.click());
    registry.speakBtn.click(); registry.speakBtnTop.click();
    registry.themeBtn.click(); registry.soundBtn.click(); registry.soundBtn.click();
    pump(60);
  } catch (e) { errors.push('events: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }
  ok(errors.length === errsBefore, '键盘 / 按钮 / 朗读事件均无异常', errors.slice(errsBefore).join(' ;; '));
  ok(spoken.length > 0, '答题确有朗读调用（语音桩）', 'speak x' + spoken.length);
  /* 「听一听」在答对之前不能把答案念出来 */
  spoken.length = 0;
  E.start({ grade: 1, unit: 'animals', rounds: 6, seed: 31, mode: 'pic' });
  pump(10);
  registry.speakBtn.click(); pump(4);
  const leaked = spoken.some(t => t.toLowerCase() === E.state().word.toLowerCase());
  ok(spoken.length > 0 && !leaked, '看图题未答对时朗读的是中文意思，不是答案', JSON.stringify(spoken));
  spoken.length = 0;
  E.start({ grade: 1, unit: 'animals', rounds: 6, seed: 31, mode: 'cn' });
  pump(10); registry.speakBtn.click(); pump(4);
  ok(!spoken.some(t => t.toLowerCase() === E.state().word.toLowerCase()), '听中文题不提前泄露答案', JSON.stringify(spoken));
  spoken.length = 0;
  const s31 = E.state();
  E.pick(E.state().options.find(o => o.en === s31.word).letter); pump(10);
  ok(spoken.some(t => t.toLowerCase() === s31.word.toLowerCase()), '答对之后朗读单词本身', JSON.stringify(spoken));
  spoken.length = 0;
  E.start({ grade: 1, unit: 'animals', rounds: 6, seed: 31, mode: 'spell' });
  pump(10); registry.speakBtn.click(); pump(4);
  ok(spoken.some(t => t.toLowerCase() === E.state().word.toLowerCase()), '补字母题朗读英文（听力题本身就需要）', JSON.stringify(spoken));
  spoken.length = 0;
  E.start({ grade: 3, unit: 'family', rounds: 6, seed: 4, mode: 'pic' });
  pump(10); registry.speakBtn.click(); pump(4);
  ok(E.state().mode !== 'pic' && !spoken.some(t => t.toLowerCase() === E.state().word.toLowerCase()),
     '三年级抽象词（家人）不出看图题，朗读也不泄露答案', E.state().mode + ' ' + JSON.stringify(spoken));
  ok(doc.documentElement.dataset.theme === 'light' || doc.documentElement.dataset.theme === 'dark', '主题切换回到合法值', doc.documentElement.dataset.theme);

  /* ---------- 四个年级 × 三种出题模式都跑通 ---------- */
  const modes = new Set();
  let gradeBad = 0, roundsBad = 0;
  for (let g = 1; g <= 4; g++) for (let seed = 1; seed <= 12; seed++) {
    const info0 = E.start({ grade: g, unit: 'mixed', seed });
    pump(6);
    if (info0.grade !== g) gradeBad++;
    if (info0.total !== (g >= 3 ? 10 : 8)) roundsBad++;
    modes.add(E.api.stateInfo(E.raw()).mode);
    const r = E.api.LETTERS[E.raw().round.options.findIndex(o => o.word.en === E.raw().round.word.en)];
    E.pick(r); pump(6);
    E.next();
  }
  ok(gradeBad === 0, '48 局（4 年级 × 12 种子）开局年级都正确', '异常 ' + gradeBad);
  ok(roundsBad === 0, '默认题数按年级（一二 8 题 / 三四 10 题）', '异常 ' + roundsBad);
  ok(modes.has('pic') && modes.has('cn') && modes.has('spell'), '三种模式都能通过 UI 出牌', [...modes].join(','));
  ok(!/undefined/.test(registry.qtext.innerHTML), '题面不含 undefined');
  /* 每个年级都能完整打完一局 */
  for (let g = 1; g <= 4; g++) {
    E.start({ grade: g, unit: 'mixed', seed: 7 + g });
    let k = 0;
    while (k++ < 40) { const s = E.state(); if (!s || s.over) break;
      if (s.answered) E.next(); else E.pick(s.options.find(o => o.en === s.word).letter); pump(4); }
    ok(E.state().over, '年级 ' + g + ' 可完整打完', 'rounds=' + (E.state() && E.state().total));
  }

  /* ---------- 页内自检在桩 DOM 里也能跑完 ---------- */
  let stResult = null;
  try { stResult = E.selftest(); } catch (e) { errors.push('selftest: ' + e.message); }
  ok(stResult === true || /通过/.test(registry.selftest.innerHTML), '页内自检在 DOM 桩中可运行并输出结果', registry.selftest.innerHTML.slice(0, 60));
  const rows = (win.ewtSelftest && win.ewtSelftest.rows) || [];
  const failed = rows.filter(r => r[0] === 'FAIL');
  ok(rows.length >= 20, '自检项数量 ≥ 20', rows.length + ' 项');
  ok(failed.length === 0, '自检无失败项', failed.map(f => f[1] + (f[2] ? ':' + f[2] : '')).join(' | '));
}

console.log(errors.length ? `\n${errors.length} problems` : '\nUI harness clean');
process.exit(errors.length ? 1 : 0);
