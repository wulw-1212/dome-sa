'use strict';
/* 用最小 DOM / Canvas 桩在 Node 中驱动 sin-curve.html 的 UI 层：
 * 验证数学内核、渲染无异常、交互不崩、HUD 不出现 NaN。
 * 运行： node tools/sin-curve-harness.cjs [ "?auto=1&sim=60" ]                      */
const fs = require('fs');
const path = require('path');

const file = path.join(__dirname, '..', 'sin-curve.html');
const html = fs.readFileSync(file, 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.error('FAIL  找不到 <script> 块'); process.exit(1); }
const src = m[1];

let calls = 0, errors = [];
function ctxStub() {
  const grad = { addColorStop() { calls++; } };
  return new Proxy({
    measureText: () => ({ width: 42 }),
    createLinearGradient: () => grad,
    createRadialGradient: () => grad,
    setTransform: () => { calls++; }
  }, {
    get(t, k) {
      if (k in t) return t[k];
      return (...a) => { calls++; return undefined; };
    },
    set(t, k, v) { t[k] = v; return true; }
  });
}

function makeEl(id, extra) {
  const el = {
    id, textContent: '', innerHTML: '', value: '0', checked: false, hidden: false,
    style: {}, dataset: {}, children: [], _h: {},
    classList: {
      _s: new Set(),
      add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); },
      contains(c) { return this._s.has(c); },
      toggle(c, on) { on ? this._s.add(c) : this._s.delete(c); }
    },
    addEventListener(type, fn) { (el._h[type] = el._h[type] || []).push(fn); },
    appendChild(c) { el.children.push(c); return c; },
    getBoundingClientRect() { return { left: 0, top: 0, width: el._w || 960, height: el._h2 || 600 }; },
    setPointerCapture() {}, releasePointerCapture() {},
    querySelectorAll() { return []; },
    focus() {}, blur() {},
    click() { el._fire('click', { target: el }); },
    _fire(type, ev) { (el._h[type] || []).forEach(f => f(ev || {})); }
  };
  Object.assign(el, extra || {});
  return el;
}

function canvasEl(id, w, h) {
  const el = makeEl(id, { width: w, height: h, _w: w, _h2: h });
  el.getContext = () => ctxStub();
  return el;
}

const registry = {};
const ids = ['plot', 'circle', 'plotWrap', 'circleBox', 'playBtn', 'resetBtn', 'themeBtn',
  'formulaText', 'periodText', 'rangeText', 'outX', 'outXpi', 'outY', 'outTheta', 'outSpeed',
  'amp', 'freq', 'phase', 'offset', 'span', 'speed',
  'ampOut', 'freqOut', 'phaseOut', 'offsetOut', 'spanOut', 'zoomOut', 'speedOut',
  'ckGhost', 'ckGrid', 'ckFill', 'ckZero', 'ckCircle', 'selftest', 'selftestList'];
ids.forEach(id => { registry[id] = makeEl(id); });
registry.plot = canvasEl('plot', 1180, 560);
registry.circle = canvasEl('circle', 280, 236);
registry.plotWrap = makeEl('plotWrap', { _w: 1180, _h2: 560 });
registry.circleBox = makeEl('circleBox', { _w: 280, _h2: 236 });
// 预设按钮：querySelectorAll 返回它们
const presetButtons = ['sin', 'cos', 'double', 'half', 'lift'].map(k => {
  const b = makeEl('preset-' + k);
  b.getAttribute = n => (n === 'data-preset' ? k : null);
  return b;
});

const doc = {
  documentElement: { setAttribute() {}, getAttribute() { return 'light'; }, style: {} },
  body: makeEl('body'),
  title: '',
  getElementById: id => registry[id] || null,
  createElement: tag => makeEl(tag),
  querySelectorAll: sel => (sel === '.preset-row button' ? presetButtons : []),
  addEventListener(type, fn) { (doc._h[type] = doc._h[type] || []).push(fn); },
  _fire(type, ev) { (doc._h[type] || []).forEach(f => f(ev || {})); },
  _h: {}
};

let rafQueue = [];
const search = process.argv[2] || '?auto=1&sim=120';
const win = {
  document: doc,
  location: { search: search },
  matchMedia: () => ({ matches: false }),
  addEventListener: doc.addEventListener,
  requestAnimationFrame: fn => { rafQueue.push(fn); return rafQueue.length; },
  URLSearchParams: URLSearchParams,
  getComputedStyle: () => ({ getPropertyValue: () => '#123456' }),
  devicePixelRatio: 2,
  innerWidth: 1440,
  performance: { now: () => Date.now() }
};
win.window = win;

function run() {
  const fn = new Function('window', 'document', 'console', 'location', 'requestAnimationFrame',
    'getComputedStyle', 'devicePixelRatio', 'URLSearchParams', 'innerWidth', 'performance', src);
  fn(win, doc, console, win.location, win.requestAnimationFrame, win.getComputedStyle,
    win.devicePixelRatio, URLSearchParams, win.innerWidth, win.performance);
}

const qs = new URLSearchParams(search);
const simSeconds = +(qs.get('sim') || 120);

try { run(); } catch (e) { errors.push('init: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }

const S = win.__sinCurve && win.__sinCurve.state;
const core = win.__sinCurve && win.__sinCurve.core;

let frames = 0;
try {
  let t = 0;
  while (rafQueue.length && frames < simSeconds * 60) {
    const fns = rafQueue; rafQueue = [];
    t += 1000 / 60;
    for (const f of fns) { f(t); frames++; }
  }
} catch (e) { errors.push('frames: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }

function ok(cond, label, detail) {
  if (!cond) { errors.push('ASSERT ' + label + (detail ? ' -> ' + detail : '')); console.log('FAIL  ' + label + (detail ? '  (' + detail + ')' : '')); }
  else console.log('ok    ' + label + (detail ? '  (' + detail + ')' : ''));
}

ok(!errors.length, 'UI 层初始化与动画帧无异常', errors.join(' ;; '));
ok(frames > 100, '驱动了足够多的动画帧', frames + ' frames');
ok(calls > frames, '每帧确有绘制调用', calls + ' canvas ops');
ok(S, 'window.__sinCurve 暴露状态供调试');
ok(core && typeof core.curveY === 'function', '内核可被外部调用');

if (S) {
  const PI = Math.PI, TAU = 2 * PI;
  ok(qs.get('auto') === '1' ? S.playing === true : S.playing === false, 'auto 参数与扫描状态一致', String(S.playing));
  ok(isFinite(S.t) && S.t > 0, '扫描时间随帧推进', S.t.toFixed(3));
  ok(S.cfg.A >= 0.2 && S.cfg.A <= 2.4 && S.cfg.B >= 0.25 && S.cfg.B <= 4,
    '参数保持在合法区间', JSON.stringify(S.cfg));
  const y = core.curveY(S.cfg, 1.234);
  ok(isFinite(y), 'curveY 输出有限', String(y));
  ok(Math.abs(core.curveY({ A: 1, B: 1, C: 0, D: 0 }, PI / 2) - 1) < 1e-12,
    'sin(π/2) = 1');
  ok(Math.abs(core.curveY({ A: 1, B: 1, C: 0, D: 0 }, PI) ) < 1e-12, 'sin(π) = 0');
  ok(Math.abs(core.curveY({ A: 2, B: 3, C: PI / 4, D: 1 }, 0.3)
      - (2 * Math.sin(3 * 0.3 + PI / 4) + 1)) < 1e-12, 'A/B/C/D 组合公式正确');
  const outs = [registry.outX.textContent, registry.outY.textContent, registry.outTheta.textContent,
    registry.outSpeed.textContent, registry.formulaText.textContent, registry.periodText.textContent,
    registry.rangeText.textContent, registry.ampOut.textContent, registry.freqOut.textContent,
    registry.phaseOut.textContent, registry.offsetOut.textContent, registry.spanOut.textContent,
    registry.zoomOut.textContent, registry.speedOut.textContent];
  ok(!/NaN|undefined|null/.test(outs.join('|')), 'HUD / 面板不含 NaN 或 undefined', outs.join(' / '));
  ok(/sin\(/.test(registry.formulaText.textContent), '公式文本渲染出 sin', registry.formulaText.textContent);

  /* ---- 交互：事件不应抛错 ---- */
  const before = errors.length;
  try {
    registry.playBtn._fire('click', {});
    registry.amp.value = '1.8'; registry.amp._fire('input', {});
    registry.freq.value = '2.5'; registry.freq._fire('input', {});
    registry.phase.value = '1.57'; registry.phase._fire('input', {});
    registry.offset.value = '-0.5'; registry.offset._fire('input', {});
    registry.span.value = '8'; registry.span._fire('input', {});
    registry.speed.value = '3'; registry.speed._fire('input', {});
    ['ckGhost', 'ckGrid', 'ckFill', 'ckZero', 'ckCircle'].forEach(id => {
      registry[id].checked = !registry[id].checked; registry[id]._fire('change', {});
    });
    presetButtons.forEach(b => b._fire('click', {}));
    registry.plot._fire('pointermove', { clientX: 700, clientY: 280, pointerType: 'mouse' });
    registry.plot._fire('pointerdown', { clientX: 400, clientY: 200, pointerType: 'touch' });
    registry.plot._fire('pointerleave', {});
    [' ', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', '[', ']', 'r', 't', 'R', 'T']
      .forEach(k => doc._fire('keydown', { key: k, preventDefault() {} }));
    doc._fire('keydown', { key: 'x', preventDefault() {} });
    registry.themeBtn._fire('click', {});
    registry.resetBtn._fire('click', {});
    let t2 = win.performance.now() + 2000;
    for (let i = 0; i < 240 && rafQueue.length; i++) { const fns = rafQueue; rafQueue = []; t2 += 16.7; fns.forEach(f => f(t2)); }
  } catch (e) { errors.push('events: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }
  ok(errors.length === before, '滑块 / 复选框 / 预设 / 指针 / 键盘事件均无异常');
  ok(S.cfg.A === 1 && S.cfg.B === 1 && S.cfg.C === 0 && S.cfg.D === 0,
    '复位回到 y = sin x', JSON.stringify(S.cfg));
  ok(S.playing === false, '复位后停止扫描');

  /* ---- 数值边界：极端参数下不产生非法坐标 ---- */
  const bad = errors.length;
  try {
    S.cfg = { A: 2.4, B: 4, C: -PI, D: -1 };
    S.cycles = 12; S.speed = 4;
    win.__sinCurve.render();
    S.cfg = { A: 0.2, B: 0.25, C: PI, D: 1 };
    S.cycles = 1;
    win.__sinCurve.render();
  } catch (e) { errors.push('extremes: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }
  ok(errors.length === bad, '极端参数下渲染不抛错');
}

console.log(errors.length ? `\n${errors.length} problems` : '\nUI harness clean');
process.exit(errors.length ? 1 : 0);
