'use strict';
/* 用无头 Edge 抓取 english-game.html 的运行画面（改前 / 改后对比证据）。
 * 运行： node tools/english-game-shots.cjs            */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const OUT = path.join(root, 'docs', 'screenshots');
const EDGE = process.env.EDGE ||
  (fs.existsSync('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe')
    ? 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
    : 'C:/Program Files/Microsoft/Edge/Application/msedge.exe');

fs.mkdirSync(OUT, { recursive: true });

function fileUrl(p, q) {
  return 'file:///' + path.resolve(p).replace(/\\/g, '/') + (q || '');
}
function shot(target, query, png, w, h) {
  const out = path.join(OUT, png);
  const args = ['--headless', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
    '--window-size=' + w + ',' + h, '--screenshot=' + out, '--virtual-time-budget=6000',
    fileUrl(target, query)];
  try {
    execFileSync(EDGE, args, { stdio: ['ignore', 'ignore', 'ignore'], timeout: 120000 });
  } catch (e) { /* Edge 把日志写到 stderr，非零退出仍可能已写出文件 */ }
  const ok = fs.existsSync(out) && fs.statSync(out).size > 5000;
  console.log((ok ? 'ok    ' : 'FAIL  ') + png + (ok ? '  (' + Math.round(fs.statSync(out).size / 1024) + ' KB)' : ''));
  return ok;
}

const GAME = path.join(root, 'english-game.html');
const BASE = path.join(root, '.verify', 'main-baseline', 'index.html');

let bad = 0;
/* ---- 改前：main 分支的实际内容（仓库里没有任何学英语的游戏页面） ---- */
if (!shot(BASE, '?freeze=1', 'english-before-main-index.png', 1280, 940)) bad++;
if (!fs.existsSync(path.join(root, '.verify', 'main-baseline', 'english-game.html')))
  console.log('ok    确认 english-game.html 在 origin/main 上不存在（改前基线）');
else { console.log('FAIL  基线目录里出现了游戏页面'); bad++; }

/* ---- 改后：本分支的运行画面 ---- */
const shots = [
  ['?auto=1&unit=animals&word=cat&seed=7&freeze=4.2&sound=off', 'english-after-play.png', 1280, 940],
  ['?freeze=1', 'english-after-menu.png', 1280, 980],
  ['?auto=1&unit=colors&word=two&mode=cn&seed=11&freeze=3.1&sound=off', 'english-after-mode-cn.png', 1280, 940],
  ['?auto=1&unit=food&word=apple&mode=spell&seed=12&freeze=2.4&sound=off', 'english-after-mode-spell.png', 1280, 940],
  ['?auto=1&unit=animals&word=cat&seed=5&rounds=6&solve=3&freeze=6.5&sound=off', 'english-after-answered.png', 1280, 940],
  ['?auto=1&unit=animals&seed=9&rounds=8&solve=8&freeze=8.2&sound=off', 'english-after-results.png', 1280, 940],
  ['?auto=1&unit=school&word=tree&seed=4&theme=dark&freeze=5.0&sound=off', 'english-after-dark.png', 1280, 940],
  ['?auto=1&unit=animals&seed=2&freeze=3.6&sound=off&selftest=1', 'english-after-selftest.png', 1280, 1520],
  ['?auto=1&unit=animals&word=cat&seed=2&freeze=3.6&sound=off&ui=canvas', 'english-after-canvas-only.png', 960, 540],
  ['?auto=1&unit=colors&word=red&seed=8&freeze=4.0&sound=off', 'english-after-narrow-504x900.png', 504, 900]
];
shots.forEach(([q, name, w, h]) => { if (!shot(GAME, q, name, w, h)) bad++; });

console.log(bad ? '\n' + bad + ' screenshots missing' : '\nall screenshots written');
process.exit(bad ? 1 : 0);
