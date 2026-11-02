'use strict';
/* 从 index.html 中抽出「规则内核」与「整段脚本」，供语法检查与无头测试使用。 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const lines = html.split('\n');

function between(startMark, endMark, name){
  const a = lines.findIndex(l => l.includes(startMark));
  const b = lines.findIndex(l => l.includes(endMark));
  if (a < 0 || b < 0 || b <= a) throw new Error(`找不到标记 ${startMark} / ${endMark}`);
  const out = path.join(root, 'tools', 'out', name);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, lines.slice(a + 1, b).join('\n'), 'utf8');
  return { out, count: b - a - 1 };
}

const s = lines.indexOf('<script>'), e = lines.indexOf('</script>');
if (s < 0 || e < 0) throw new Error('找不到 <script> 块');

const core = between('__CORE_START__', '__CORE_END__', 'core.cjs');
const full = { out: path.join(root, 'tools', 'out', 'full.js'), count: e - s - 1 };
fs.mkdirSync(path.dirname(full.out), { recursive: true });
fs.writeFileSync(full.out, lines.slice(s + 1, e).join('\n'), 'utf8');

console.log(`core  -> ${path.relative(root, core.out)} (${core.count} 行)`);
console.log(`full  -> ${path.relative(root, full.out)} (${full.count} 行)`);
