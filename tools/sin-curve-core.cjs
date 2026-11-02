'use strict';
/* 抽出 sin-curve.html 的纯数学内核（__CORE_START__ … __CORE_END__），
 * 在 Node 里直接跑断言，不需要浏览器。
 * 运行： node tools/sin-curve-core.cjs                                            */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'sin-curve.html'), 'utf8');
const lines = html.split('\n');
const a = lines.indexOf('// __CORE_START__');
const b = lines.indexOf('// __CORE_END__');
if (a < 0 || b < 0 || b <= a) { console.error('FAIL  找不到内核标记'); process.exit(1); }

const out = path.join(root, 'tools', 'out', 'sin-curve-core.cjs');
fs.mkdirSync(path.dirname(out), { recursive: true });
const body = lines.slice(a + 1, b).join('\n');
fs.writeFileSync(out, body + '\nmodule.exports = {'
  + 'curveY,phaseAngle,makeView,toPx,toWorld,yHalfFor,periodOf,sampleCurve,'
  + 'zeroCrossings,extrema,xTickStep,ticksIn,formatPi,normalizeAngle,circlePoint,'
  + 'probeXAt,fmt,PI,TAU};\n', 'utf8');

const K = require(out);
let fails = 0;
function ok(cond, label, detail) {
  if (cond) { console.log('ok    ' + label + (detail ? '  (' + detail + ')' : '')); return; }
  fails++; console.log('FAIL  ' + label + (detail ? '  (' + detail + ')' : ''));
}
const near = (x, y, t) => Math.abs(x - y) < (t === undefined ? 1e-9 : t);

const DEF = { A: 1, B: 1, C: 0, D: 0 };

/* ---------- 方程本身 ---------- */
ok(near(K.curveY(DEF, 0), 0), 'sin(0) = 0');
ok(near(K.curveY(DEF, K.PI / 2), 1), 'sin(π/2) = 1');
ok(near(K.curveY(DEF, K.PI), 0, 1e-12), 'sin(π) = 0');
ok(near(K.curveY(DEF, -K.PI / 2), -1), 'sin(−π/2) = −1');
ok(near(K.curveY(DEF, 2.3), K.curveY(DEF, 2.3 + K.TAU)), '周期 2π 重复');
ok(near(K.curveY(DEF, 0.7), K.curveY(DEF, K.PI - 0.7)), '关于 π/2 对称');
ok(K.curveY(DEF, 1.1) < K.curveY(DEF, 1.9), '0→π/2 上升段');
ok(K.curveY(DEF, 1.9) > K.curveY(DEF, 2.9), 'π/2→π 下降段');
const big = { A: 2.5, B: 3, C: 0.4, D: -1 };
for (const x of [-7.3, -1, 0, 0.5, 2.5, 9]) {
  ok(near(K.curveY(big, x), 2.5 * Math.sin(3 * x + 0.4) - 1), 'A/B/C/D 组合 x=' + x);
}
ok(near(K.curveY(big, 4.1), K.curveY(big, 4.1 + K.TAU / 3), 1e-12), 'B=3 周期为 2π/3');
ok(near(K.periodOf(DEF), K.TAU) && near(K.periodOf({ A: 1, B: 4, C: 0, D: 0 }), K.PI / 2), 'periodOf 正确');
ok(K.phaseAngle(big, 2) === 3 * 2 + 0.4, 'phaseAngle = Bx + C');
/* sin 与 cos 的关系：C = π/2 */
ok(near(K.curveY({ A: 1, B: 1, C: K.PI / 2, D: 0 }, 1.3), Math.cos(1.3)), '相位 π/2 即 cos');

/* ---------- 值域与视角 ---------- */
ok(near(K.yHalfFor(DEF), 1.55), '默认 y 半高 = 1 + 0.55');
ok(K.yHalfFor({ A: 2.4, B: 1, C: 0, D: 1 }) >= 3.4 + 0.55, '峰值+偏移能装进画布');
const v = K.makeView(2 * K.PI, K.yHalfFor(DEF), 900, 420, 26);
ok(v.x0 === -2 * K.PI && v.x1 === 2 * K.PI, 'makeView 对称范围');
for (const [x, y] of [[-6, 1.4], [0, 0], [3.5, -0.7], [2 * Math.PI, 1]]) {
  const p = K.toPx(v, x, y);
  const back = K.toWorld(v, p[0], p[1]);
  ok(near(back[0], x, 1e-9) && near(back[1], y, 1e-9), '坐标往返 x=' + x + ' y=' + y);
}
const mid = K.toPx(v, 0, 0);
ok(mid[0] > v.pad && mid[0] < v.w - v.pad && mid[1] > v.pad && mid[1] < v.h - v.pad, '原点落在绘图区内');
const left = K.toPx(v, v.x0, 0), right = K.toPx(v, v.x1, 0);
ok(left[0] < right[0], 'x 轴向右增大');
const top = K.toPx(v, 0, v.y1), bot = K.toPx(v, 0, v.y0);
ok(top[1] < bot[1], 'y 轴向上为像素减小方向（屏幕坐标正确）');

/* ---------- 采样 ---------- */
const pts = K.sampleCurve(DEF, v, 450);
ok(pts.length === 450, '采样点数 = 请求数');
ok(pts[0].x === v.x0 && near(pts[pts.length - 1].x, v.x1), '采样覆盖整个显示范围');
ok(pts.every(p => isFinite(p.y)), '所有采样点有限');
ok(pts.filter(p => Math.abs(p.y) === 1).length === 0, '网格点不会假造极值');
const maxP = pts.reduce((m, p) => (p.y > m.y ? p : m), pts[0]);
const minP = pts.reduce((m, p) => (p.y < m.y ? p : m), pts[0]);
ok(maxP.y > 0.99 && minP.y < -0.99, '采样能逼近 ±1', maxP.y.toFixed(3) + ' / ' + minP.y.toFixed(3));
ok(near(pts[224].y, Math.sin(pts[224].x)), '采样点确实满足方程');

/* ---------- 零点与极值 ---------- */
const zs = K.zeroCrossings(DEF, v);
ok(zs.length === 5, '±2π 内 5 个零点', zs.length + '');
ok(zs.every(z => near(z.y, 0) && z.x >= v.x0 - 1e-9 && z.x <= v.x1 + 1e-9), '零点在范围内且 y=0');
ok(zs.every(z => near(Math.sin(z.x), 0, 1e-12)), '零点满足 sin x = 0');
ok(zs[2].x === 0, '零点含 x=0');
const zs2 = K.zeroCrossings({ A: 1, B: 2, C: 0, D: 0 }, v);
ok(zs2.length === 9, 'B=2 时零点翻倍', zs2.length + '');
const zsd = K.zeroCrossings({ A: 1, B: 1, C: 0, D: 0.5 }, v);
ok(zsd.every(p => near(p.y, 0.5)), 'D=0.5 时零点标在 y=D 上');
const ex = K.extrema(DEF, v);
ok(ex.length === 4, '±2π 内 4 个极值', ex.length + '');
ok(ex.filter(e => e.max).every(e => near(e.y, 1)) && ex.filter(e => !e.max).every(e => near(e.y, -1)),
  '极大 = 1，极小 = −1', ex.map(e => (e.max ? 'max' : 'min') + '@' + K.fmt(e.x, 3)).join(', '));
ok(ex.filter(e => e.max).length === 2 && ex.filter(e => !e.max).length === 2, '极大极值各 2 个');
ok(ex.every(e => near(Math.abs(e.x), Math.PI / 2, 1e-9) || near(Math.abs(e.x), 3 * Math.PI / 2, 1e-9)),
  '极值出现在 π/2 的奇数倍', ex.map(e => K.fmt(e.x, 3)).join(', '));
const exd = K.extrema({ A: 2, B: 1, C: 0, D: 1 }, v);
ok(exd.filter(e => e.max).every(e => near(e.y, 3)) && exd.filter(e => !e.max).every(e => near(e.y, -1)),
  'A=2,D=1 极值为 3 / −1');
ok(K.extrema({ A: 1, B: 0.0001, C: 0, D: 0 }, v).length <= 2, '极低频不爆点');
ok(K.zeroCrossings({ A: 1, B: 0, C: 0, D: 0 }, v).length === 0, 'B=0 时不生成零点（防除零）');
ok(K.extrema({ A: 1, B: 0, C: 0, D: 0 }, v).length === 0, 'B=0 时不生成极值');

/* ---------- 刻度 ---------- */
const stepWide = K.xTickStep(v, 54);
ok(stepWide === K.PI / 2 || stepWide === K.PI, '默认范围给出 π/2 或 π 刻度', String(stepWide / K.PI) + 'π');
const perPx = stepWide / (v.x1 - v.x0) * (v.w - 2 * v.pad);
ok(perPx >= 54, '刻度间距不小于下限', perPx.toFixed(1) + 'px');
const tight = K.makeView(12 * K.PI, 1.55, 300, 200, 26);
ok(K.xTickStep(tight, 54) === K.TAU, '窄屏大范围退回 2π 刻度');
const tk = K.ticksIn(-K.PI, K.PI, K.PI / 2);
ok(tk.length === 5 && tk[0] === -K.PI && near(tk[2], 0), 'ticksIn 覆盖端点', tk.length + '');
ok(K.ticksIn(-1, 1, 0).length === 0 && K.ticksIn(NaN, 1, 1).length === 0, 'ticksIn 对非法输入返回空');

/* ---------- π 分数格式化 ---------- */
ok(K.formatPi(0) === '0', 'formatPi(0)');
ok(K.formatPi(K.PI / 2) === 'π/2', 'formatPi(π/2)', K.formatPi(K.PI / 2));
ok(K.formatPi(-K.PI / 2) === '−π/2', 'formatPi(−π/2)', K.formatPi(-K.PI / 2));
ok(K.formatPi(K.PI) === 'π', 'formatPi(π)', K.formatPi(K.PI));
ok(K.formatPi(-K.TAU) === '−2π', 'formatPi(−2π)', K.formatPi(-K.TAU));
ok(K.formatPi(K.TAU) === '2π', 'formatPi(2π)', K.formatPi(K.TAU));
ok(K.formatPi(3 * K.PI / 2) === '3π/2', 'formatPi(3π/2)', K.formatPi(3 * K.PI / 2));
ok(K.formatPi(K.PI / 4) === 'π/4', 'formatPi(π/4)', K.formatPi(K.PI / 4));
ok(K.formatPi(K.PI / 3) === 'π/3', 'formatPi(π/3)', K.formatPi(K.PI / 3));
ok(K.formatPi(2 * K.PI / 3) === '2π/3', '约分 2π/6 → 2π/3', K.formatPi(2 * K.PI / 3));
ok(K.formatPi(0.123) === K.fmt(0.123, 2), '无理倍数退回小数', K.formatPi(0.123));
ok(K.formatPi(NaN) === 'NaN', 'NaN 不抛错', K.formatPi(NaN));
ok(K.formatPi(6 * K.PI) === '6π', 'formatPi(6π)', K.formatPi(6 * K.PI));

/* ---------- 角度与扫描 ---------- */
ok(K.normalizeAngle(-K.PI / 2) === 3 * K.PI / 2, 'normalizeAngle 归到 [0,2π)');
ok(K.normalizeAngle(K.TAU) === 0, 'normalizeAngle(2π) = 0');
ok(K.normalizeAngle(7.5) === 7.5 - K.TAU && K.normalizeAngle(-7.5) > 0 && K.normalizeAngle(-7.5) < K.TAU,
  'normalizeAngle 收敛到 [0,2π)', K.fmt(K.normalizeAngle(7.5), 4));
const c1 = K.circlePoint(0, 1);
ok(near(c1.x, 1) && near(c1.y, 0), 'θ=0 在 (1,0)');
const c2 = K.circlePoint(K.PI / 2, 1);
ok(near(c2.x, 0, 1e-12) && near(c2.y, 1), 'θ=π/2 在 (0,1)');
for (const th of [0, 0.7, 2.4, 5.9]) {
  const p = K.circlePoint(th, 1);
  ok(near(p.x * p.x + p.y * p.y, 1, 1e-12), '单位圆恒等式 θ=' + th);
  ok(near(p.y, Math.sin(th)), '圆上 y 坐标 = sin θ');
}
const pv = K.makeView(K.PI, 1.55, 900, 420, 26);
for (const t of [0, 0.001, 3, 12.5, 999, 1e6]) {
  const x = K.probeXAt(t, pv);
  ok(x >= pv.x0 - 1e-9 && x <= pv.x1 + 1e-9, '扫描点不越界 t=' + t, K.fmt(x, 3));
}
ok(K.probeXAt(0, pv) === pv.x0, 't=0 从最左端开始');
const x1a = K.probeXAt(0.5, pv), x2a = K.probeXAt(1.5, pv);
ok(x2a > x1a, '扫描随时间向右推进', K.fmt(x1a, 3) + ' -> ' + K.fmt(x2a, 3));
/* 走完一整个来回（2π 相位）后回到起点，不会跳到范围外 */
const wrap = K.probeXAt((pv.x1 - pv.x0), pv);
ok(near(wrap, pv.x0, 1e-9), '扫完一圈回到左端点', K.fmt(wrap, 4));

/* ---------- 数字格式 ---------- */
ok(K.fmt(-0.5, 2) === '−0.50', 'fmt 使用真减号', K.fmt(-0.5, 2));
ok(K.fmt(0, 4) === '0.0000', 'fmt 固定位数');

console.log(fails ? '\n' + fails + ' 项失败' : '\n内核断言全部通过');
process.exit(fails ? 1 : 0);
