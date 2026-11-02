'use strict';
/* 语法检查：整段页面脚本与抽出的内核都必须能被 Node 解析。 */
const { execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const root = path.join(__dirname, '..');
const targets = ['tools/out/full.js', 'tools/out/core.cjs'];
let bad = 0;

if (!fs.existsSync(path.join(root, 'tools/out/full.js'))){
  execFileSync(process.execPath, [path.join(root, 'tools/extract.cjs')], { stdio: 'inherit' });
}

for (const t of targets){
  const file = path.join(root, t);
  try{
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
    console.log('ok    ' + t);
  }catch(err){
    bad++;
    console.log('FAIL  ' + t);
    console.log(String(err.stderr || err.stdout || err.message).trim());
  }
}
console.log(bad ? `\n${bad} 个文件语法错误` : '\n语法检查通过');
process.exit(bad ? 1 : 0);
