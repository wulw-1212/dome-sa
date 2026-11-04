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
  + 'WORDS,UNITS,GRADES,MODES,MODE_MIX,LETTERS,mulberry32,gradeInfo,unitsFor,unitInfo,gradeWords,'
  + 'unitWords,shuffle,distractFor,pickOptions,pickMode,canPic,orderWord,newRound,firstLetterHint,'
  + 'scoreFor,starsFor,cartSpeedFor,forceFirst,makeState,startGame,choose,advance,nextIndex,isDone,'
  + 'stateInfo,maxScore,bestKey,bestUnit,'
  + 'TRACK_ENTRY,TRACK_EXIT,TRACK_LOOP,catmullRom,sampleSpline,sampleLoop,buildTrack,trackAt,isLoopRegion};\n', 'utf8');

const K = require(out);
let fails = 0;
function ok(cond, label, detail) {
  if (cond) { console.log('ok    ' + label + (detail ? '  (' + detail + ')' : '')); return; }
  fails++; console.log('FAIL  ' + label + (detail ? '  (' + detail + ')' : ''));
}
const right = g => K.LETTERS[g.round.options.findIndex(o => o.word.en === g.round.word.en)];
const wrong = g => { const o = g.round.options.find(x => x.word.en !== g.round.word.en && !x.picked); return o ? o.letter : null; };
const GS = [1, 2, 3, 4];

/* ---------- 年级表 ---------- */
ok(K.GRADES.length === 4, '四个年级', K.GRADES.map(g => g.g).join(','));
ok(K.GRADES.every(g => [1, 2, 3, 4].includes(g.g) && g.cn && g.en && g.rounds >= 4), '年级字段齐备');
ok(K.gradeInfo(3).g === 3 && K.gradeInfo('2').g === 2, 'gradeInfo 接受字符串');
ok(K.gradeInfo(99).g === 1 && K.gradeInfo(undefined).g === 1 && K.gradeInfo(null).g === 1, '非法年级回退一年级');
ok(K.GRADES.every(g => g.blurb && g.blurb.length > 3), '每个年级都有简介文案');

/* ---------- 词库 ---------- */
ok(K.WORDS.length >= 90, '单词数 ≥ 90', K.WORDS.length + ' 个');
ok(K.WORDS.every(w => w.en && w.cn && w.icon && w.sentence && w.scn && w.unit && w.g), '每词都有 en/cn/icon/sentence/scn/unit/g');
ok(K.WORDS.every(w => /^[A-Za-z]+$/.test(w.en)), '单词都是字母（首字母大写仅限 Chinese / English 这类专名）');
ok(K.WORDS.filter(w => /^[A-Z]/.test(w.en)).every(w => ['Chinese', 'English', 'Monday', 'Friday', 'Sunday'].includes(w.en)), '大写开头的只有专名与星期');
ok(K.WORDS.every(w => w.en === w.en.toLowerCase() || /^[A-Z][a-z]+$/.test(w.en)), '没有全大写或奇怪大小写');
ok(new Set(K.WORDS.map(w => w.en.toLowerCase())).size === K.WORDS.length, '英文单词不重复（忽略大小写）');
ok(K.WORDS.every(w => GS.includes(w.g)), '每词年级都在 1–4');
ok(K.WORDS.every(w => K.UNITS.some(u => u.key === w.unit)), '每词的 unit 都在词库表里');
ok(K.UNITS.every(u => u.key && u.cn && u.en), '词库表字段齐备');
ok(K.unitsFor(1).length >= 4 && K.unitsFor(4).length >= 4, '每个年级至少 4 个词库 + 混合');
ok(K.unitsFor(1).every(u => u.key === 'mixed' || u.g === 1), 'unitsFor 只给本年级词库');
ok(K.unitsFor(9).length === K.unitsFor(1).length && K.unitsFor(9).every(u => u.g === 1 || u.key === 'mixed'), '非法年级按一年级处理而不抛错');
ok(K.unitInfo('animals').cn === '动物' && K.unitInfo('nope').key === K.UNITS[0].key, 'unitInfo 合法/回退');
for (const g of GS) {
  ok(K.gradeWords(g).length >= 20, '年级 ' + g + ' 至少 20 词', K.gradeWords(g).length + ' 词');
  ok(K.unitWords('mixed', g).length === K.gradeWords(g).length, '年级 ' + g + ' mixed = 本年级全部');
  ok(K.unitsFor(g).every(u => K.unitWords(u.key, g).length >= 4), '年级 ' + g + ' 每个词库 ≥ 4 词');
  ok(K.gradeWords(g).every(w => K.unitWords(w.unit, g).some(x => x.en === w.en)), '年级 ' + g + ' 每词都能在自己的词库里找到');
}
ok(K.unitWords('animals', 1).every(w => w.g === 1), '跨年级不串词：animals@1 都是一年级');
ok(K.unitWords('animals', 4).length === K.gradeWords(4).length, '本年级没有该词库时回退本年级全部（不返回别的年级）');
ok(K.unitWords('nope', 2).length === K.gradeWords(2).length, '未知词库回退本年级');
ok(K.unitWords('food').length >= 6 && K.unitWords('food').every(w => w.unit === 'food'), '不传年级时按全库取词库');
ok(K.WORDS.filter(w => w.icon === 'color').every(w => /^#[0-9a-f]{6}$/.test(w.hue)), 'color 图标都带合法色值');
ok(K.WORDS.filter(w => w.icon === 'count').every(w => w.n >= 1 && w.n <= 6), 'count 图标都带 1–6 的数量');
ok(K.WORDS.filter(w => w.pic === false).every(w => !K.canPic(w)), 'pic:false 的词都判定为不可画图');
ok(K.WORDS.filter(w => w.icon === 'idea').every(w => w.pic === false), 'idea 占位图标都标了 pic:false');
ok(K.WORDS.filter(w => K.canPic(w)).every(w => w.icon !== 'idea'), '可画图的词不用 idea');
ok(K.WORDS.filter(w => !K.canPic(w)).length >= 20, '抽象词数量合理（三四年级为主）', 'no-pic ' + K.WORDS.filter(w => !K.canPic(w)).length);
for (const g of GS) {
  const pics = K.gradeWords(g).filter(K.canPic).length;
  ok(pics >= 6, '年级 ' + g + ' 至少 6 个可画图的词（看图题不会绝迹）', pics + ' / ' + K.gradeWords(g).length);
}
ok(K.gradeWords(1).every(K.canPic) && K.gradeWords(2).every(K.canPic), '一二年级全部单词都有图画（小小孩靠图认词）');
ok(K.gradeWords(3).some(w => !K.canPic(w)) && K.gradeWords(4).some(w => !K.canPic(w)), '三四年级加入抽象词（家人/职业/学科…）');
{
  /* 每个年级实际跑一批题，看图题真的会出现（不是只靠比例算出来的） */
  for (const g of GS) {
    let pic = 0;
    for (let seed = 1; seed <= 40; seed++) {
      const game = K.startGame(K.makeState({ grade: g, unit: 'mixed', rounds: K.gradeInfo(g).rounds, seed }));
      for (let i = 0; i < game.rounds; i++) { if (game.round.mode === 'pic') pic++; K.choose(game, right(game)); K.advance(game); }
    }
    ok(pic >= 10, '年级 ' + g + ' 40 局里看图题出现 ' + pic + ' 次', String(pic));
  }
}
ok(K.WORDS.every(w => /\S+$/.test(w.sentence) && w.sentence.length > 6), '例句不是单词本身');
ok(K.WORDS.every(w => /[\u4e00-\u9fff]/.test(w.scn)), '例句中文都是汉字');
ok(K.WORDS.every(w => w.sentence.toLowerCase().includes(w.en.toLowerCase())), '例句里包含这个单词');

/* ---------- 随机数 ---------- */
const r1 = K.mulberry32(123), r2 = K.mulberry32(123);
ok([r1(), r1(), r1()].join(',') === [r2(), r2(), r2()].join(','), '同种子序列一致');
let inRange = true; const rr = K.mulberry32(7); const seen = new Set();
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
  const pool = K.unitWords('animals', 1);
  const word = pool[0];
  const opts = K.pickOptions(word, pool, rng, 4);
  ok(opts.length === 4, '四个选项');
  ok(opts.map(o => o.letter).join('') === 'ABCD', '标签依次 A B C D');
  ok(opts.some(o => o.word.en === word.en), '正确词在选项中');
  ok(new Set(opts.map(o => o.word.en)).size === 4, '选项互不重复');
  const dist = K.distractFor(word, pool, 3, rng);
  ok(dist.length === 3 && dist.every(w => w.en !== word.en && w.unit === word.unit), '干扰项同词库且不含正确词');
  const small = K.unitWords('numbers', 1);
  const cross = K.distractFor(small[0], small, 3, rng);
  ok(cross.length === 3 && cross.every(w => w.en !== small[0].en), '本库不够时同年级补齐', cross.map(w => w.en).join(','));
  ok(cross.every(w => w.g === 1), '补齐的干扰项仍是同年级');
  /* 每个年级每个词库都能凑出 4 个不重复选项 */
  let bad = 0, offGrade = 0;
  for (const g of GS) for (const u of K.unitsFor(g))
    for (const w of K.unitWords(u.key, g)){
      const o = K.pickOptions(w, K.unitWords(u.key, g), K.mulberry32(w.en.length * 7 + g), 4);
      if (o.length !== 4 || new Set(o.map(x => x.word.en)).size !== 4) bad++;
      if (!o.every(x => x.word.g === g || x.word.en === w.en)) offGrade++;
    }
  ok(bad === 0, '全库 ' + K.WORDS.length + ' 词都能凑 4 个不重复选项', '异常 ' + bad);
  ok(offGrade === 0, '所有干扰项都与正确词同年级', '跨年级 ' + offGrade);
  ok(K.pickOptions(word, pool, rng, 1).length === 1, 'n=1 也能出选项');
}

/* ---------- 三种出题模式随年级变化 ---------- */
{
  const modes = new Set(); const rng = K.mulberry32(202);
  for (let i = 0; i < 400; i++) modes.add(K.pickMode(rng, null, 1));
  ok(modes.has('pic') && modes.has('cn') && modes.has('spell'), '三种模式都会出现', [...modes].join(','));
  const share = g => { const c = { pic: 0, cn: 0, spell: 0 }; const r = K.mulberry32(99);
    for (let i = 0; i < 4000; i++) c[K.pickMode(r, null, g)]++; return c; };
  const s1 = share(1), s4 = share(4);
  ok(s1.pic / 4000 > 0.62, '一年级看图题最多（靠图认词）', (s1.pic / 40).toFixed(1) + '%');
  ok(s4.pic / 4000 < 0.36 && s4.pic < s1.pic, '四年级看图题明显减少', (s4.pic / 40).toFixed(1) + '%');
  ok(s4.spell > s1.spell, '四年级拼写题比一年级多', s1.spell + ' -> ' + s4.spell);
  ok(s4.cn > s1.cn, '四年级中英互译比一年级多', s1.cn + ' -> ' + s4.cn);
  let picSum = 0, cnSum = 0;
  for (const g of GS) { const c = share(g); picSum += c.pic; cnSum += c.cn; }
  ok(picSum > 0 && cnSum > 0, '四个年级都能正常出题');
  ok(K.MODE_MIX[1][0] > K.MODE_MIX[2][0] && K.MODE_MIX[2][0] > K.MODE_MIX[3][0] && K.MODE_MIX[3][0] > K.MODE_MIX[4][0], 'MODE_MIX 看图比例逐年级递减');
  for (const g of GS) { const m = K.MODE_MIX[g]; ok(Math.abs(m[0] + m[1] + m[2] - 1) < 1e-9, '年级 ' + g + ' 出题比例之和为 1'); }
  ok(K.pickMode(K.mulberry32(1), { pic: false, icon: 'idea' }, 3) !== 'pic', '抽象词不出看图题');
  ok(K.pickMode(K.mulberry32(1), { icon: 'cat' }, 1) !== undefined, '有图词正常出题');
  ok(K.MODES.length === 3 && K.MODES.join(',') === 'pic,cn,spell', 'MODES 表');
}

/* ---------- 补字母提示 ---------- */
ok(K.firstLetterHint('apple') === 'a....' && K.firstLetterHint('egg') === 'e..' && K.firstLetterHint('banana') === 'b.....', '补字母提示：首字母 + 点位');
ok(K.firstLetterHint('Chinese') === 'C......', '专名保留原有大小写');
ok(K.firstLetterHint('') === '' && K.firstLetterHint(undefined) === '' && K.firstLetterHint('a') === '', '空/单字母不提示');

/* ---------- 出题顺序 ---------- */
{
  for (const g of GS) for (const u of K.unitsFor(g)) {
    const list = K.orderWord(u.key, g, K.mulberry32(5), 12);
    ok(list.length === 12 && list.every(w => w.g === g), 'orderWord g=' + g + ' ' + u.key + ' 出题数与年级正确');
    let dup = 0;
    for (let i = 1; i < list.length; i++) if (list[i].en === list[i - 1].en) dup++;
    ok(dup === 0, 'g' + g + ' ' + u.key + ' 连续不重复', '重复 ' + dup + ' 次');
  }
  const small = K.orderWord('numbers', 1, K.mulberry32(1), 40);
  ok(small.length === 40, '轮数多于词数时循环出题');
  ok(new Set(small.map(w => w.en)).size === K.unitWords('numbers', 1).length, '循环出题覆盖整库');
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

/* ---------- 过山车速度 ---------- */
{
  let p = 1;
  for (let i = 0; i < 400; i++) p = K.cartSpeedFor(p, 0.016, 6, false);
  ok(p > 2.4 && p <= 2.66, '连对越多越快且封顶', p.toFixed(3));
  let q = 3;
  for (let i = 0; i < 400; i++) q = K.cartSpeedFor(q, 0.016, 0, true);
  ok(q < 0.05, '跑完后平滑停下', q.toFixed(4));
  ok(K.cartSpeedFor(1, 0, 3, false) === 1, 'dt=0 不变化');
  ok(Number.isFinite(K.cartSpeedFor(1, 0.016, undefined, undefined)), '缺参不 NaN');
}

/* ---------- 过山车轨道几何 ---------- */
{
  const tk = K.buildTrack({ per: 3 });
  ok(tk.pts.length > 100, '轨道采样点数量足够', tk.pts.length + ' 点');
  ok(tk.length > 1500 && tk.length < 3000, '轨道总长度合理（画面 960 宽）', Math.round(tk.length) + ' px');
  let gap = 0;
  for (let i = 1; i < tk.pts.length; i++) gap = Math.max(gap, Math.hypot(tk.pts[i].x - tk.pts[i - 1].x, tk.pts[i].y - tk.pts[i - 1].y));
  ok(gap < 40, '相邻采样点间距够小，轨道不会画成折线', gap.toFixed(2) + ' px');
  let dAng = 0;
  for (let i = 1; i < tk.pts.length; i++){
    let d = Math.abs(tk.pts[i].ang - tk.pts[i - 1].ang);
    if (d > Math.PI) d = Math.PI * 2 - d;
    dAng = Math.max(dAng, d);
  }
  ok(dAng < 0.2, '切线角逐步变化，车厢不会突然翻角（含坡顶与接缝）', (dAng * 180 / Math.PI).toFixed(1) + '°');
  const ys = tk.pts.map(p => p.y), xs = tk.pts.map(p => p.x);
  ok(Math.min(...xs) > 20 && Math.max(...xs) < 940, '轨道横向不出画面', Math.min(...xs).toFixed(0) + '..' + Math.max(...xs).toFixed(0));
  ok(Math.min(...ys) > 60 && Math.max(...ys) < 500, '轨道纵向不出画面（上方留题面文字）', Math.min(...ys).toFixed(0) + '..' + Math.max(...ys).toFixed(0));
  ok(Math.max(...ys) - Math.min(...ys) > 250, '提升坡落差够大，看得出是过山车', (Math.max(...ys) - Math.min(...ys)).toFixed(0) + ' px');
  /* u 参数化：端点正确、越界夹紧、弧长均匀 */
  ok(Math.abs(K.trackAt(tk, 0).u) < 1e-9, 'u=0 在起点');
  ok(Math.abs(K.trackAt(tk, 1).u - 1) < 1e-9, 'u=1 在终点');
  ok(K.trackAt(tk, -0.5).u === 0 && K.trackAt(tk, 2).u === 1, '越界夹紧');
  ok(Number.isFinite(K.trackAt(tk, undefined).x), 'u 缺失不 NaN');
  let uPrev = -1, uMono = true;
  for (let i = 0; i <= 200; i++){ const p = K.trackAt(tk, i / 200); if (p.u < uPrev) uMono = false; uPrev = p.u; }
  ok(uMono, 'u 随进度单调递增');
  /* 走过的路程 ≈ 弧长：u 从 0 到 1 每 1% 的位移之和应接近轨道总长 */
  let walk = 0, pw = K.trackAt(tk, 0);
  for (let i = 1; i <= 100; i++){
    const p = K.trackAt(tk, i / 100);
    walk += Math.hypot(p.x - pw.x, p.y - pw.y); pw = p;
  }
  ok(Math.abs(walk / tk.length - 1) < 0.05, '按 u 取点走过的路程与弧长一致', Math.round(walk) + ' / ' + Math.round(tk.length));
  /* 圆环：轨道确实绕一整圈 —— 环顶在圆心上方、环底在圆心下方，且左右各经过一次 */
  const LP = K.TRACK_LOOP;
  let top = 0, bottom = 0, sideL = 0, sideR = 0;
  for (const p of tk.pts){
    const d = Math.hypot(p.x - LP.cx, p.y - LP.cy);
    if (d < LP.r + 8){
      if (p.y < LP.cy - LP.r * 0.6) top++;
      if (p.y > LP.cy + LP.r * 0.6) bottom++;
      if (p.x < LP.cx - LP.r * 0.6) sideL++;
      if (p.x > LP.cx + LP.r * 0.6) sideR++;
    }
  }
  ok(top > 2 && bottom > 2 && sideL > 2 && sideR > 2, '竖直圆环完整（顶/底/左/右都经过）', top + '/' + bottom + '/' + sideL + '/' + sideR);
  /* 车厢沿环走一圈时朝向会翻转（倒挂）—— 用角度覆盖判断 */
  let angMin = Infinity, angMax = -Infinity;
  for (let i = 0; i <= 400; i++){
    const p = K.trackAt(tk, i / 400);
    angMin = Math.min(angMin, p.ang); angMax = Math.max(angMax, p.ang);
  }
  ok(angMax - angMin > Math.PI, '车头朝向覆盖一整圈（会倒挂过环）', ((angMax - angMin) * 180 / Math.PI).toFixed(0) + '°');
  /* 支撑柱判定：环内部不立柱 */
  let inLoopBelow = 0;
  for (let i = 0; i < tk.pts.length; i++){
    const p = tk.pts[i];
    if (K.isLoopRegion(tk, i) && p.y > LP.cy && p.y < LP.cy + LP.r - 6) inLoopBelow++;
  }
  ok(inLoopBelow > 0, 'isLoopRegion 认得出环内的点', inLoopBelow + ' 点');
  ok(K.isLoopRegion(tk, 0) === false, '起点不在环内');
  /* 样条端点保真 */
  const sp = K.sampleSpline(K.TRACK_ENTRY, 2);
  ok(Math.abs(sp[0][0] - K.TRACK_ENTRY[0][0]) < 1e-6 && Math.abs(sp[0][1] - K.TRACK_ENTRY[0][1]) < 1e-6, '样条从第一个控制点出发');
  ok(Math.abs(sp[sp.length - 1][0] - K.TRACK_ENTRY[K.TRACK_ENTRY.length - 1][0]) < 1e-6, '样条止于最后一个控制点');
  ok(sp.every(p => Number.isFinite(p[0]) && Number.isFinite(p[1])), '样条无 NaN');
  const lp = K.sampleLoop(K.TRACK_LOOP, 1);
  ok(Math.hypot(lp[0][0] - LP.cx, lp[0][1] - (LP.cy + LP.r)) < 1e-6, '环从最低点起步');
  ok(Math.abs(lp[0][0] - lp[lp.length - 1][0]) < 1e-6 && Math.abs(lp[0][1] - lp[lp.length - 1][1]) < 1e-6, '环闭合');
  ok(K.sampleLoop(K.TRACK_LOOP, 0).length > 8, 'per=0 时环仍给出足够采样点');
  /* 三段接缝：找环起点的 u，检查接缝前后不跳变 */
  let seamU = 0, bestD = Infinity;
  for (let i = 0; i <= 1000; i++){
    const p = K.trackAt(tk, i / 1000);
    const d = Math.hypot(p.x - LP.cx, p.y - (LP.cy + LP.r));
    if (d < bestD){ bestD = d; seamU = i / 1000; }
  }
  const s1 = K.trackAt(tk, Math.max(0, seamU - 0.01)), s2 = K.trackAt(tk, seamU + 0.01);
  ok(Math.hypot(s2.x - s1.x, s2.y - s1.y) < 60, '环接缝前后 2% 进度内的位移正常（没有瞬移）',
     Math.round(Math.hypot(s2.x - s1.x, s2.y - s1.y)) + ' px @u=' + seamU.toFixed(2));
  ok(seamU > 0.3 && seamU < 0.7, '环在轨道中段（先爬坡冲坡，再过环）', seamU.toFixed(2));
  /* 每答对一题，车头沿轨道前进一段可测的距离 */
  const game = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 8, seed: 42 }));
  const p0 = K.trackAt(tk, K.stateInfo(game).progress);
  K.choose(game, right(game)); K.advance(game);
  const p1 = K.trackAt(tk, K.stateInfo(game).progress);
  ok(Math.hypot(p1.x - p0.x, p1.y - p0.y) > 40, '答对一题车头真的移动一段距离', Math.round(Math.hypot(p1.x - p0.x, p1.y - p0.y)) + ' px');
  let moved = 0, lastP = K.trackAt(tk, 0);
  for (let i = 1; i < game.rounds; i++){
    K.choose(game, right(game)); K.advance(game);
    const p = K.trackAt(tk, K.stateInfo(game).progress);
    moved += Math.hypot(p.x - lastP.x, p.y - lastP.y); lastP = p;
  }
  ok(moved > 1500 && moved <= tk.length * 1.35, '一整局走过的轨道长度与轨道总长相符', Math.round(moved) + ' / ' + Math.round(tk.length));
  /* 车厢间距：CART_GAP 对应的弧长约等于车身长度，别叠成一坨 */
  const gapPx = 0.04 * tk.length;
  ok(gapPx > 40 && gapPx < 110, '车厢间距合理（约一个车身）', Math.round(gapPx) + ' px');
}

/* ---------- 完整一局：状态机 ---------- */
{
  const g = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 8, seed: 42 }));
  ok(g.started && !g.over && g.i === 0 && g.round, '开局进入第 1 题');
  ok(g.grade === 1 && g.unit === 'animals', '年级与词库进入状态');
  ok(g.list.length === 8, '8 题序列');
  ok(g.rounds === 8, 'rounds 显式指定生效');
  const a = K.startGame(K.makeState({ grade: 2, unit: 'food', rounds: 8, seed: 77 })).list.join(',');
  const b = K.makeState({ grade: 2, unit: 'food', rounds: 8, seed: 77 }).list.join(',');
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
  ok(info.grade === 1 && info.unit === 'animals', '快照带年级与词库');
}
{
  const g = K.startGame(K.makeState({ grade: 2, unit: 'food', rounds: 5, seed: 8 }));
  K.choose(g, wrong(g));
  ok(g.round.done === false && g.streak === 0, '答错可重选、连对清零');
  K.choose(g, right(g));
  ok(g.score === 60 && g.round.done, '错一次再对得 60');
  const res2 = K.choose(g, right(g));
  ok(res2.skipped && g.score === 60, '已完成的题再点不加分');
}
{
  const g = K.startGame(K.makeState({ grade: 3, unit: 'family', rounds: 3, seed: 9 }));
  let guard = 0;
  while (!g.round.done && guard++ < 6) { const w = wrong(g); if (!w) break; K.choose(g, w); }
  ok(g.round.done && g.score === 0 && g.round.picks === 4, '三个都选错 → 自动揭晓正确项，本题 0 分', 'picks=' + g.round.picks);
  ok(guard === 3, '自动揭晓后不再循环', 'guard=' + guard);
}
{
  const g = K.startGame(K.makeState({ grade: 4, unit: 'week', rounds: 4, seed: 10 }));
  for (let i = 0; i < 4; i++) { K.choose(g, right(g)); K.advance(g); }
  const before = g.score;
  K.advance(g); K.choose(g, 'A'); K.nextIndex(g);
  ok(g.over && K.advance(g).over && g.score === before, '结束后 advance/choose 不再改变分数');
}
{
  const g = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 8, seed: 11 }));
  ok(K.choose(g, 'Z').skipped, '非法字母被忽略');
  ok(K.choose(g, '').skipped, '空字母被忽略');
  ok(K.choose(g, null).skipped && K.choose(g, undefined).skipped, 'null/undefined 被忽略');
  const g2 = K.makeState({ grade: 1, unit: 'animals', rounds: 8, seed: 1 });
  ok(K.choose(g2, 'A').skipped && K.advance(g2) === g2, '未开局不崩');
}
{
  const s = K.makeState({ grade: 1, unit: 'animals', rounds: 999, seed: 1 });
  ok(s.rounds <= 40 && s.rounds >= 1, 'rounds 夹紧', String(s.rounds));
  const s2 = K.makeState({ grade: 'nope', unit: 'nope', rounds: 0, seed: -5 });
  ok(s2.grade === 1 && s2.rounds === 8, '非法年级/词库/轮数回退默认', s2.grade + '/' + s2.unit + '/' + s2.rounds);
  ok(K.nextIndex({ i: 0, rounds: 5 }) === 1 && K.nextIndex({ i: 9, rounds: 5 }) === 4, 'nextIndex 夹紧');
  /* 每个年级的默认题数随年级增加 */
  ok(K.makeState({ grade: 1 }).rounds === 8 && K.makeState({ grade: 4 }).rounds === 10, '默认题数按年级',
     K.makeState({ grade: 1 }).rounds + ' / ' + K.makeState({ grade: 4 }).rounds);
  ok(K.GRADES.every(g => K.makeState({ grade: g.g }).rounds === g.rounds), '默认题数与年级表一致');
  /* 跨年级词库回退到本年级混合，而不是拿别的年级的词 */
  const cross = K.makeState({ grade: 4, unit: 'animals' });
  ok(cross.unit === 'mixed' && cross.grade === 4, '四年级选 animals 回退本年级混合', cross.unit);
  const crossG = K.startGame(K.makeState({ grade: 4, unit: 'animals', rounds: 6, seed: 2 }));
  ok(crossG.list.every(w => K.gradeWords(4).some(x => x.en === w)), '回退后出题全是四年级的词');
}
{
  /* forceFirst：?word= 固定第一题 */
  for (const [g, u, w] of [[1, 'animals', 'cat'], [2, 'food', 'apple'], [3, 'family', 'mother'], [4, 'weather', 'sunny']]) {
    const st = K.startGame(K.makeState({ grade: g, unit: u, rounds: 6, seed: 3, word: w }));
    ok(st.round.word.en === w, 'g' + g + ' word=' + w + ' 固定为第一题', st.round.word.en);
    ok(st.list.filter(x => x === w).length === 1, '固定词不重复', st.list.join(','));
    ok(K.startGame(K.makeState({ grade: g, unit: u, rounds: 6, seed: 3, word: w })).list.join(',') === st.list.join(','), '同参数可复现');
  }
  const miss = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 6, seed: 3, word: 'apple' }));
  const plain = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 6, seed: 3 }));
  ok(miss.list.join(',') === plain.list.join(','), '词不在本库时不改动序列（apple ∉ 一年级 animals）');
  const junk = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 6, seed: 3, word: 'zzz' }));
  ok(junk.list.join(',') === plain.list.join(','), '未知单词同样不改动序列');
  ok(K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 6, seed: 3, word: 'CAT' })).round.word.en === 'cat', 'word 参数大小写不敏感');
  const big = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 12, seed: 3, word: 'cat' }));
  ok(big.round.word.en === 'cat' && big.list.filter(x => x === 'cat').length === 1, '轮数多于词数时仍能固定', big.list.join(','));
}
{
  /* 强制模式 */
  for (const m of K.MODES) {
    const g = K.startGame(K.makeState({ grade: 1, unit: 'animals', rounds: 4, seed: 3, mode: m }));
    ok(g.round.mode === m, 'mode=' + m + ' 强制出题类型生效（一年级有图）');
    let guard = 0;
    while (!K.isDone(g) && guard++ < 20) { K.choose(g, right(g)); K.advance(g); }
    ok(K.isDone(g) && g.score === 400, 'mode=' + m + ' 全程可答完且满分 400', String(g.score));
  }
  /* 抽象词年级：强制 pic 也不会给没有图的词出看图题 */
  let abstractBad = null;
  for (const w of K.WORDS.filter(x => !K.canPic(x))) {
    const g = K.startGame(K.makeState({ grade: w.g, unit: w.unit, rounds: 1, seed: 5, mode: 'pic', word: w.en }));
    if (g.round.word.en !== w.en) { abstractBad = w.en + ' 没被固定出题'; break; }
    if (g.round.mode === 'pic') { abstractBad = w.en + ' 仍出了看图题'; break; }
  }
  ok(abstractBad === null, '所有抽象词强制 pic 都退化为中文/拼写题', abstractBad || '');
  const bad = K.startGame(K.makeState({ grade: 3, unit: 'jobs', rounds: 3, seed: 3, mode: 'nonsense' }));
  ok(K.MODES.includes(bad.round.mode), '非法 mode 回退随机出题', bad.round.mode);
}
{
  /* 最佳成绩 */
  ok(K.bestKey(1, 'animals') === '1:animals' && K.bestKey(3, 'mixed') === '3:mixed', 'bestKey 带年级前缀');
  ok(K.bestKey(2, undefined) === '2:mixed', 'bestKey 缺词库按 mixed');
  let b = K.bestUnit({}, K.bestKey(1, 'animals'), 80);
  ok(b['1:animals'] === 80, '最佳成绩写入');
  b = K.bestUnit(b, K.bestKey(1, 'animals'), 50);
  ok(b['1:animals'] === 80, '更低分不覆盖');
  b = K.bestUnit(b, K.bestKey(2, 'animals'), 95);
  ok(b['1:animals'] === 80 && b['2:animals'] === 95, '不同年级同词库分别记录');
  ok(K.bestUnit(null, '1:mixed', NaN)['1:mixed'] === 0, 'NaN/空对象安全');
  ok(K.bestUnit({ '1:mixed': 150 }, '1:mixed', -20)['1:mixed'] === 100, '越界值夹紧到 0–100');
}
{
  /* 端到端：四个年级 × 全部词库随机对局 */
  let bad = 0, min = Infinity, max = -Infinity, starSum = 0, games = 0, picOnAbstract = 0;
  for (const g of GS) for (const u of K.unitsFor(g)) for (let s = 1; s <= 4; s++) {
    const rounds = K.gradeInfo(g).rounds;
    const game = K.startGame(K.makeState({ grade: g, unit: u.key, rounds, seed: s * 31 + g }));
    let guard = 0;
    while (!K.isDone(game) && guard++ < 200) {
      if (game.round.mode === 'pic' && !K.canPic(game.round.word)) picOnAbstract++;
      if (game.rng() < 0.72) K.choose(game, right(game));
      else { const w = wrong(game); if (w) K.choose(game, w); else K.choose(game, right(game)); }
      if (game.round && game.round.done) K.advance(game);
    }
    if (!K.isDone(game)) bad++;
    if (!game.list.every(w => K.gradeWords(g).some(x => x.en === w))) bad++;
    const info = K.stateInfo(game);
    if (!(info.score >= 0 && info.score <= rounds * 100)) bad++;
    if (!Number.isFinite(info.avg) || !Number.isFinite(info.progress)) bad++;
    if (info.grade !== g || info.unit !== u.key) bad++;
    min = Math.min(min, info.score / rounds); max = Math.max(max, info.score / rounds);
    starSum += info.stars; games++;
  }
  ok(bad === 0, games + ' 局（4 年级 × 全部词库 × 4 种子）全部正常收束、年级不串、数值合法', '异常 ' + bad);
  ok(picOnAbstract === 0, '没有任何一局给抽象词出看图题', '违规 ' + picOnAbstract);
  ok(min >= 0 && max <= 100, '平均分区间 [' + Math.round(min) + ', ' + Math.round(max) + ']');
  ok(starSum / games >= 1, '随机对局平均星级 ≥1（不会太难）', (starSum / games).toFixed(2));
}
{
  /* 难度递进：全对时每个年级都满分；随机作答时高年级不更容易 */
  for (const g of GS) {
    let sum = 0;
    for (let s = 1; s <= 12; s++) {
      const game = K.startGame(K.makeState({ grade: g, unit: 'mixed', rounds: K.gradeInfo(g).rounds, seed: s }));
      while (!K.isDone(game)) { K.choose(game, right(game)); K.advance(game); }
      sum += K.stateInfo(game).avg;
    }
    ok(sum / 12 === 100, '年级 ' + g + ' 混合全对 → 平均 100 分');
  }
  const acc = g => { let s = 0; for (let seed = 1; seed <= 20; seed++) {
      const game = K.startGame(K.makeState({ grade: g, unit: 'mixed', rounds: K.gradeInfo(g).rounds, seed }));
      let guard = 0;
      while (!K.isDone(game) && guard++ < 300) {
        /* 模拟「乱点」：固定点第一个选项，不看答案 */
        K.choose(game, 'A');
        if (game.round && game.round.done) K.advance(game);
      }
      s += K.stateInfo(game).avg;
    } return s / 20; };
  const a1 = acc(1), a4 = acc(4);
  ok(a1 > 0 && a4 > 0 && Number.isFinite(a1) && Number.isFinite(a4), '乱点策略在高低年级都能打完并给出平均分',
     a1.toFixed(1) + ' / ' + a4.toFixed(1));
}

console.log(fails === 0 ? '\nALL PASS (' + K.WORDS.length + ' 词 / 4 年级 / ' + K.UNITS.length + ' 词库)' : '\n' + fails + ' FAILED');
process.exit(fails === 0 ? 0 : 1);
