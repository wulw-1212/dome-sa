'use strict';
/* 成语大飞车规则内核的无头测试。
 * 从 idiom-driving.html 抽取 __CORE_START__…__CORE_END__ 块并在 Node 中直接运行。
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'idiom-driving.html'), 'utf8');
const lines = html.split('\n');

function extractBlock(lines, startMarker, endMarker){
  const a = lines.findIndex(l => l.includes(startMarker));
  const b = lines.findIndex(l => l.includes(endMarker));
  if (a < 0 || b < 0 || b <= a) throw new Error(`找不到 ${startMarker} / ${endMarker}`);
  // 标记写在 JS 块注释里：真实代码从 startMarker 之后第一行含 */ 的下一行开始。
  let realStart = a + 1;
  for (let k = a + 1; k < b; k++){ if (lines[k].includes('*/')){ realStart = k + 1; break; } }
  return lines.slice(realStart, b).join('\n');
}
const coreSrc = extractBlock(lines, '__CORE_START__', '__CORE_END__');
const createGame = new Function(coreSrc + '\nreturn createGame;')();

let fails = 0, checks = 0;
function ok(cond, label, detail){
  checks++;
  if (!cond){ fails++; console.log('FAIL  ' + label + (detail ? '  -> ' + detail : '')); }
  else console.log('ok    ' + label + (detail ? '  (' + detail + ')' : ''));
}

/* 跑到第一题出现为止 */
function firstQuestion(g){
  for (let i = 0; i < 400 && !g.S.question; i++) g.step(1 / 60);
  return g.S.question;
}
/* 等到一道「还没结算」的全新题目 */
function freshQuestion(g, prev){
  for (let i = 0; i < 3000; i++){
    g.step(1 / 60);
    if (g.S.question && g.S.question !== prev && !g.S.question.resolved) return g.S.question;
  }
  return null;
}
function drain(g, onEvent){
  while (g.S.events.length){
    const ev = g.S.events.shift();
    if (onEvent) onEvent(ev);
  }
}

/* ---------- 1. 题库 ---------- */
{
  const g = createGame({ seed: 1 });
  const ok1 = g.S;
  ok(ok1.phase === 'menu', '初始停在菜单', ok1.phase);
  const idio = new Function(coreSrc + '\nreturn IDIOMS;')();
  ok(idio.length >= 24, '题库条数足够', idio.length);
  ok(idio.every(x => Array.from(x.t).length === 4), '每条都是四字成语');
  ok(idio.every(x => /^[a-zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü\s]+$/.test(x.p)), '拼音格式正常');
  ok(idio.every(x => x.m && x.m.length >= 4), '每条都有释义');
  ok(new Set(idio.map(x => x.t)).size === idio.length, '成语不重复');
  ok(idio.every(x => /[一-龥]/.test(x.m)), '释义为中文');
}

/* ---------- 2. 出题 ---------- */
{
  const g1 = createGame({ seed: 900 }); g1.startMatch({});
  const g2 = createGame({ seed: 900 }); g2.startMatch({});
  const g3 = createGame({ seed: 901 }); g3.startMatch({});
  const seen1 = [], seen2 = [], seen3 = [];
  for (let i = 0; i < 60 * 120; i++){
    g1.step(1 / 60); g2.step(1 / 60); g3.step(1 / 60);
    for (const [g, arr] of [[g1, seen1], [g2, seen2], [g3, seen3]]){
      if (g.S.question && arr.indexOf(g.S.question.item.t) < 0) arr.push(g.S.question.item.t);
    }
  }
  ok(seen1.join('|') === seen2.join('|'), '同题序出题一致', seen1.length + ' 条');
  ok(seen1.join('|') !== seen3.join('|'), '换题序出题改变');
  ok(seen1.length >= 4, '题序会给出多道题', seen1.length);

  const g4 = createGame({ seed: 7 }); g4.startMatch({});
  const q = firstQuestion(g4);
  ok(!!q, '能出第一题');
  ok(q.tokens.length === 3, '三块字牌', q.tokens.length);
  const ansTok = q.tokens.filter(t => t.isAnswer)[0];
  ok(!!ansTok, '有答案牌');
  ok(ansTok && ansTok.lane === q.answerLane, '答案牌在 answerLane');
  ok(q.tokens.filter(t => t.ch === q.answer).length === 1, '正确答案只出现一次');
  ok(new Set(q.tokens.map(t => t.ch)).size === 3, '三字互不相同');
  ok(q.emptyLane >= 0 && q.emptyLane <= 3, '有明确的空车道');
  ok(!q.tokens.some(t => t.lane === q.emptyLane), '空车道上没有牌');
  ok(new Set(q.tokens.map(t => t.lane)).size === 3, '三条牌各占一条车道');
  ok(q.tokens.every(t => t.lane !== q.emptyLane), '没有牌落在空车道');
  ok(Array.from(q.item.t).length === 4, '原成语四字');
  // 缺的正是答案字
  const chars = Array.from(q.item.t);
  ok(chars[q.blankIdx] === q.answer, '缺口位置对应答案字');
  // 干扰字不是成语里的其它字
  const others = chars.filter((c, i) => i !== q.blankIdx);
  const distract = q.tokens.filter(t => !t.isAnswer).map(t => t.ch);
  ok(distract.every(d => others.indexOf(d) < 0), '干扰字不与成语其它字重复', distract.join(''));
}

/* ---------- 3. 变道 ---------- */
{
  const g = createGame({ seed: 7 }); g.startMatch({});
  ok(g.S.carLane === 1, '初始在中间车道', g.S.carLane);
  g.shift(-1); ok(g.S.carLane === 0, '左移一格');
  g.shift(-1); ok(g.S.carLane === 0, '左边界不越界');
  g.shift(1); g.shift(1); g.shift(1); ok(g.S.carLane === 3, '右移到最右');
  g.shift(1); ok(g.S.carLane === 3, '右边界不越界');
  g.setLane(2); ok(g.S.carLane === 2, 'setLane 生效');
  g.setLane(9); ok(g.S.carLane === 2, 'setLane 忽略非法值');
}

/* ---------- 4. 接对 / 接错 / 放跑 ---------- */
{
  // 接对
  const g = createGame({ seed: 7 }); g.startMatch({});
  const q = firstQuestion(g);
  g.setLane(q.answerLane);
  let correct = null;
  for (let i = 0; i < 900 && !correct; i++){ g.step(1 / 60); drain(g, ev => { if (ev.t === 'correct') correct = ev; }); }
  ok(!!correct, '接对触发 correct 事件');
  ok(correct && correct.idiom === q.item.t, '事件带完整成语');
  ok(correct && correct.p === q.item.p && correct.m === q.item.m, '事件带拼音与释义');
  ok(g.S.score >= 100, '接对得分', String(g.S.score));
  ok(g.S.stats.correct === 1, '正确计数', String(g.S.stats.correct));
  ok(g.S.combo === 1, '连击计数', String(g.S.combo));

  // 连击加成：连续两题都接对
  const g2 = createGame({ seed: 7 }); g2.startMatch({});
  let combos = [];
  for (let round = 0; round < 3; round++){
    const qq = freshQuestion(g2, null);
    if (!qq) break;
    g2.setLane(qq.answerLane);
    let hit = false;
    for (let i = 0; i < 900 && !hit; i++){
      g2.step(1 / 60);
      drain(g2, ev => { if (ev.t === 'correct') hit = true; });
    }
    combos.push(g2.S.combo);
  }
  ok(combos.length >= 2 && combos[1] === 2, '连续接对连击递增', combos.join(','));

  // 接错扣命
  const g3 = createGame({ seed: 7 }); g3.startMatch({});
  const q3 = firstQuestion(g3);
  const wrongLane = q3.tokens.filter(t => !t.isAnswer)[0].lane;
  g3.setLane(wrongLane);
  let wrong = null; const lives0 = g3.S.lives;
  for (let i = 0; i < 900 && !wrong; i++){ g3.step(1 / 60); drain(g3, ev => { if (ev.t === 'wrong') wrong = ev; }); }
  ok(!!wrong, '接错触发 wrong 事件');
  ok(wrong && wrong.answer === q3.answer, 'wrong 事件带正解');
  ok(wrong && wrong.picked && wrong.picked !== wrong.answer, 'wrong 事件带误接的字');
  ok(g3.S.lives === lives0 - 1, '接错扣一条命', lives0 + '->' + g3.S.lives);
  ok(g3.S.combo === 0, '接错清空连击');

  // 放跑扣命：车停在空车道，正解直接开过去
  const g4 = createGame({ seed: 7 }); g4.startMatch({});
  const q4 = firstQuestion(g4);
  g4.setLane(q4.emptyLane);
  let miss = null; const lives1 = g4.S.lives;
  for (let i = 0; i < 1800 && !miss; i++){ g4.step(1 / 60); drain(g4, ev => { if (ev.t === 'miss') miss = ev; }); }
  ok(!!miss, '放跑触发 miss 事件');
  ok(miss && miss.answer === q4.answer, 'miss 事件带正解');
  ok(g4.S.lives === lives1 - 1, '放跑扣一条命', lives1 + '->' + g4.S.lives);
}

/* ---------- 5. 一局结束 ---------- */
{
  const g = createGame({ seed: 7 }); g.startMatch({});
  let over = false, guard = 0;
  while (g.S.phase === 'play' && guard++ < 60 * 600){ g.step(1 / 60); drain(g, ev => { if (ev.t === 'over') over = true; }); }
  ok(g.S.phase === 'over', '三条命用完一局结束', 'phase=' + g.S.phase);
  ok(g.S.lives === 0, '生命归零');
  ok(over, '发出 over 事件');
  ok(g.S.stats.questions >= 1, '统计了出题数', String(g.S.stats.questions));
  ok(g.S.stats.wrong + g.S.stats.miss + g.S.stats.correct === g.S.stats.questions, '三种结果之和等于出题数',
    g.S.stats.correct + '+' + g.S.stats.wrong + '+' + g.S.stats.miss + ' vs ' + g.S.stats.questions);
  // 结束后不再推进
  const e = g.S.elapsed;
  for (let i = 0; i < 60; i++) g.step(1 / 60);
  ok(g.S.elapsed === e, '结束后时间不再推进');
}

/* ---------- 6. 暂停 / 速度 / AI ---------- */
{
  const g = createGame({ seed: 7 }); g.startMatch({});
  g.pause(true);
  const e = g.S.elapsed, q0 = g.S.question;
  for (let i = 0; i < 120; i++) g.step(1 / 60);
  ok(g.S.elapsed === e, '暂停冻结时间');
  ok(g.S.question === q0, '暂停不改变题目');
  g.pause(false);
  for (let i = 0; i < 120; i++) g.step(1 / 60);
  ok(g.S.elapsed > e, '恢复后时间继续推进');
  ok(g.S.paused === false, '暂停标记已清除');

  // 速度随得分上升
  const g2 = createGame({ seed: 7 }); g2.startMatch({});
  const v0 = g2.S.speed;
  g2.S.score = 1200;
  g2.step(1 / 60);
  ok(g2.S.speed > v0, '得分越高来牌越快', v0.toFixed(1) + '->' + g2.S.speed.toFixed(1));
  ok(g2.S.speed <= 13 + 1e-9, '速度有上限', g2.S.speed.toFixed(1));

  // AI 演示：自动变道到答案车道，能持续答对，也会有失误
  const g3 = createGame({ seed: 7, mode: 'demo' }); g3.startMatch({ mode: 'demo' });
  for (let i = 0; i < 60 * 120; i++){ g3.step(1 / 60); drain(g3); }
  ok(g3.S.stats.correct >= 5, 'AI 演示持续答对', 'correct=' + g3.S.stats.correct);
  ok(g3.S.score > 0, 'AI 演示有得分', String(g3.S.score));
  ok(g3.S.stats.wrong + g3.S.stats.miss > 0, 'AI 演示偶有失误', 'wrong=' + g3.S.stats.wrong + ' miss=' + g3.S.stats.miss);
  // 非犹豫期时车应在答案车道（犹豫期会故意偏出去）
  const g3b = createGame({ seed: 7, mode: 'demo' }); g3b.startMatch({ mode: 'demo' });
  let inLane = true, seenQ = false;
  for (let i = 0; i < 60 * 60; i++){
    g3b.step(1 / 60); drain(g3b);
    if (g3b.S.question && !g3b.S.question.resolved){
      seenQ = true;
      if (g3b.S.demoMistake <= 0 && g3b.S.carLane !== g3b.S.question.answerLane) inLane = false;
    }
  }
  ok(seenQ && inLane, 'AI 非犹豫期开在答案车道');
}

/* ---------- 7. 多种子稳健性 ---------- */
{
  let nan = 0, err = 0, ended = 0, questions = 0;
  for (let seed = 1; seed <= 16; seed++){
    const g = createGame({ seed, mode: 'demo' });
    g.startMatch({ mode: 'demo' });
    try{
      for (let i = 0; i < 60 * 90; i++){ g.step(1 / 60); drain(g); }
      if (!Number.isFinite(g.S.score + g.S.elapsed + g.S.speed)) nan++;
      if (g.S.phase === 'over') ended++;
      questions += g.S.stats.questions;
    }catch(e){ err++; console.log('   seed ' + seed + ' 抛错: ' + e.message); }
  }
  ok(err === 0, '16 组种子均不抛异常', 'errors=' + err);
  ok(nan === 0, '16 组种子状态无 NaN');
  ok(questions >= 16, '多种子都能出题', 'questions=' + questions);
  ok(ended >= 8, 'AI 演示多数种子能打到命用完', ended + '/16');
}

/* ---------- 8. reset / startMatch ---------- */
{
  const g = createGame({ seed: 7 }); g.startMatch({});
  for (let i = 0; i < 600; i++){ g.step(1 / 60); drain(g); }
  g.reset();
  ok(g.S.phase === 'menu', 'reset 回到菜单');
  ok(g.S.score === 0 && g.S.lives === 3 && g.S.question === null, 'reset 清空状态');
  ok(g.S.stats.questions === 0, 'reset 清空统计');
  g.startMatch({ mode: 'demo' });
  ok(g.S.phase === 'play' && g.S.demo === true, 'startMatch 可切到演示模式');
  ok(g.S.score === 0 && g.S.lives === 3, 'startMatch 重置分数与生命');
}

console.log(`\n${checks - fails}/${checks} core checks passed`);
process.exit(fails ? 1 : 0);
