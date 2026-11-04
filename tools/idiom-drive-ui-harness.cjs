'use strict';
/* 用最小 DOM / Canvas 桩在 Node 中驱动 idiom-driving.html 的 UI 层，
 * 捕捉渲染期异常、确认每帧有绘制、HUD 无 NaN，并检查弹出成语的 DOM。
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const file = path.join(root, 'idiom-driving.html');
const html = fs.readFileSync(file, 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m){ console.error('FAIL  找不到 <script> 块'); process.exit(1); }
const src = m[1];

let calls = 0, errors = [];
function ctxStub(){
  const gradient = { addColorStop(){ calls++; } };
  const handler = {
    get(t, k){
      if (k in t) return t[k];
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
    getBoundingClientRect(){ return { left: 0, top: 0, width: 960, height: 640 }; },
    setPointerCapture(){}, querySelectorAll(){ return []; },
    querySelector(sel){
      // 只支持 .class 选择器：弹层里的 tag / ci / py / mean
      if (sel === '.tag') return el._parts.tag || (el._parts.tag = makeEl('tag'));
      if (sel === '.ci') return el._parts.ci || (el._parts.ci = makeEl('ci'));
      if (sel === '.py') return el._parts.py || (el._parts.py = makeEl('py'));
      if (sel === '.mean') return el._parts.mean || (el._parts.mean = makeEl('mean'));
      return null;
    },
    style: {}, lastChild: null, _parts: {},
    replaceChildren(){ el.children.length = 0; }
  };
  el._h = {};
  return el;
}

const registry = {};
const ids = ['scene', 'menuMask', 'pauseMask', 'overMask', 'overTitle', 'overText',
  'startBtn', 'pauseBtn', 'resetBtn', 'soundBtn', 'voiceBtn', 'themeBtn', 'exportBtn',
  'seedInp', 'popup', 'foot', 'selftestBox', 'modeSingle', 'modeDemo'];
ids.forEach(id => { registry[id] = makeEl(id); });
const canvas = registry.scene;
canvas.width = 960; canvas.height = 640;
canvas.getContext = () => ctxStub();
canvas.toDataURL = () => 'data:image/png;base64,stub';

const doc = {
  documentElement: { dataset: { theme: 'light' }, style: {} },
  body: { classList: makeEl('body').classList, dataset: {} },
  getElementById: id => registry[id] || null,
  createElement: tag => makeEl(tag),
  addEventListener(type, fn){ (doc._h[type] = doc._h[type] || []).push(fn); },
  _fire(type, ev){ (doc._h[type] || []).forEach(f => f(ev || {})); },
  _h: {}
};
let rafQueue = [];
const win = {
  document: doc,
  location: { search: process.argv[2] || '?auto=1&demo=1&seed=7&theme=light' },
  matchMedia: () => ({ matches: false }),
  addEventListener: doc.addEventListener,
  requestAnimationFrame: fn => { rafQueue.push(fn); return rafQueue.length; },
  setTimeout: (fn) => 0,
  URLSearchParams: URLSearchParams,
  getComputedStyle: () => ({ getPropertyValue: k => '#123456' }),
  AudioContext: undefined, webkitAudioContext: undefined,
  speechSynthesis: undefined, SpeechSynthesisUtterance: undefined,
  localStorage: { _d: {}, getItem(k){ return this._d[k] || null; }, setItem(k, v){ this._d[k] = String(v); } },
  performance: { now: () => Date.now() }
};

function run(){
  const fn = new Function('window', 'document', 'console', 'performance', 'requestAnimationFrame',
    'URLSearchParams', 'getComputedStyle', 'setTimeout', 'addEventListener', 'matchMedia', 'location', src);
  fn(win, doc, console, win.performance, win.requestAnimationFrame, URLSearchParams,
     win.getComputedStyle, win.setTimeout, doc.addEventListener, win.matchMedia, win.location);
}

const qs = new URLSearchParams(win.location.search);
const simSeconds = +(qs.get('sim') || 60);
try{ run(); }catch(e){ errors.push('init: ' + e.stack.split('\n').slice(0, 2).join(' | ')); }

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
ok(g && g.S, 'window.__game 暴露内核');

if (g){
  const S = g.S;
  const auto = qs.get('auto') === '1';
  if (!auto){
    ok(S.phase === 'menu', '无参数打开时停在菜单', S.phase);
    ok(registry.menuMask.classList.contains('show'), '菜单遮罩可见');
    ok(registry.foot.textContent.includes('成语'), '页脚渲染了题库信息');
  } else {
    ok(S.phase !== 'menu', 'auto=1 跳过菜单', S.phase);
    ok(S.demo === (qs.get('demo') === '1'), '模式与参数一致', String(S.demo));
    ok(S.stats.questions >= 1, '出题了', String(S.stats.questions));
    ok(S.stats.correct >= 1, 'AI 答对过', String(S.stats.correct));
  }
  ok(!/NaN|undefined/.test(String(S.score) + String(S.elapsed) + String(S.speed)),
    'HUD 数字不含 NaN/undefined', S.score + '/' + S.elapsed.toFixed(1) + '/' + S.speed.toFixed(1));
  try{
    const u = canvas.toDataURL('image/png');
    ok(typeof u === 'string' && u.startsWith('data:image/png'), '可导出 PNG');
  }catch(e){ ok(false, '可导出 PNG', String(e)); }

  // 弹层：答对后应显示成语 / 拼音 / 释义
  const popup = registry.popup;
  const ci = popup.querySelector('.ci'), py = popup.querySelector('.py'), mean = popup.querySelector('.mean');
  ok(popup.classList.contains('show'), '弹层已显示');
  ok(ci && ci.children.length === 4, '弹层里四个汉字', ci ? String(ci.children.length) : 'none');
  ok(py && py.textContent.length > 0, '弹层有拼音', py ? py.textContent : '');
  ok(mean && mean.textContent.length > 0, '弹层有释义', mean ? mean.textContent : '');

  const before = errors.length;
  try{
    doc._fire('keydown', { key: 'ArrowLeft', code: 'ArrowLeft', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'ArrowRight', code: 'ArrowRight', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'a', code: 'KeyA', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'd', code: 'KeyD', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: ' ', code: 'Space', preventDefault(){} });
    doc._fire('keydown', { key: 'p', code: 'KeyP', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 't', code: 'KeyT', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'm', code: 'KeyM', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'v', code: 'KeyV', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'r', code: 'KeyR', preventDefault(){}, target: {} });
    doc._fire('keydown', { key: 'e', code: 'KeyE', preventDefault(){}, target: {} });
    canvas._fire('pointerdown', { clientX: 480, clientY: 500, pointerType: 'touch', pointerId: 1 });
    canvas._fire('pointermove', { clientX: 560, clientY: 500, pointerType: 'touch', pointerId: 1 });
    doc._fire('pointerup', { pointerId: 1 });
    canvas._fire('click', { clientX: 500, clientY: 560, pointerType: 'mouse' });
    ids.forEach(id => { try{ registry[id]._fire('click', { target: { closest: () => null } }); }catch(e){} });
    let t2 = win.performance.now() + 1000;
    for (let i = 0; i < 120 && rafQueue.length; i++){ const fns = rafQueue; rafQueue = []; t2 += 16.7; fns.forEach(f => f(t2)); }
  }catch(e){ errors.push('events: ' + e.stack.split('\n').slice(0, 3).join(' | ')); }
  ok(errors.length === before, '键盘 / 指针 / 按钮事件均无异常');
}

console.log(errors.length ? `\n${errors.length} problems` : '\nUI harness clean');
process.exit(errors.length ? 1 : 0);
