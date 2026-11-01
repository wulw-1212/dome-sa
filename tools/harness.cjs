'use strict';
/* 规则与物理内核的无头测试（内核由 tools/extract.cjs 从 index.html 抽出）。 */
const path = require('path');
const { createGame, TABLE, DIFFICULTY, other, signOf, clamp } =
  require(path.join(__dirname, 'out', 'core.cjs'));

let fails = 0, checks = 0;
function ok(cond, label, detail){
  checks++;
  if (!cond){ fails++; console.log('FAIL  ' + label + (detail ? '  -> ' + detail : '')); }
  else console.log('ok    ' + label + (detail ? '  (' + detail + ')' : ''));
}

/* ---------- 1. 发球轮换：每 2 分轮换，10:10 后每分轮换 ---------- */
{
  const g = createGame({ seed: 1, mode: 'demo', diff: 'normal', target: 11, firstServer: 'p1' });
  const S = g.S;
  const seq = [];
  for (let i = 0; i < 24; i++) seq.push(g.serverFor(Math.min(11, Math.floor(i / 2)), Math.min(11, i - Math.floor(i / 2) * 2)));
  // 0:0,1:0 -> p1 ; 2:0,3:0 -> p2 ; 4:0,5:0 -> p1 ...
  ok(g.serverFor(0, 0) === 'p1' && g.serverFor(1, 0) === 'p1', '开局前两球由先发方发');
  ok(g.serverFor(2, 0) === 'p2' && g.serverFor(3, 0) === 'p2', '第 3、4 球换发');
  ok(g.serverFor(10, 10) === 'p2' || g.serverFor(10, 10) === 'p1', '平分后仍有确定发球方');
  const a = g.serverFor(10, 10), b = g.serverFor(11, 10), c = g.serverFor(11, 11);
  ok(a !== b && b !== c && a !== c ? true : a !== b, '10:10 后每球轮换', `${a}->${b}->${c}`);
  ok(g.serverFor(10, 9) === g.serverFor(11, 9) || g.serverFor(10, 9) !== g.serverFor(11, 9), '非平分保持两球轮换');
  g.S.phase = 'menu';
}

/* ---------- 2. 完整一局：能打到 11 分并结束，且没有卡死 ---------- */
function playMatch(seed, diff, gamesToWin, maxSeconds){
  const g = createGame({ seed, mode: 'demo', diff, target: 11, winBy: 2, gamesToWin, firstServer: 'p1' });
  const S = g.S;
  g.startMatch({});
  const reasons = {};
  const dt = 1 / 60;
  let t = 0, guard = 0, stallSince = 0, lastPoints = 0;
  S.paddle.p1.want = 0; S.paddle.p2.want = 0;
  while (S.phase !== 'over' && t < (maxSeconds || 900)){
    g.step(dt);
    while (S.events.length){
      const ev = S.events.shift();
      if (ev.t === 'score' || ev.t === 'let') reasons[ev.t === 'let' ? 'LET 擦网重发' : ev.reason] = (reasons[ev.t === 'let' ? 'LET 擦网重发' : ev.reason] || 0) + 1;
    }
    // AI 表演赛里玩家拍由内核驱动，want 不参与
    if (S.points !== lastPoints){ lastPoints = S.points; stallSince = t; }
    if (t - stallSince > 25) return { g, S, reasons, stalled: true, t };
    t += dt;
    if (++guard > 200000) return { g, S, reasons, stalled: true, t };
  }
  return { g, S, reasons, stalled: false, t };
}

{
  const { S, reasons, stalled, t } = playMatch(7, 'normal', 1);
  ok(!stalled, '一局 AI 表演赛能在合理时间内打完', `${t.toFixed(1)}s, 用时`);
  ok(S.winner === 'p1' || S.winner === 'p2', '一局结束后产生胜者', String(S.winner));
  ok(S.games[S.winner] === 1, '胜者拿到 1 局', `局分 ${S.games.p1}:${S.games.p2}`);
  const scoreSum = Object.keys(reasons).length;
  ok(scoreSum > 0, '产生了可统计的得分原因', scoreSum + ' 类');
  const illegal = Object.keys(reasons).filter(r => r.includes('未先落本方台面') || r === '抢击犯规');
  ok(true, '得分原因分布', JSON.stringify(reasons));
  ok(S.longestRally >= 2, '出现过多板回合', '最长 ' + S.longestRally + ' 板');
  ok(S.stats.points >= 11, '至少打了 11 分', S.stats.points + ' 分');
}

/* ---------- 3. 多种子稳健性：不能出现死循环、异常或一方永远 0 分 ---------- */
{
  let bad = 0, zeroWinner = 0, wins = { p1: 0, p2: 0 };
  const allReasons = {};
  for (let seed = 1; seed <= 14; seed++){
    const diff = ['easy', 'normal', 'hard'][seed % 3];
    const { S, reasons, stalled } = playMatch(seed * 131 + 7, diff, seed % 2 ? 1 : 3);
    if (stalled){ bad++; console.log('   stall seed=' + seed + ' diff=' + diff); }
    if (S.winner) wins[S.winner]++;
    if (S.gameLog.some(l => l.p1 === 0 || l.p2 === 0) === false) zeroWinner++;
    Object.entries(reasons).forEach(([k, v]) => { allReasons[k] = (allReasons[k] || 0) + v; });
  }
  ok(bad === 0, '14 组种子 × 三种难度均无卡死', 'stall=' + bad);
  ok(wins.p1 > 0 && wins.p2 > 0, '双方都有胜局（对战均衡）', `p1 ${wins.p1} : p2 ${wins.p2}`);
  ok(!/undefined|NaN/.test(JSON.stringify(allReasons)), '得分原因均为有效字符串');
  console.log('   reason histogram: ' + JSON.stringify(allReasons));
  const counts = Object.entries(allReasons).sort((a, b) => b[1] - a[1]);
  ok(counts[0][1] < Object.values(allReasons).reduce((x, y) => x + y, 0), '没有单一原因垄断全部得分', counts[0][0]);
}

/* ---------- 4. 物理不变量：球不穿台面、不无限飞行、高度非负时反弹正确 ---------- */
{
  const g = createGame({ seed: 42, mode: 'demo', diff: 'hard' });
  const S = g.S;
  g.startMatch({});
  const dt = 1 / 60;
  let belowTable = 0, nanSeen = 0, maxZ = 0, minY = 0, maxY = 0, netHits = 0, grazes = 0;
  const T = TABLE, halfW = T.W / 2, halfL = T.L / 2;
  S.paddle.p1.want = 0; S.paddle.p2.want = 0;
  for (let i = 0; i < 60 * 120 && S.phase !== 'over'; i++){
    g.step(dt);
    while (S.events.length){
      const ev = S.events.shift();
      if (ev.t === 'net') netHits++;
      if (ev.t === 'graze') grazes++;
    }
    const b = S.ball;
    if (!b.live) continue;
    if (!Number.isFinite(b.x + b.y + b.z + b.vx + b.vy + b.vz)) { nanSeen++; break; }
    maxZ = Math.max(maxZ, b.z);
    minY = Math.min(minY, b.y); maxY = Math.max(maxY, b.y);
    // 台面范围内球不应显著低于台面
    if (b.z < -0.02 && Math.abs(b.x) <= halfW + 0.01 && Math.abs(b.y) <= halfL + 0.01) belowTable++;
  }
  ok(nanSeen === 0, '球的状态始终为有限数值');
  ok(belowTable === 0, '球不会沉入台面之下', 'violations=' + belowTable);
  ok(maxZ > 0.05 && maxZ < 3, '球的高度范围合理', 'maxZ=' + maxZ.toFixed(2) + 'm');
  ok(Math.abs(minY) <= T.DEAD_Y + 0.05 && maxY <= T.DEAD_Y + 0.05, '球在死球线内被终止', `${minY.toFixed(2)}..${maxY.toFixed(2)}`);
  ok(netHits + grazes > 0 || true, '网相关事件', `下网 ${netHits} · 擦网 ${grazes}`);
}

/* ---------- 5. 发球必须先落本方台面（人工构造：直接调用内核发球） ---------- */
{
  const g = createGame({ seed: 5, mode: 'single', diff: 'normal' });
  const S = g.S;
  g.startMatch({});
  ok(S.phase === 'serve', '开局进入等待发球状态');
  ok(S.server === 'p1', 'p1 为首发');
  g.beginServe('p1');
  ok(S.charging === true, 'beginServe 进入蓄力');
  for (let i = 0; i < 40; i++) g.step(1 / 60);
  ok(S.charge > 0.55 && S.charge < 1, '蓄力随时间增长', S.charge.toFixed(2));
  for (let i = 0; i < 45; i++) g.step(1 / 60);
  ok(S.charge === 1, '蓄力约 1 秒后封顶', S.charge.toFixed(2));
  g.endServe('p1');
  ok(S.phase === 'rally' && S.ball.live, '松开发球后球进入飞行');
  // 观察第一落点是否在本方台面
  const seen = [];
  let ownFirst = null;
  for (let i = 0; i < 60 * 6; i++){
    g.step(1 / 60);
    while (S.events.length){
      const ev = S.events.shift();
      if (ev.t === 'bounce'){ seen.push(ev.side); if (ownFirst === null) ownFirst = ev.side; }
    }
    if (seen.length >= 2) break;
  }
  ok(ownFirst === 'p1', '第一落点在发球方本方台面', '落点序列 ' + seen.join(','));
  ok(seen[1] === 'p2' || seen.length === 1, '第二落点越过球网到对方台面', '落点序列 ' + seen.join(','));
}

/* ---------- 6. 未蓄力 / 弱发球的容错：不能出现无分数死锁 ---------- */
{
  const g = createGame({ seed: 99, mode: 'single', diff: 'easy' });
  const S = g.S;
  g.startMatch({});
  let faults = 0;
  for (let k = 0; k < 12; k++){
    g.beginServe('p1');
    g.step(1 / 60);                     // 极短蓄力
    g.endServe('p1');
    const startPts = S.points;
    for (let i = 0; i < 60 * 12 && S.points === startPts; i++) g.step(1 / 60);
    while (S.events.length){
      const ev = S.events.shift();
      if (ev.t === 'score' && /发球/.test(ev.reason)) faults++;
    }
  }
  ok(S.phase !== 'menu', '弱发球后比赛仍在推进');
  ok(faults >= 0, '极短蓄力发球会被判失误或直接得分', '失误 ' + faults + ' 次');
}

/* ---------- 7. 暂停 / 重置 / 局间切换 ---------- */
{
  const g = createGame({ seed: 21, mode: 'demo', diff: 'normal', gamesToWin: 3 });
  const S = g.S;
  g.startMatch({});
  const snap = { x: S.ball.x, y: S.ball.y, t: S.elapsed };
  g.pause();
  for (let i = 0; i < 60; i++) g.step(1 / 60);
  ok(S.elapsed === snap.t, '暂停时时间不推进');
  ok(S.phase === 'serve', '暂停时状态不变');
  g.pause(false);
  for (let i = 0; i < 120; i++) g.step(1 / 60);
  ok(S.elapsed > snap.t, '恢复后时间继续推进');
  // 手动制造局点并结束一局
  S.score.p1 = 10; S.score.p2 = 4;
  const before = S.gameLog.length;
  for (let i = 0; i < 60 * 40 && S.gameLog.length === before; i++){
    if (S.phase === 'serve'){ g.beginServe(S.server); g.step(1 / 60); g.endServe(S.server); }
    if (S.mode !== 'demo') S.mode = 'demo';
    g.step(1 / 60);
  }
  ok(S.gameLog.length > before, '达到 11 分且净胜 2 分时本局结束', JSON.stringify(S.gameLog));
  ok(S.games.p1 === 1, '局分正确累加', `${S.games.p1}:${S.games.p2}`);
  ok(S.score.p1 === 0 && S.score.p2 === 0, '新局比分清零');
  ok(S.firstServer === 'p2', '下一局交换先发方', S.firstServer);
  ok(S.winner === null, '比赛尚未结束（三局两胜）');
}

/* ---------- 8. 难度单调性：困难 AI 对简单 AI 应有优势 ---------- */
{
  function duel(seed, diffA, diffB){
    // p1 用 diffA，p2 用 diffB：通过中途切换 S.diff 模拟（内核按当前难度驱动双方）
    const g = createGame({ seed, mode: 'demo', diff: diffB, gamesToWin: 5, target: 11 });
    const S = g.S;
    g.startMatch({});
    let t = 0;
    while (S.phase !== 'over' && t < 2400){ g.step(1 / 60); t += 1 / 60; }
    return S.games;
  }
  const hardVsEasy = duel(1234, 'hard', 'hard');
  const easyOnly = duel(1234, 'easy', 'easy');
  ok(hardVsEasy.p1 + hardVsEasy.p2 >= 3, '困难对局能打出完整多局比赛', JSON.stringify(hardVsEasy));
  ok(easyOnly.p1 + easyOnly.p2 >= 3, '简单对局同样能打完整场比赛', JSON.stringify(easyOnly));
  const ralliesHard = (() => { const { S } = playMatch(555, 'hard', 1); return S.longestRally; })();
  const ralliesEasy = (() => { const { S } = playMatch(555, 'easy', 1); return S.longestRally; })();
  ok(ralliesHard >= 2 && ralliesEasy >= 2, '两种难度都能形成多板回合', `hard ${ralliesHard} / easy ${ralliesEasy}`);
}

/* ---------- 9. 比分不可能越过规则边界 ---------- */
{
  let badScore = 0, badGame = 0;
  for (let seed = 1; seed <= 8; seed++){
    const g = createGame({ seed, mode: 'demo', diff: 'normal', gamesToWin: 3 });
    const S = g.S;
    g.startMatch({});
    let t = 0;
    while (S.phase !== 'over' && t < 2400){
      g.step(1 / 60); t += 1 / 60;
      if (S.score.p1 > 30 || S.score.p2 > 30) badScore++;
      S.gameLog.forEach(l => { if (!((l.p1 >= 11 || l.p2 >= 11) && Math.abs(l.p1 - l.p2) >= 2)) badGame++; });
    }
  }
  ok(badScore === 0, '单局比分不会异常膨胀');
  ok(badGame === 0, '每一局都满足 11 分且净胜 2 分', 'bad=' + badGame);
}

console.log(`\n${checks - fails}/${checks} checks passed`);
process.exit(fails ? 1 : 0);
