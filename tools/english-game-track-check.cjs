'use strict';
/* 轨道几何体检：曲率、越界、环完整性、车厢间距 */
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const L = fs.readFileSync(path.join(root, 'english-game.html'), 'utf8').split('\n');
const a = L.indexOf('// __CORE_START__'), b = L.indexOf('// __CORE_END__');
const out = path.join(root, '.verify', 't.cjs');
fs.writeFileSync(out, L.slice(a + 1, b).join('\n') +
  '\nmodule.exports={buildTrack,trackAt,TRACK_LOOP,TRACK_ENTRY,TRACK_EXIT,isLoopRegion,smoothPts,sampleSpline,sampleLoop};');
const K = require(out);

const CART_LEN = 46;          // 车身约 46px
const tk = K.buildTrack({ per: 3 });
let maxStep = 0, atStep = 0, minR = Infinity, atR = 0;
for (let i = 1; i < tk.pts.length; i++){
  const p = tk.pts[i], q = tk.pts[i - 1];
  let d = Math.abs(p.ang - q.ang); if (d > Math.PI) d = Math.PI * 2 - d;
  const ds = Math.hypot(p.x - q.x, p.y - q.y);
  if (d > maxStep){ maxStep = d; atStep = p.u; }
  const r = d > 1e-6 ? ds / d : Infinity;
  if (r < minR){ minR = r; atR = p.u; }
}
const ys = tk.pts.map(p => p.y), xs = tk.pts.map(p => p.x);
const LP = K.TRACK_LOOP;
let top = Infinity, bot = -Infinity, left = Infinity, right = -Infinity, near = 0;
for (const p of tk.pts){
  if (Math.hypot(p.x - LP.cx, p.y - LP.cy) < LP.r + 14){
    near++; top = Math.min(top, p.y); bot = Math.max(bot, p.y);
    left = Math.min(left, p.x); right = Math.max(right, p.x);
  }
}
/* 自交检查：非相邻段是否交叉（环与落坡交叉就是这里发现的） */
function segHit(p1, p2, p3, p4){
  const d = (p2[0]-p1[0])*(p4[1]-p1[1]) - (p2[1]-p1[1])*(p4[0]-p1[0]);
  if (Math.abs(d) < 1e-9) return false;
  const t = ((p3[0]-p1[0])*(p4[1]-p1[1]) - (p3[1]-p1[1])*(p4[0]-p1[0])) / d;
  const s = ((p3[0]-p1[0])*(p2[1]-p1[1]) - (p3[1]-p1[1])*(p2[0]-p1[0])) / d;
  return t > 0.01 && t < 0.99 && s > 0.01 && s < 0.99;
}
let crossings = [];
const P = tk.pts.map(p => [p.x, p.y]);
for (let i = 0; i < P.length - 1; i++){
  for (let j = i + 3; j < P.length - 1; j++){
    if (segHit(P[i], P[i+1], P[j], P[j+1])){
      const key = Math.round(tk.pts[i].u * 100) + '-' + Math.round(tk.pts[j].u * 100);
      if (!crossings.includes(key)) crossings.push(key);
    }
  }
}
console.log('points', tk.pts.length, 'length', Math.round(tk.length));
console.log('bbox x', Math.min(...xs).toFixed(0) + '..' + Math.max(...xs).toFixed(0),
            'y', Math.min(...ys).toFixed(0) + '..' + Math.max(...ys).toFixed(0));
console.log('max step', (maxStep * 180 / Math.PI).toFixed(1) + '° @u=' + atStep.toFixed(3),
            '| min turn radius', minR.toFixed(0), 'px @u=' + atR.toFixed(3),
            '| radius/cart', (minR / CART_LEN).toFixed(2));
console.log('loop bbox x', left.toFixed(0) + '..' + right.toFixed(0), 'y', top.toFixed(0) + '..' + bot.toFixed(0),
            'expected r', LP.r, 'span', (right - left).toFixed(0), (bot - top).toFixed(0), 'pts', near);
console.log('self crossings (u%)', crossings.length ? crossings.join(' ') : 'none');
const gapPx = 0.022 * tk.length;
console.log('cart gap', gapPx.toFixed(0), 'px  (4 cars ≈', (gapPx * 4).toFixed(0), 'px)');
