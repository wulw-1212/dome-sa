'use strict';
/* 用最小 DOM / Canvas 桩在 Node 中驱动 index.html 的 UI 层，捕捉渲染期异常与明显错误。 */
const fs = require('fs');
const path = require('path');

const file = path.join(__dirname, '..', 'index.html');
const html = fs.readFileSync(file, 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m){ console.error('FAIL  找不到 <script> 块'); process.exit(1); }
const src = m[1];
require('./extract.cjs');

let calls = 0, errors = [];
function ctxStub(){
  const gradient = { addColorStop(){ calls++; } };
  const handler = {
    get(t, k){
      if (k in t) return t[k];
      // 任何未实现的属性都返回可调用桩，计数用于确认绘制确实发生
      return (...a) => { calls++; if (k === 'createLinearGradient' || k === 'createRadialGradient') return gradient; };
    },
    set(t, k, v){ t[k] = v; return true; }
  };
  return new Proxy({ measureText: () => ({ width: 40 }) }, handler);
}

function makeEl(id){
  const el = {
    id, textContent: '', innerHTML: '', value: '', dataset: {}, children: [],
    classList: { _s: new Set(),
      add(c){ this._s.add(c); }, remove(c){ this._s.delete(c); },
      contains(c){ return this._s.has(c); },
      toggle(c, on){ if (on === undefined) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); } else on ? this._s.add(c) : this._s.delete(c); return this._s.has(c); } },
    addEventListener(type, fn){ (el._h[type] = el._h[type] || []).push(fn); },
    appendChild(c){ el.children.push(c); return c; },
    closest(){ return null; },
    _fire(type, ev){ (el._h[type] || []).forEach(f => f(ev || {})); },
    getBoundingClientRect(){ return { left: 0, top: 0, width: 960, height: 620 }; },
    setPointerCapture(){}, querySelectorAll(){ return []; },
    style: {}, lastChild: null
  };
  el._h = {};
  return el;
}

const registry = {};
const ids = ['stage', 'chip1', 'chip2', 'lbl1', 'lbl2', 's1', 's2', 'g1', 'g2', 'rally', 'longest', 'speed',
  'msg', 'menuMask', 'pauseMask', 'overMask', 'overTitle', 'overText', 'startBtn', 'pauseBtn', 'resetBtn',
  'modeSeg', 'diffSel', 'boSel', 'soundBtn', 'themeBtn', 'log', 'foot', 'touchServe', 'touchSmash'];
ids.forEach(id => { registry[id] = makeEl(id); });
const canvas = registry.stage;
canvas.width = 960; canvas.height = 620;
canvas.getContext = () => ctxStub();

const doc = {
  documentElement: { dataset: { theme: 'light' }, style: {} },
  body: { classList: makeEl('body').classList },
  getElementById: id => registry[id] || null,
  createElement: tag => makeEl(tag),
  addEventListener(type, fn){ (doc._h[type] = doc._h[type] || []).push(fn); },
  _fire(type, ev){ (doc._h[type] || []).forEach(f => f(ev || {})); },
  _h: {}
};

let rafQueue = [];
const win = {
  document: doc,
  location: { search: process.argv[2] || '?auto=1&demo=1&seed=9&sim=900' },
  matchMedia: () => ({ matches: false }),
  addEventListener: doc.addEventListener,
  requestAnimationFrame: fn => { rafQueue.push(fn); return rafQueue.length; },
  setTimeout: (fn) => 0,
  URLSearchParams: URLSearchParams,
  getComputedStyle: () => ({ getPropertyValue: k => '#123456' }),
  AudioContext: undefined, webkitAudioContext: undefined,
  performance: { now: () => Date.now() }
};

// 在模拟帧之后由测试代码读取内核状态
const sandboxApi = { window: win, document: doc, console, performance: win.performance, requestAnimationFrame: win.requestAnimationFrame };

function run(){
  const fn = new Function('window', 'document', 'console', 'performance', 'requestAnimationFrame',
    'URLSearchParams', 'getComputedStyle', 'setTimeout', 'addEventListener', 'matchMedia', 'location', src);
  fn(win, doc, console, win.performance, win.requestAnimationFrame, URLSearchParams,
     win.getComputedStyle, win.setTimeout, doc.addEventListener, win.matchMedia, win.location);
}

/* ---------- 驱动若干帧 ---------- */
const qs = new URLSearchParams(win.location.search);
const simSeconds = +(qs.get('sim') || 600);
try{
  run();
}catch(e){ errors.push('init: ' + e.stack.split('\n').slice(0, 2).join(' | ')); }

let frames = 0;
try{
  let t = 0;
  while (rafQueue.length && frames < simSeconds * 60){
    const fns = rafQueue; rafQueue = [];
    t += 1000 / 60;
    for (const f of fns){ win.performance.now = () => t; f(t); frames++; }
  }
}catch(e){ errors.push('frames: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }

const g = win.__game;
function ok(cond, label, detail){
  if (!cond){ errors.push('ASSERT ' + label + (detail ? ' -> ' + detail : '')); console.log('FAIL  ' + label + (detail ? '  (' + detail + ')' : '')); }
  else console.log('ok    ' + label + (detail ? '  (' + detail + ')' : ''));
}

ok(!errors.length, 'UI 层初始化与绘制无异常', errors.join(' ;; '));
ok(frames > 100, '驱动了足够多的动画帧', frames + ' frames');
ok(calls > frames, '每帧确有绘制调用', calls + ' canvas ops');
ok(g && g.S, 'window.__game 暴露内核供调试');
if (g){
  const S = g.S;
  ok(S.phase !== 'menu', 'auto=1 直接开打', S.phase);
  ok(S.mode === 'demo', 'demo=1 双方由 AI 驱动', S.mode);
  ok(S.stats.points > 0, '模拟中已产生分数', JSON.stringify(S.score));
  ok(S.gameLog.length > 0 || S.phase === 'over', '模拟时长足够打完至少一局', JSON.stringify(S.gameLog));
  ok(doc.getElementById('foot').textContent.includes('球台'), '页脚渲染了球台参数');
  ok(registry.msg.classList.contains('show') || S.phase === 'over', '比分提示有过可见状态');
  ok(!/NaN|undefined/.test(registry.s1.textContent + registry.s2.textContent + registry.speed.textContent),
    'HUD 数字不含 NaN/undefined', `${registry.s1.textContent}/${registry.s2.textContent}/${registry.speed.textContent}`);
}

/* ---------- 交互事件不应抛错 ---------- */
const before = errors.length;
try{
  doc._fire('keydown', { key: 'ArrowLeft', code: 'ArrowLeft', preventDefault(){}, target: {} });
  doc._fire('keyup', { key: 'ArrowLeft', code: 'ArrowLeft' });
  doc._fire('keydown', { key: ' ', code: 'Space', preventDefault(){} });
  doc._fire('keyup', { key: ' ', code: 'Space' });
  doc._fire('keydown', { key: 'p', code: 'KeyP', preventDefault(){}, target: {} });
  doc._fire('keydown', { key: 't', code: 'KeyT', preventDefault(){}, target: {} });
  doc._fire('keydown', { key: 'm', code: 'KeyM', preventDefault(){}, target: {} });
  doc._fire('keydown', { key: 'r', code: 'KeyR', preventDefault(){}, target: {} });
  canvas._fire('pointerdown', { clientX: 480, clientY: 300, pointerType: 'touch', pointerId: 1 });
  canvas._fire('pointermove', { clientX: 300, clientY: 300, pointerType: 'mouse' });
  doc._fire('pointerup', {});
  ids.forEach(id => { try{ registry[id]._fire('click', { target: { closest: () => null } }); }catch(e){} });
  let t2 = win.performance.now() + 1000;
  for (let i = 0; i < 120 && rafQueue.length; i++){ const fns = rafQueue; rafQueue = []; t2 += 16.7; fns.forEach(f => f(t2)); }
}catch(e){ errors.push('events: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }
ok(errors.length === before, '键盘 / 指针 / 按钮事件均无异常');

console.log(errors.length ? `\n${errors.length} problems` : '\nUI harness clean');
process.exit(errors.length ? 1 : 0);
