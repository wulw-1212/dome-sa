'use strict';
/* 抽出 english-game.html 的规则内核（__CORE_START__ … __CORE_END__），
 * 在 Node 里直接跑断言，不需要浏览器。
 * 运行： node tools/english-game-core.cjs                                            */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'english-game.html'), 'utf8');
const lines = html.split('\n');
const a = lines.indexOf('// __CORE_START__');
const b = lines.indexOf('// __CORE_END__');
if (a < 0 || b < 0 || b <= a) { console.error('FAIL  找不到内核标记'); process.exit(1); }

const out = path.join(root, 'tools', 'out', 'english-game-core.cjs');
fs.mkdirSync(path.dirname(out), { recursive: true });
const body = lines.slice(a + 1, b).join('\n');
fs.writeFileSync(out, body + '\nmodule.exports = {'
  + 'WORDS,UNITS,LETTERS,MODES,mulberry32,unitWords,shuffle,distractFor,pickOptions,pickMode,'
  + 'orderWord,newRound,firstLetterHint,scoreFor,starsFor,trainSpeedFor,wordFromIndex,'
  + 'makeState,startGame,choose,advance,nextIndex,isDone,stateInfo,maxScore,bestUnit};\n', 'utf8');

const K = require(out);
let fails = 0;
function ok(cond, label, detail) {
  if (cond) { console.log('ok    ' + label + (detail ? '  (' + detail + ')' : '')); return; }
  fails++; console.log('FAIL  ' + label + (detail ? '  (' + detail + ')' : ''));
}
const right = g => K.LETTERS[g.round.options.findIndex(o => o.word.en === g.round.word.en)];
const wrong = g => { const o = g.round.options.find(x => x.word.en !== g.round.word.en && !x.picked); return o ? o.letter : null; };

/* ---------- 词库 ---------- */
ok(K.WORDS.length >= 28, '单词数 ≥ 28', K.WORDS.length + ' 个');
ok(K.WORDS.every(w => w.en && w.cn && w.icon && w.sentence && w.unit), '每词都有 en/cn/icon/sentence/unit');
ok(K.WORDS.every(w => /^[a-z]+$/.test(w.en)), '单词都是纯小写字母（一二年级不需要认大写以外形式）', '');
ok(new Set(K.WORDS.map(w => w.en)).size === K.WORDS.length, '英文单词不重复');
ok(K.UNITS.length === 5 && K.UNITS.every(u => u.key && u.cn && u.en), '五个关卡齐备', K.UNITS.map(u => u.key).join(','));
for (const u of K.UNITS) ok(K.unitWords(u.key).length >= 4, '关卡 ' + u.key + ' 至少 4 词', K.unitWords(u.key).length + ' 词');
ok(K.unitWords('mixed').length === K.WORDS.length, 'mixed = 全库');
ok(K.unitWords('nonexistent').length === K.WORDS.length, '未知关卡回退全库');
ok(K.WORDS.every(w => w.unit === 'mixed' || K.UNITS.some(u => u.key === w.unit)), '每词的 unit 都在关卡表里');
ok(K.WORDS.filter(w => w.icon === 'color').every(w => /^#[0-9a-f]{6}$/.test(w.hue)), 'color 图标都带合法色值');
ok(K.WORDS.filter(w => w.icon === 'count').every(w => w.n >= 1 && w.n <= 4), 'count 图标都带 1–4 的数量');

/* ---------- 随机数：可复现、范围合法 ---------- */
const r1 = K.mulberry32(123), r2 = K.mulberry32(123);
ok([r1(), r1(), r1()].join(',') === [r2(), r2(), r2()].join(','), '同种子序列一致');
let inRange = true, distinct = 0;
const rr = K.mulberry32(7); const seen = new Set();
for (let i = 0; i < 2000; i++) { const v = rr(); if (!(v >= 0 && v < 1)) inRange = false; seen.add(Math.floor(v * 1000)); }
ok(inRange, 'rng() 落在 [0,1)');
ok(seen.size > 780, '分布覆盖广（千分位命中 ' + seen.size + '/1000）');
ok(K.mulberry32(0)() !== undefined, 'seed=0 不崩');
const sh = K.shuffle(K.mulberry32(3), [1, 2, 3, 4, 5]);
ok(sh.length === 5 && sh.sort((x, y) => x - y).join(',') === '1,2,3,4,5', 'shuffle 保元素不变');
ok(K.shuffle(K.mulberry32(4), []).length === 0, 'shuffle 空数组安全');

/* ---------- 选项构造 ---------- */
{
  const rng = K.mulberry32(11);
  const pool = K.unitWords('animals');
  const word = pool[0];
  const opts = K.pickOptions(word, pool, rng, 4);
  ok(opts.length === 4, '四个选项');
  ok(opts.map(o => o.letter).join('') === 'ABCD', '标签依次 A B C D');
  ok(opts.some(o => o.word.en === word.en), '正确词在选项中');
  ok(new Set(opts.map(o => o.word.en)).size === 4, '选项互不重复');
  const dist = K.distractFor(word, pool, 3, rng);
  ok(dist.length === 3 && dist.every(w => w.en !== word.en && w.unit === word.unit), '干扰项同关卡且不含正确词');
  const few = K.distractFor(K.WORDS[0], K.WORDS.filter(w => w.unit === 'colors'), 3, rng);
  ok(few.length === 3 && few.every(w => w.en !== K.WORDS[0].en), '本库不够时跨库补齐', few.map(w => w.en).join(','));
  ok(K.pickOptions(word, pool, rng, 1).length === 1, 'n=1 也能出选项');
}

/* ---------- 三种出题模式 ---------- */
{
  const modes = new Set(); const rng = K.mulberry32(202);
  for (let i = 0; i < 400; i++) modes.add(K.pickMode(rng));
  ok(modes.has('pic') && modes.has('cn') && modes.has('spell'), '三种模式都会出现', [...modes].join(','));
  const c = { pic: 0, cn: 0, spell: 0 };
  const r2 = K.mulberry32(99);
  for (let i = 0; i < 3000; i++) c[K.pickMode(r2)]++;
  ok(c.pic / 3000 > 0.52 && c.pic / 3000 < 0.68, '看图 ≈60%', (c.pic / 30).toFixed(1) + '%');
  ok(c.cn / 3000 > 0.19 && c.cn / 3000 < 0.31, '听中文 ≈25%', (c.cn / 30).toFixed(1) + '%');
  ok(c.spell / 3000 > 0.10 && c.spell / 3000 < 0.20, '补字母 ≈15%', (c.spell / 30).toFixed(1) + '%');
}
ok(K.firstLetterHint('apple') === 'a....' && K.firstLetterHint('egg') === 'e..' && K.firstLetterHint('banana') === 'b.....', '补字母提示：首字母 + 点位');
ok(K.firstLetterHint('') === '' && K.firstLetterHint(undefined) === '' && K.firstLetterHint('a') === '', '空/单字母不提示');
{
  for (const m of K.MODES) {
    const g = K.startGame(K.makeState({ unit: 'animals', rounds: 4, seed: 3, mode: m }));
    ok(g.round.mode === m, 'mode=' + m + ' 强制出题类型生效');
    ok(g.round.options.length === 4 && g.round.options[g.round.answer].word.en === g.round.word.en, '强制模式选项与答案仍正确');
    let guard = 0;
    while (!K.isDone(g) && guard++ < 20) { K.choose(g, K.LETTERS[g.round.options.findIndex(o => o.word.en === g.round.word.en)]); K.advance(g); }
    ok(K.isDone(g) && g.score === 400, 'mode=' + m + ' 全程可答完且满分 400', String(g.score));
  }
  const bad = K.startGame(K.makeState({ unit: 'animals', rounds: 3, seed: 3, mode: 'nonsense' }));
  ok(K.MODES.includes(bad.round.mode), '非法 mode 回退随机出题', bad.round.mode);
}

/* ---------- 出题顺序：不连续重复 ---------- */
{
  for (const u of ['animals', 'colors', 'food', 'school', 'mixed']) {
    const list = K.orderWord(u, K.mulberry32(5), 12);
    ok(list.length === 12 && list.every(w => u === 'mixed' || w.unit === u), 'orderWord ' + u + ' 出题数与关卡正确');
    let dup = 0;
    for (let i = 1; i < list.length; i++) if (list[i].en === list[i - 1].en) dup++;
    ok(dup === 0, u + ' 连续不重复', '重复 ' + dup + ' 次');
  }
  const small = K.orderWord('animals', K.mulberry32(1), 40);
  ok(small.length === 40, '轮数多于词数时循环出题');
}

/* ---------- 计分 ---------- */
ok(K.scoreFor(1) === 100, '一次答对 = 100 分');
ok(K.scoreFor(2) === 60 && K.scoreFor(3) === 30 && K.scoreFor(4) === 0, '二次 60 / 三次 30 / 四次 0');
ok(K.scoreFor(undefined) === 100 && K.scoreFor(0) === 100 && K.scoreFor(9) === 0, '缺参/越界夹紧不 NaN');
for (const p of [0, 1, 2, 3, 4, 5, 99, -3]) {
  const s = K.scoreFor(p);
  ok(s >= 0 && s <= 100 && Number.isFinite(s), 'scoreFor 合法 p=' + p, String(s));
}
ok(K.starsFor(100) === 3 && K.starsFor(90) === 3 && K.starsFor(89) === 2 && K.starsFor(72) === 2
   && K.starsFor(60) === 1 && K.starsFor(54) === 0 && K.starsFor(0) === 0, '星级阈值 90/72/55');

/* ---------- 火车速度 ---------- */
{
  let p = 1;
  for (let i = 0; i < 400; i++) p = K.trainSpeedFor(p, 0.016, 6, false);
  ok(p > 2.4 && p <= 2.66, '连对越多越快且封顶', p.toFixed(3));
  let q = 3;
  for (let i = 0; i < 400; i++) q = K.trainSpeedFor(q, 0.016, 0, true);
  ok(q < 0.05, '到站后平滑停下', q.toFixed(4));
  ok(K.trainSpeedFor(1, 0, 3, false) === 1, 'dt=0 不变化');
  ok(Number.isFinite(K.trainSpeedFor(1, 0.016, undefined, undefined)), '缺参不 NaN');
}

/* ---------- 完整一局：状态机 ---------- */
{
  const g = K.startGame(K.makeState({ unit: 'animals', rounds: 8, seed: 42 }));
  ok(g.started && !g.over && g.i === 0 && g.round, '开局进入第 1 题');
  ok(g.list.length === 8, '8 题序列');
  const a = K.startGame(K.makeState({ unit: 'animals', rounds: 8, seed: 77 })).list.join(',');
  const b = K.makeState({ unit: 'animals', rounds: 8, seed: 77 }).list.join(',');
  ok(a === b, '同种子开局序列一致');
  let total = 0;
  for (let i = 0; i < 8; i++) {
    ok(g.round.options.length === 4, '第 ' + (i + 1) + ' 题四个选项');
    const res = K.choose(g, right(g));
    ok(res.correct && !res.skipped, '第 ' + (i + 1) + ' 题答对');
    total += g.round.score;
    K.advance(g);
  }
  ok(g.over && K.isDone(g), '八题打完 → 结束');
  ok(g.score === total && total === 800, '全对总分 ' + g.score);
  ok(g.score <= K.maxScore(g), '总分不超过满分 ' + K.maxScore(g));
  ok(K.starsFor(g.score / 8) === 3, '全对三星');
  ok(g.streak === 8 && g.bestStreak === 8, '连对 8');
  const info = K.stateInfo(g);
  ok(info.over && info.total === 8 && info.options.length === 0, '结束后快照干净');
}
{
  const g = K.startGame(K.makeState({ unit: 'food', rounds: 5, seed: 8 }));
  K.choose(g, wrong(g));
  ok(g.round.done === false && g.streak === 0, '答错可重选、连对清零');
  K.choose(g, right(g));
  ok(g.score === 60 && g.round.done, '错一次再对得 60');
  const res2 = K.choose(g, right(g));
  ok(res2.skipped && g.score === 60, '已完成的题再点不加分');
}
{
  const g = K.startGame(K.makeState({ unit: 'school', rounds: 3, seed: 9 }));
  let guard = 0;
  while (!g.round.done && guard++ < 6) { const w = wrong(g); if (!w) break; K.choose(g, w); }
  ok(g.round.done && g.score === 0 && g.round.picks === 4, '三个都选错 → 自动揭晓正确项，本题 0 分', 'picks=' + g.round.picks);
  ok(guard === 3, '自动揭晓后不再循环', 'guard=' + guard);
}
{
  const g = K.startGame(K.makeState({ unit: 'colors', rounds: 4, seed: 10 }));
  for (let i = 0; i < 4; i++) { K.choose(g, right(g)); K.advance(g); }
  const before = g.score;
  K.advance(g); K.choose(g, 'A'); K.nextIndex(g);
  ok(g.over && K.advance(g).over && g.score === before, '结束后 advance/choose 不再改变分数');
}
{
  const g = K.startGame(K.makeState({ unit: 'animals', rounds: 8, seed: 11 }));
  ok(K.choose(g, 'Z').skipped, '非法字母被忽略');
  ok(K.choose(g, '').skipped, '空字母被忽略');
  const g2 = K.makeState({ unit: 'animals', rounds: 8, seed: 1 });
  ok(K.choose(g2, 'A').skipped && K.advance(g2) === g2, '未开局不崩');
}
{
  const s = K.makeState({ unit: 'animals', rounds: 999, seed: 1 });
  ok(s.rounds <= 40 && s.rounds >= 1, 'rounds 夹紧', String(s.rounds));
  const s2 = K.makeState({ unit: 'nope', rounds: 0, seed: -5 });
  ok(K.UNITS.some(u => u.key === s2.unit) && s2.rounds === 8, '非法关卡/轮数回退默认', s2.unit + '/' + s2.rounds);
  ok(K.nextIndex({ i: 0, rounds: 5 }) === 1 && K.nextIndex({ i: 9, rounds: 5 }) === 4, 'nextIndex 夹紧');
}
{
  const arr = K.unitWords('animals');
  ok(K.wordFromIndex(null, arr, 0).en === arr[0].en, 'wordFromIndex 按下标取词');
  ok(K.wordFromIndex(null, arr, arr.length + 2).en === arr[2].en, '下标取模循环');
  ok(K.wordFromIndex(null, arr, -1).en === arr[arr.length - 1].en, '负下标合法');
}
{
  let b = K.bestUnit({}, 'animals', 80);
  ok(b.animals === 80, '最佳成绩写入');
  b = K.bestUnit(b, 'animals', 50);
  ok(b.animals === 80, '更低分不覆盖');
  b = K.bestUnit(b, 'food', 95);
  ok(b.animals === 80 && b.food === 95, '不同关卡分别记录');
  ok(K.bestUnit(null, 'animals', NaN).animals === 0, 'NaN/空对象安全');
  ok(K.bestUnit({ animals: 150 }, 'animals', -20).animals === 100, '越界值夹紧到 0–100');
}
{
  /* 端到端模拟 200 局随机对局：不卡死、分数区间合理 */
  let bad = 0, min = Infinity, max = -Infinity, starSum = 0;
  for (let seed = 1; seed <= 200; seed++) {
    const unit = K.UNITS[seed % 5].key;
    const g = K.startGame(K.makeState({ unit, rounds: 8, seed }));
    let guard = 0;
    while (!K.isDone(g) && guard++ < 200) {
      if (g.rng() < 0.72) K.choose(g, right(g));
      else { const w = wrong(g); if (w) K.choose(g, w); else K.choose(g, right(g)); }
      if (g.round && g.round.done) K.advance(g);
    }
    if (!K.isDone(g)) bad++;
    const info = K.stateInfo(g);
    if (!(info.score >= 0 && info.score <= 800)) bad++;
    if (!Number.isFinite(info.avg) || !Number.isFinite(info.progress)) bad++;
    min = Math.min(min, info.score); max = Math.max(max, info.score); starSum += info.stars;
  }
  ok(bad === 0, '200 局随机对局全部正常收束、数值合法', '异常 ' + bad);
  ok(min >= 0 && max <= 800, '总分区间 [' + min + ', ' + max + ']');
  ok(starSum / 200 >= 1, '随机对局平均星级 ≥1（不会太难）', (starSum / 200).toFixed(2));
}
{
  /* 难度检查：孩子全选对时平均分高；随机乱选仍有正反馈 */
  const perfect = [];
  for (let seed = 1; seed <= 60; seed++) {
    const g = K.startGame(K.makeState({ unit: 'mixed', rounds: 8, seed }));
    while (!K.isDone(g)) { K.choose(g, right(g)); K.advance(g); }
    perfect.push(K.stateInfo(g).avg);
  }
  ok(perfect.every(v => v >= 100), '混合关卡全对 → 平均 ' + Math.min(...perfect) + ' 分');
}

console.log(fails === 0 ? '\nALL PASS (' + (K.WORDS.length) + ' 词 / 5 关)' : '\n' + fails + ' FAILED');
process.exit(fails === 0 ? 0 : 1);
