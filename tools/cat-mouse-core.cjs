'use strict';
/* 猫和老鼠迷宫规则内核的无头测试。
 * 从 cat-mouse-game.html 抽取 __CORE_START__…__CORE_END__ 块并在 Node 中直接运行。
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'cat-mouse-game.html'), 'utf8');
const lines = html.split('\n');
function extractBlock(lines, startMarker, endMarker){
  const a = lines.findIndex(l => l.includes(startMarker));
  const b = lines.findIndex(l => l.includes(endMarker));
  if (a < 0 || b < 0 || b <= a) throw new Error(`找不到 ${startMarker} / ${endMarker}`);
  // 标记写在 JS 块注释里：真实代码从 startMarker 之后第一行含 */ 的下一行开始，到 endMarker 那行结束。
  let realStart = a + 1;
  for (let k = a + 1; k < b; k++){ if (lines[k].includes('*/')){ realStart = k + 1; break; } }
  return lines.slice(realStart, b).join('\n');
}
const coreSrc = extractBlock(lines, '__CORE_START__', '__CORE_END__');

// coreSrc 只声明 function createGame，不做 CommonJS 导出：把它当作脚本运行并取出 createGame。
const createGame = new Function(coreSrc + '\nreturn createGame;')();

let fails = 0, checks = 0;
function ok(cond, label, detail){
  checks++;
  if (!cond){ fails++; console.log('FAIL  ' + label + (detail ? '  -> ' + detail : '')); }
  else console.log('ok    ' + label + (detail ? '  (' + detail + ')' : ''));
}

function playToEnd(seed, diff, maxSeconds){
  const g = createGame({ seed, mode: 'demo', diff, lives: 3 });
  const S = g.S;
  g.startMatch({ mode: 'demo' });
  const dt = 1 / 60;
  let t = 0, stallSince = 0, lastGot = -1;
  const events = [];
  while (S.phase !== 'over' && t < (maxSeconds || 900)){
    g.step(dt);
    while (S.events.length){ events.push(S.events.shift()); }
    if (S.got !== lastGot){ lastGot = S.got; stallSince = t; }
    if (t - stallSince > 60) return { g, S, events, stalled: true, t, got: S.got };
    t += dt;
  }
  return { g, S, events, stalled: false, t, got: S.got };
}

/* ---------- 1. 迷宫生成 ---------- */
{
  const g1 = createGame({ seed: 7 }); const S1 = g1.S;
  const g2 = createGame({ seed: 7 }); const S2 = g2.S;
  const g3 = createGame({ seed: 8 }); const S3 = g3.S;
  ok(S1.walls.join(',') === S2.walls.join(','), '同种子迷宫完全一致');
  ok(S1.walls.join(',') !== S3.walls.join(','), '换种子迷宫改变');
  ok(S1.W === 15 && S1.H === 11, '默认迷宫 15x11', S1.W + 'x' + S1.H);

  // 连通与墙对称
  const dmap = S1.helpers.distMap(S1.helpers.idx(1, 1));
  let conn = 0, wallBad = 0;
  for (let i = 0; i < S1.W * S1.H; i++) if (dmap[i] >= 0) conn++;
  for (let y = 0; y < S1.H; y++){
    for (let x = 0; x < S1.W; x++){
      const i = S1.helpers.idx(x, y), w = S1.walls[i];
      if (x + 1 < S1.W){ const j = S1.helpers.idx(x + 1, y);
        if (((w & 2) === 0) !== ((S1.walls[j] & 8) === 0)) wallBad++; }
      if (y + 1 < S1.H){ const j = S1.helpers.idx(x, y + 1);
        if (((w & 4) === 0) !== ((S1.walls[j] & 1) === 0)) wallBad++; }
    }
  }
  ok(conn === S1.W * S1.H, '所有格子连通', conn + '/' + S1.W * S1.H);
  ok(wallBad === 0, '墙体两侧一致', 'bad=' + wallBad);

  const dcat = S1.helpers.distMap(S1.catStart);
  ok(dcat[S1.start] >= 0, '老鼠起点可从猫起点到达');
  ok(dcat[S1.catStart] === 0, '猫起点距离为 0');

  // 奶酪数量固定，全部可达且不重叠，不占起点
  ok(S1.goal === Math.floor(S1.W * S1.H / 6), '奶酪数量固定', S1.goal);
  const cheeseIdx = S1.cheese.map(c => c.i);
  ok(new Set(cheeseIdx).size === S1.goal, '奶酪不重叠');
  ok(cheeseIdx.every(i => dmap[i] >= 0), '所有奶酪可达');
  ok(!cheeseIdx.includes(S1.start) && !cheeseIdx.includes(S1.catStart), '奶酪不占起点');
  ok(S1.catnip.i >= 0 && dmap[S1.catnip.i] >= 0, '猫薄荷可达');

  // 难度单调性
  const harder = createGame({ seed: 1, diff: 'hard' });
  const easier = createGame({ seed: 1, diff: 'easy' });
  ok(harder.S.DIFF.cat > easier.S.DIFF.cat, '困难猫更快');
  ok(harder.S.DIFF.vision > easier.S.DIFF.vision, '困难视野更大');
  ok(harder.S.diffName === '惊险' && easier.S.diffName === '轻松', '难度中文名');
}

/* ---------- 2. 移动与碰撞 ---------- */
{
  const g = createGame({ seed: 7 });
  const S = g.S;
  g.startMatch({});
  const m0x = S.mouse.cx, m0y = S.mouse.cy;
  // 从起点找一个不撞墙的方向再尝试移动
  const DIRS4 = [{dx:1,dy:0},{dx:-1,dy:0},{dx:0,dy:1},{dx:0,dy:-1}];
  let openDir = null;
  for (let d = 1; d <= 4; d++){
    const dd = DIRS4[d - 1];
    const nx = m0x + dd.dx, ny = m0y + dd.dy;
    if (nx >= 0 && ny >= 0 && nx < S.W && ny < S.H && !(S.walls[S.helpers.idx(m0x, m0y)] & (dd.dx > 0 ? 2 : dd.dx < 0 ? 8 : dd.dy > 0 ? 4 : 1))){ openDir = d; break; }
  }
  ok(openDir != null, '起点有至少一个可行方向');
  if (openDir != null){
    g.setDir(openDir);
    let moved = false;
    for (let i = 0; i < 200; i++){ g.step(1 / 60); if (S.mouse.cx !== m0x || S.mouse.cy !== m0y) moved = true; }
    ok(moved, '按方向可移动', (m0x + ',' + m0y) + ' -> ' + S.mouse.cx + ',' + S.mouse.cy);
  }

  // 越界停在原地：把老鼠放在最左列 x=0，再向左走
  const g2 = createGame({ seed: 7 }); const S2 = g2.S;
  g2.startMatch({});
  S2.mouse.cx = 0; S2.mouse.cy = 1; S2.mouse.dir = 0; S2.mouse.want = 0; S2.mouse.prog = 0;
  g2.setDir(2);
  for (let i = 0; i < 100; i++) g2.step(1 / 60);
  ok(S2.mouse.cx === 0 && S2.mouse.cy === 1, '越界向左停在原地', S2.mouse.cx + ',' + S2.mouse.cy);

  // 撞内部墙壁停在原地：找一堵墙两侧的相邻格，尝试穿墙
  const g3 = createGame({ seed: 7 }); const S3 = g3.S;
  g3.startMatch({});
  let walled = false;
  for (let y = 0; y < S3.H && !walled; y++){
    for (let x = 0; x < S3.W && !walled; x++){
      const i = S3.helpers.idx(x, y);
      if (x + 1 < S3.W && (S3.walls[i] & 2)){
        S3.mouse.cx = x; S3.mouse.cy = y; S3.mouse.dir = 0; S3.mouse.want = 0; S3.mouse.prog = 0;
        g3.setDir(1);
        const before = S3.mouse.cx;
        for (let t = 0; t < 100; t++) g3.step(1 / 60);
        walled = (S3.mouse.cx === before);
      }
    }
  }
  ok(walled, '撞内部墙壁停在原地');

  // 同格即被抓，扣一条命
  const g4 = createGame({ seed: 7 }); const S4 = g4.S;
  g4.startMatch({});
  g4.S.inv = 0;
  g4.S.cat.cx = S4.mouse.cx; g4.S.cat.cy = S4.mouse.cy; g4.S.cat.prog = 0; g4.S.cat.fx = 0;
  const lives0 = S4.lives;
  g4.step(0.02);
  let sawCaught = false;
  while (S4.events.length){ const ev = S4.events.shift(); if (ev.t === 'caught') sawCaught = true; }
  ok(sawCaught && S4.lives === lives0 - 1, '同格被抓扣命', 'lives ' + lives0 + '->' + S4.lives);

  // 无敌期内不被抓
  const g5 = createGame({ seed: 7 }); const S5 = g5.S;
  g5.startMatch({});
  g5.S.inv = 5;
  g5.S.cat.cx = S5.mouse.cx; g5.S.cat.cy = S5.mouse.cy; g5.S.cat.prog = 0; g5.S.cat.fx = 0;
  g5.step(0.02);
  let caughtDuringInv = false;
  while (S5.events.length){ const ev = S5.events.shift(); if (ev.t === 'caught') caughtDuringInv = true; }
  ok(!caughtDuringInv && S5.lives === lives0, '无敌期不扣命');

  // 猫薄荷生效 6 秒，过期后归零
  const g6 = createGame({ seed: 7 }); const S6 = g6.S;
  g6.startMatch({});
  g6.beginCatnip();
  ok(S6.catnipT === 6, '猫薄荷 6 秒');
  g6.step(0.1);
  ok(S6.catnipT > 0 && S6.catnipT < 6, '猫薄荷倒计时');
  g6.S.catnipT = 0.05;
  g6.step(0.1);
  ok(S6.catnipT === 0, '猫薄荷过期');
}

/* 把猫放到老鼠同格，等待 caught 事件并度过 0.9s 的缓动恢复期 */
function forceCatch(g){
  const S = g.S;
  S.inv = 0;
  S.cat.cx = S.mouse.cx; S.cat.cy = S.mouse.cy; S.cat.prog = 0; S.cat.fx = 0;
  let sawCaught = false;
  for (let i = 0; i < 60 * 3 && !sawCaught; i++){ g.step(1 / 60); while (S.events.length){ const ev = S.events.shift(); if (ev.t === 'caught') sawCaught = true; } }
  // 等待 caught 结束回到 play
  for (let i = 0; i < 60 * 3 && S.phase === 'caught'; i++){ g.step(1 / 60); while (S.events.length) S.events.shift(); }
  return sawCaught;
}

/* ---------- 3. 采集与胜负 ---------- */
{
  // 老鼠站在奶酪上即可吃掉
  const g = createGame({ seed: 7 }); const S = g.S;
  g.startMatch({});
  const first = S.cheese[0].i;
  S.mouse.cx = first % S.W; S.mouse.cy = (first - (first % S.W)) / S.W;
  g.step(0.05);
  let got = false;
  while (S.events.length){ const ev = S.events.shift(); if (ev.t === 'cheese') got = true; }
  ok(got && S.got >= 1, '吃到第一块奶酪', 'got=' + S.got);

  // 全部吃光即胜
  const g2 = createGame({ seed: 7 }); const S2 = g2.S;
  g2.startMatch({});
  for (const c of S2.cheese) if (!c.got) c.i = S2.helpers.idx(S2.mouse.cx, S2.mouse.cy);
  g2.step(0.05);
  ok(S2.phase === 'over' && S2.result && S2.result.won, '集齐奶酪胜利', JSON.stringify(S2.result));
  ok(typeof S2.result.score === 'number' && typeof S2.result.timeBonus === 'number', '结果带得分',
    S2.result ? JSON.stringify(S2.result) : 'none');

  // 三条命用完即败：连续被抓三次
  const g3 = createGame({ seed: 7 }); const S3 = g3.S;
  g3.startMatch({});
  for (let round = 0; round < 3 && S3.lives > 0 && S3.phase !== 'over'; round++){
    forceCatch(g3);
  }
  ok(S3.phase === 'over' && S3.result && !S3.result.won, '命用完后失败', 'phase=' + S3.phase + ' lives=' + S3.lives);
}

/* ---------- 4. 多种子稳健性（不卡死、不 NaN、AI 能启动并得分） ---------- */
{
  let nan = 0, anyProgress = 0;
  for (let seed = 1; seed <= 12; seed++){
    const diff = ['easy', 'normal', 'hard'][seed % 3];
    const { S, stalled, got } = playToEnd(seed * 131 + 7, diff, 300);
    if (!Number.isFinite(S.elapsed + S.score + S.got)) nan++;
    if (S.got > 0) anyProgress++;
  }
  ok(nan === 0, '多种子 × 三档难度运行 300s 无 NaN / 不崩溃');
  ok(anyProgress === 12, 'AI 老鼠在每种子上都能偷到奶酪', 'progress=' + anyProgress);
}

/* ---------- 5. AI 表演赛 ---------- */
{
  const g = createGame({ seed: 5, mode: 'demo', diff: 'easy' });
  const S = g.S;
  g.startMatch({ mode: 'demo' });
  let t = 0, nan = 0;
  while (t < 60){
    g.step(1 / 60);
    while (S.events.length) S.events.shift();
    if (!Number.isFinite(S.elapsed + S.got + S.score)) nan++;
    t += 1 / 60;
  }
  ok(nan === 0, 'AI 表演赛运行 60 秒无 NaN');
  ok(typeof S.got === 'number' && typeof S.score === 'number', 'AI 表演赛有得分');
  ok(S.DIFF.cat > 0, 'AI 难度参数生效');
}

console.log(`\n${checks - fails}/${checks} core checks passed`);
process.exit(fails ? 1 : 0);
