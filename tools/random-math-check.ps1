# tools/random-math-check.ps1
# random-math.html 的独立验证（不依赖页面自带 selftest 的结论）。
#
#   运行： powershell -NoProfile -File tools\random-math-check.ps1
#          （本机未安装 pwsh 7；脚本同时兼容 Windows PowerShell 5.1 与 PowerShell 7+）
#
#   本机没有 Node，所以全部用无头 Edge 执行：
#     C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
#     --headless --disable-gpu --hide-scrollbars --no-first-run
#     --window-size=W,H --virtual-time-budget=N --dump-dom "<file:///...>"
#   Edge 把日志写到 stderr、退出码不可靠（本机 --dump-dom 依赖 URL 被引号包住，
#   否则带空格的路径会被拆成多个 target 而直接失败），因此一律看输出内容判断。
#
#   验证内容（见 .verify/CONTRACT.md v1）：
#     A. 静态：文件/区块标记/无外部 URL/30 个 DOM id/window API 痕迹
#     B. 内核：自写断言页（自己抽取 __CORE_START__..__CORE_END__），同 seed 复现、
#        算式求值与 answer 一致、除法整除、计分/星级单调、输入归一化与判定、时钟、最佳成绩键
#     C. 全流程探针：把页面复制到 .verify/ 并在 </body> 前追加自写探针，驱动
#        window.randommath 走 menu→play→result，覆盖 DOM id、HUD/结算无 NaN、
#        答对加分/答错清连击、count/time 结束、星级与最佳成绩一致、键位、窄屏溢出、无外部请求
#     D. URL 自动化参数（auto/solve/miss/ff/theme/freeze）与页内 selftest 的独立复核
#     E. 基线：random-math.html 在 .verify/main-baseline/（origin/main）不存在；
#        index.html 的 PAGES 里有指向 random-math.html 的卡片
#
#   退出码：全部通过 0；任一失败非 0。结果写入 .verify/random-math-check-report.txt。
#   可重复运行：每次重建 .verify/rm-check/ 下的产物与一次性 Edge profile。

param(
  [string]$Page = '',                       # 默认 <仓库根>/random-math.html（-Page 便于用 fixture 自测本脚本）
  [string]$EdgeExe = '',
  [switch]$SkipIndexCard,                   # 跳过 index.html 导航卡片断言（rm-docs 还没改完时）
  [int]$Budget = 15000                      # --virtual-time-budget，毫秒
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Verify = Join-Path $script:Root '.verify'
$script:Work = Join-Path $script:Verify 'rm-check'
$script:ReportPath = Join-Path $script:Verify 'random-math-check-report.txt'
$script:Baseline = Join-Path $script:Verify 'main-baseline'

if (-not $Page) { $Page = Join-Path $script:Root 'random-math.html' }
$script:PagePath = $Page
$script:PageUrl = 'file:///' + ($Page -replace '\\', '/')

$script:Results = New-Object System.Collections.ArrayList
$script:Skips = New-Object System.Collections.ArrayList
$script:Runs = New-Object System.Collections.ArrayList
$script:EdgeFailures = 0
$script:SelftestInfo = ''
$script:EdgeErrors = New-Object System.Collections.ArrayList
$script:Infos = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- 小工具
function Read-TextFile([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $strict = New-Object Text.UTF8Encoding($false, $true)
  try { return $strict.GetString($bytes) } catch { return [Text.Encoding]::Default.GetString($bytes) }
}
function Write-TextFile([string]$path, [string]$text) {
  $enc = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($path, $text, $enc)
}
function Check {
  param([string]$Name, [bool]$Cond, [string]$Detail = '', [string]$Url = '', [string]$Source = 'static')
  [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Ok = [bool]$Cond; Detail = $Detail; Url = $Url; Source = $Source })
  if ($Cond) { Write-Host "ok    $Name" }
  else { Write-Host "FAIL  $Name" -ForegroundColor Red; if ($Detail) { Write-Host "      $Detail" -ForegroundColor DarkGray } }
}
function Skip {
  param([string]$Name, [string]$Why)
  [void]$script:Skips.Add([pscustomobject]@{ Name = $Name; Why = $Why })
  Write-Host "SKIP  $Name ($Why)" -ForegroundColor DarkYellow
}
function Sha256([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}

function Invoke-EdgeDom {
  # 返回 @{ text=DOM; url=...; dump=落盘路径; ok=是否拿到输出 }
  param([string]$Url, [int]$W, [int]$H, [int]$Budget, [string]$Tag)
  # URL / 带空格的路径必须带引号：否则会被拆成多个 target，Edge 直接报
  # "Multiple targets are not supported in headless mode"。
  $profile = Join-Path $script:Work ('edge-profile-' + $Tag)
  $eargs = @(
    '--user-data-dir="' + $profile + '"',
    '--headless', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
    '--disable-extensions', '--disable-background-networking', '--no-default-browser-check',
    '--window-size=' + $W + ',' + $H,
    '--virtual-time-budget=' + $Budget,
    '--dump-dom',
    '"' + $Url + '"'
  )
  $ok = $false
  $text = ''
  $errText = ''
  $code = ''
  $attempt = 0
  while ($attempt -lt 2 -and -not $ok) {
    $attempt++
    $outF = Join-Path $env:TEMP ('rm-edge-' + [guid]::NewGuid().ToString('N') + '.html')
    $errF = Join-Path $env:TEMP ('rm-edge-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
      # 既有范式（tools\word-copy-check.ps1）：走 cmd /c 重定向到文件。
      # Edge 的启动进程可能比真正写 stdout 的子进程先退出，所以还要轮询：
      # 独占打开拿到内容、内容以 </html> 收尾后长度稳定，才算抓全。
      $cmdLine = '"' + $script:Edge + '" ' + ($eargs -join ' ') + ' > "' + $outF + '" 2> "' + $errF + '"'
      $null = cmd /c $cmdLine
      $code = '' + $LASTEXITCODE
      $deadline = (Get-Date).AddMilliseconds(45000 + $Budget)
      $lastLen = -1
      $stable = 0
      while ((Get-Date) -lt $deadline) {
        $cand = $null
        try {
          if (Test-Path -LiteralPath $outF) {
            $fs = [IO.File]::Open($outF, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            $sr = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)))
            $cand = $sr.ReadToEnd()
            $sr.Close(); $fs.Close()
          }
        } catch { $cand = $null }
        if ($null -ne $cand) {
          if ($cand.Length -eq $lastLen -and $cand.Length -gt 0) { $stable++ } else { $stable = 0 }
          $lastLen = $cand.Length
          $text = $cand
          if ($stable -ge 1 -and $cand -match '(?i)</html>') { break }
        }
        Start-Sleep -Milliseconds 250
      }
      $errText = ''
      if (Test-Path -LiteralPath $errF) { try { $errText = Read-TextFile $errF } catch { } }
      $ok = ($text.Length -gt 0)
    } catch {
      $errText = 'Edge 启动/读取失败: ' + $_.Exception.Message
      $text = ''
    } finally {
      Remove-Item -LiteralPath $outF -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $errF -Force -ErrorAction SilentlyContinue
    }
  }
  if ($errText) { Write-TextFile (Join-Path $script:Work ($Tag + '.edge.log')) $errText }
  $dump = ''
  if ($text) {
    $dump = Join-Path $script:Work ($Tag + '.dom.html')
    Write-TextFile $dump $text
  } else {
    # Edge 的日志在 stderr，退出码不可靠：把最后一行日志塞进 detail 便于定位
    $lastErr = ($errText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    $errHint = if ($lastErr) { $lastErr.Trim() } else { '(stderr 为空)' }
    [void]$script:EdgeErrors.Add([pscustomobject]@{ Tag = $Tag; Exit = $code; Log = $errHint; Attempts = $attempt })
  }
  [void]$script:Runs.Add([pscustomobject]@{ Tag = $Tag; Url = $Url; W = $W; H = $H; Bytes = $text.Length; Dump = $dump; Exit = $code })
  return @{ ok = $ok; text = $text; url = $Url; dump = $dump }
}

function Get-EdgeHint([string]$tag) {
  $e = $script:EdgeErrors | Where-Object { $_.Tag -eq $tag } | Select-Object -First 1
  if ($e) { return ('无头 Edge 没有返回 DOM; exit=' + $e.Exit + '; ' + $e.Log) }
  return '无头 Edge 没有返回 DOM'
}

function Get-ProbeBlock([string]$dom) {
  $m = [regex]::Match($dom, '(?s)<pre id="rmcheck">(.*?)</pre>')
  if (-not $m.Success) { return $null }
  $raw = $m.Groups[1].Value
  $raw = $raw -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'" -replace '&amp;', '&'
  return ($raw -split "`r?`n")
}

function Import-ProbeResult([string]$tag, [string]$url, [string]$dump) {
  $dom = ''
  if ($dump -and (Test-Path -LiteralPath $dump)) { $dom = Read-TextFile $dump }
  $lines = Get-ProbeBlock $dom
  if ($null -eq $lines) {
    Check "$tag.probeBlockPresent" $false 'dump 里找不到 <pre id="rmcheck">（探针没跑到或页面结构异常）' $url 'probe'
    return
  }
  $n = 0
  foreach ($line in $lines) {
    if ($line -notmatch '^RM\|') { continue }
    $parts = $line -split '\|', 4
    if ($parts.Count -lt 4) { continue }
    if ($parts[1] -eq 'I') {
      [void]$script:Infos.Add([pscustomobject]@{ Name = $parts[2]; Value = $parts[3] })
      continue
    }
    Check $parts[2] ($parts[1] -eq '1') $parts[3] $url 'probe'
    $n++
  }
  Check "$tag.probeAssertions" ($n -ge 5) ("probe 只抛出 $n 条断言") $url 'probe'
  Check "$tag.probeComplete" ([bool]($lines -contains 'RMCHECK_END')) '探针没有跑到 RMCHECK_END（中途异常）' $url 'probe'
}

# ---------------------------------------------------------------- 自写断言页（内核）
$corePageTemplate = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>rm core check</title>
</head>
<body>
<pre id="rmcheck">RMCHECK_PENDING</pre>
<script>
/* ==== 自动抽取的 random-math.html 内核（__CORE_START__ .. __CORE_END__） ==== */
__RM_CORE_SOURCE__
/* ==== 抽取结束 ==== */
</script>
<script>
(function(){
  var L=['RMCHECK_BEGIN'];
  function san(s){ return String(s==null?'':s).replace(/[|\r\n\t]/g,' ').replace(/[^\x20-\x7E]/g,'.').slice(0,180); }
  function ok(n,c,d){ L.push('RM|'+(c?1:0)+'|'+n+'|'+san(d==null?'':d)); }
  var OPOK=['+','-','\u00d7','\u00f7'];
  var rm=null, loadErr='';
  try { rm = (typeof RM_CORE!=='undefined') ? RM_CORE : null; }
  catch(e){ loadErr=(e&&e.name)?e.name:'access-error'; }
  ok('core.loaded', !!rm, loadErr || ('type='+(typeof RM_CORE)));

  /* 迷你算式解析器：解析成语法树，用来独立核对 answer，并逐个除法节点检查整除性
     （四年级存在 a ÷ b + c 这类混合式，所以不能只看整式结果） */
  function parseExpr(src){
    var t=String(src).replace(/[=?\s,]/g,'').replace(/\u00d7/g,'*').replace(/\u00f7/g,'/')
              .replace(/\uff08/g,'(').replace(/\uff09/g,')');
    if(!t.length || !/^[0-9+\-*/()]+$/.test(t)) return null;
    var i=0;
    function peek(){ return t.charAt(i); }
    function num(){ var st=i; while(i<t.length && /[0-9]/.test(t.charAt(i))) i++; if(st===i) return null; return {t:'num', v:parseInt(t.slice(st,i),10)}; }
    function factor(){
      if(peek()==='('){ i++; var v=expr(); if(peek()===')') i++; return v; }
      if(peek()==='-'){ i++; var x=factor(); return x?{t:'neg',x:x}:null; }
      if(peek()==='+'){ i++; return factor(); }
      return num();
    }
    function term(){ var v=factor(); while(v && (peek()==='*'||peek()==='/')){ var op=peek(); i++; var r=factor(); v=(v&&r)?{t:'bin',op:op,l:v,r:r}:null; } return v; }
    function expr(){ var v=term(); while(v && (peek()==='+'||peek()==='-')){ var op=peek(); i++; var r=term(); v=(v&&r)?{t:'bin',op:op,l:v,r:r}:null; } return v; }
    var out=expr();
    if(!out || i!==t.length) return null;
    return out;
  }
  function evalNode(n){
    if(!n) return NaN;
    if(n.t==='num') return n.v;
    if(n.t==='neg') return -evalNode(n.x);
    var a=evalNode(n.l), b=evalNode(n.r);
    if(n.op==='+') return a+b;
    if(n.op==='-') return a-b;
    if(n.op==='*') return a*b;
    return b===0?NaN:a/b;
  }
  function divNodes(n, out){
    out=out||[];
    if(!n) return out;
    if(n.t==='bin'){
      if(n.op==='/') out.push({a:evalNode(n.l), b:evalNode(n.r), raw:String(n.l.t==='num'?n.l.v:'('+evalNode(n.l)+')')+'\u00f7'+evalNode(n.r)});
      divNodes(n.l,out); divNodes(n.r,out);
    } else if(n.t==='neg'){ divNodes(n.x,out); }
    return out;
  }
  function exprValue(src){ var n=parseExpr(src); return n?evalNode(n):NaN; }

  if(rm){
    var need=['LEVELS','mulberry32','makeQuestion','makeQuestions','normalizeInput','checkAnswer','pointsFor','starsFor','formatClock','bestKey'];
    var miss=need.filter(function(k){ return rm[k]===undefined || (k!=='LEVELS' && typeof rm[k]!=='function'); });
    ok('core.members', miss.length===0, miss.join(','));

    var LV=Array.isArray(rm.LEVELS)?rm.LEVELS:[];
    ok('core.levels.array', Array.isArray(rm.LEVELS) && rm.LEVELS.length===4, Array.isArray(rm.LEVELS)?('len='+rm.LEVELS.length):'not-array');
    var ids=LV.map(function(l){ return l&&l.id; });
    ok('core.levels.ids', JSON.stringify(ids)===JSON.stringify([1,2,3,4]), JSON.stringify(ids));
    var shapeBad=[];
    LV.forEach(function(l){
      var good = l && typeof l.id==='number' && typeof l.name==='string' && l.name.length>0 &&
                 typeof l.sub==='string' && Array.isArray(l.ops) && l.ops.length>0 &&
                 typeof l.count==='number' && l.count>=4 && l.count<=50 &&
                 typeof l.time==='number' && l.time>0 && isFinite(l.time);
      if(!good) shapeBad.push(JSON.stringify({id:l&&l.id,name:l&&l.name,sub:l&&l.sub,ops:l&&l.ops,count:l&&l.count,time:l&&l.time}));
    });
    ok('core.levels.shape', shapeBad.length===0, shapeBad.join(' '));
    ok('core.levels.names', LV.length===4 && LV.every(function(l){ return /\u5e74\u7ea7/.test(String(l.name)); }), LV.map(function(l){return String(l.name);}).join('/'));
    ok('core.levels.ops', LV.every(function(l){ return l.ops.every(function(o){ return OPOK.indexOf(o)>=0; }); }), JSON.stringify(LV.map(function(l){return l.ops;})));

    function seq(seed,n){ var r=rm.mulberry32(seed), a=[]; for(var i=0;i<n;i++) a.push(r()); return a; }
    ok('core.rng.deterministic', JSON.stringify(seq(123,32))===JSON.stringify(seq(123,32)), 'n=32');
    ok('core.rng.range', [1,2,3,7,99,12345].every(function(s){
      var r=rm.mulberry32(s);
      for(var i=0;i<400;i++){ var v=r(); if(!(typeof v==='number' && isFinite(v) && v>=0 && v<1)) return false; }
      return true;
    }), '');
    ok('core.rng.seedDiffers', JSON.stringify(seq(1,16))!==JSON.stringify(seq(2,16)), '');
    var distinct={}, rr=rm.mulberry32(42);
    for(var di=0; di<1000; di++) distinct[rr()]=1;
    ok('core.rng.variance', Object.keys(distinct).length>=500, 'distinct='+Object.keys(distinct).length);

    var LVIDS=[1,2,3,4];
    var structBad=[], opBad=[], ansBad=[], evalBad=[], symBad=[], divBad=[], divUnparsed=[];
    for(var li=0; li<LVIDS.length; li++){
      for(var sd=1; sd<=12; sd++){
        var qs=rm.makeQuestions(LVIDS[li],24,sd);
        for(var k=0;k<qs.length;k++){
          var q=qs[k];
          if(!q || typeof q.text!=='string' || !q.text.length || q.op===undefined || q.op===null){ structBad.push('L'+LVIDS[li]+'s'+sd+'#'+k); continue; }
          if(OPOK.indexOf(q.op)<0) opBad.push(String(q.op));
          if(String(q.text).indexOf(q.op)<0) symBad.push(String(q.text)+'|'+q.op);
          if(!(typeof q.answer==='number' && isFinite(q.answer) && Math.floor(q.answer)===q.answer && q.answer>=0)) ansBad.push('L'+LVIDS[li]+'s'+sd+'#'+k+'='+q.answer);
          var tree=parseExpr(q.text);
          if(!tree){ evalBad.push('no-parse:'+q.text); continue; }
          var v=evalNode(tree);
          if(!(isFinite(v) && v===q.answer)) evalBad.push(String(q.text)+'='+v+'!='+q.answer);
          var dns=divNodes(tree,[]);
          if(String(q.text).indexOf('\u00f7')>=0 && dns.length===0) divUnparsed.push(String(q.text));
          for(var dq=0;dq<dns.length;dq++){
            if(dns[dq].b===0) divBad.push('zero:'+q.text);
            else if(dns[dq].a%dns[dq].b!==0) divBad.push('inexact:'+q.text+'('+dns[dq].a+'/'+dns[dq].b+')');
          }
        }
      }
    }
    ok('core.question.shape', structBad.length===0, structBad.slice(0,4).join(','));
    ok('core.question.op', opBad.length===0, opBad.slice(0,4).join(','));
    ok('core.question.opSymbol', symBad.length===0, symBad.slice(0,3).join(' '));
    ok('core.question.answerInt', ansBad.length===0, ansBad.slice(0,4).join(','));
    ok('core.question.evalMatchesAnswer', evalBad.length===0, evalBad.slice(0,3).join(' | '));
    ok('core.question.divExact', divBad.length===0, divBad.slice(0,3).join(' '));
    ok('core.question.divParsed', divUnparsed.length===0, divUnparsed.slice(0,3).join(' '));
    ok('core.question.noDivZero', !/\u00f7\s*\(?\s*0\s*\)?/.test((function(){ var s=''; LVIDS.forEach(function(l){ for(var x=1;x<=4;x++){ rm.makeQuestions(l,20,x).forEach(function(q){ s+=' '+q.text; }); } }); return s; })()), '');

    var l1Bad=[], l1Res=[];
    for(var s1=1;s1<=12;s1++){
      var q1=rm.makeQuestions(1,30,s1);
      q1.forEach(function(q){
        var nums=String(q.text).match(/\d+/g)||[];
        nums.forEach(function(n){ if(parseInt(n,10)>20) l1Bad.push(q.text); });
        if(q.answer>20 || q.answer<0) l1Res.push(q.text+'='+q.answer);
      });
    }
    ok('core.question.level1.operands', l1Bad.length===0, l1Bad.slice(0,3).join(' '));
    ok('core.question.level1.result', l1Res.length===0, l1Res.slice(0,3).join(' '));

    var repBad=[];
    LVIDS.forEach(function(l){ for(var x=1;x<=6;x++){ if(JSON.stringify(rm.makeQuestions(l,20,x))!==JSON.stringify(rm.makeQuestions(l,20,x))) repBad.push('L'+l+'s'+x); } });
    ok('core.question.reproduce', repBad.length===0, repBad.join(','));
    var diffBad=[];
    LVIDS.forEach(function(l){ if(JSON.stringify(rm.makeQuestions(l,20,1))===JSON.stringify(rm.makeQuestions(l,20,2))) diffBad.push('L'+l); });
    ok('core.question.seedDiffers', diffBad.length===0, diffBad.join(','));
    var adjBad=[];
    LVIDS.forEach(function(l){ for(var x=1;x<=6;x++){ var qq=rm.makeQuestions(l,30,x); for(var j=1;j<qq.length;j++){ if(qq[j].text===qq[j-1].text) adjBad.push('L'+l+'s'+x+'#'+j); } } });
    ok('core.question.adjacent', adjBad.length===0, adjBad.slice(0,3).join(','));
    var lenBad=[];
    [4,10,50].forEach(function(c){ var got=rm.makeQuestions(2,c,9); if(!got || got.length!==c) lenBad.push(c+':'+(got?got.length:'null')); });
    ok('core.question.count', lenBad.length===0, lenBad.join(','));

    var mqBad=[];
    LVIDS.forEach(function(l){
      var r=rm.mulberry32(l*13);
      for(var i=0;i<20;i++){
        var q=rm.makeQuestion(l,r);
        if(!(q && typeof q.text==='string' && typeof q.answer==='number' && OPOK.indexOf(q.op)>=0 && exprValue(q.text)===q.answer && q.answer>=0)) mqBad.push('L'+l+':'+JSON.stringify(q));
      }
    });
    ok('core.makeQuestion.levels', mqBad.length===0, mqBad.slice(0,2).join(' '));
    var one=rm.makeQuestion(2, rm.mulberry32(7));
    ok('core.makeQuestion.single', !!(one && typeof one.text==='string' && typeof one.answer==='number' && OPOK.indexOf(one.op)>=0 && exprValue(one.text)===one.answer), JSON.stringify(one).slice(0,80));

    ok('core.norm.fullwidth', rm.normalizeInput('\uff11\uff12\uff13')==='123', JSON.stringify(rm.normalizeInput('\uff11\uff12\uff13')));
    ok('core.norm.spaces', rm.normalizeInput(' 1 2\t3 ')==='123', JSON.stringify(rm.normalizeInput(' 1 2\t3 ')));
    ok('core.norm.minus', rm.normalizeInput('- 5')==='-5' && rm.normalizeInput('-5')==='-5', JSON.stringify(rm.normalizeInput('- 5'))+'/'+JSON.stringify(rm.normalizeInput('-5')));
    ok('core.norm.dropOther', rm.normalizeInput('1a2+3')==='123', JSON.stringify(rm.normalizeInput('1a2+3')));
    ok('core.norm.empty', rm.normalizeInput('')==='' && rm.normalizeInput('   ')==='', JSON.stringify(rm.normalizeInput('   ')));
    ok('core.norm.nonString', rm.normalizeInput(undefined)==='' && rm.normalizeInput(null)==='' && rm.normalizeInput({})==='' && rm.normalizeInput([])==='' && rm.normalizeInput(true)==='' && rm.normalizeInput(NaN)==='', 'undefined/null/object/array/bool/NaN 都按空串');
    ok('core.norm.numericSubmit', rm.checkAnswer({answer:123}, 123)===true, 'submit(v) 允许直接传数字（自动化与页内自测都这么用）');

    var Q7={answer:7};
    ok('core.check.correct', rm.checkAnswer(Q7,'7')===true, '');
    ok('core.check.spaces', rm.checkAnswer(Q7,' 7 ')===true, '');
    ok('core.check.fullwidth', rm.checkAnswer(Q7,'\uff17')===true, '');
    ok('core.check.wrong', rm.checkAnswer(Q7,'8')===false, '');
    ok('core.check.empty', rm.checkAnswer(Q7,'')===false, '');
    ok('core.check.negativeNotEqual', rm.checkAnswer(Q7,'-7')===false, '');
    ok('core.check.punctuationStripped', rm.checkAnswer(Q7,'7.5')===false, '归一化只留数字与 -，7.5 -> 75');

    ok('core.points.wrongZero', rm.pointsFor(false,9,100,1)===0 && rm.pointsFor(false,0,0,4)===0 && rm.pointsFor(false,30,99999,3)===0, '');
    var posBad=[];
    LVIDS.forEach(function(l){ [0,5,20].forEach(function(c){ [0,1500,9000].forEach(function(t){
      var p=rm.pointsFor(true,c,t,l);
      if(!(typeof p==='number' && isFinite(p) && Math.floor(p)===p && p>0)) posBad.push('L'+l+'c'+c+'t'+t+'='+p);
    }); }); });
    ok('core.points.positive', posBad.length===0, posBad.slice(0,3).join(' '));
    var mcBad=[];
    LVIDS.forEach(function(l){ [0,1000,5000].forEach(function(t){
      var prev=-1;
      for(var c=0;c<=30;c++){ var p=rm.pointsFor(true,c,t,l); if(p<prev) mcBad.push('L'+l+'t'+t+'c'+c+':'+prev+'->'+p); prev=p; }
    }); });
    ok('core.points.comboMono', mcBad.length===0, mcBad.slice(0,3).join(' '));
    var mtBad=[];
    LVIDS.forEach(function(l){ [0,3,10].forEach(function(c){
      var prev=Infinity;
      for(var t=0;t<=20000;t+=500){ var p=rm.pointsFor(true,c,t,l); if(p>prev) mtBad.push('L'+l+'c'+c+'t'+t+':'+prev+'->'+p); prev=p; }
    }); });
    ok('core.points.timeMono', mtBad.length===0, mtBad.slice(0,3).join(' '));

    function st(acc,total,correct){ return rm.starsFor(acc,total,correct); }
    var tbl=[[0.95,10,10,3],[0.9,10,9,3],[0.89,10,9,2],[0.7,10,7,2],[0.69,10,7,1],[0.4,10,4,1],[0.39,10,4,0],[1,1,1,3],[0.5,2,1,1]];
    var tblBad=[];
    tbl.forEach(function(r){ var g=st(r[0],r[1],r[2]); if(g!==r[3]) tblBad.push(JSON.stringify(r)+'->'+g); });
    ok('core.stars.table', tblBad.length===0, tblBad.slice(0,4).join(' '));
    ok('core.stars.zeroTotal', st(0.9,0,0)===0 && st(0,0,0)===0 && st(0.5,-1,0)===0, '');
    ok('core.stars.zeroCorrect', st(1,10,0)===0 && st(0.9,5,0)===0, '');
    var rangeBad='';
    for(var tt=0;tt<=20;tt++){ for(var cc=0;cc<=tt;cc++){ var g=st(tt?cc/tt:0,tt,cc); if(!(g>=0&&g<=3&&Math.floor(g)===g)){ rangeBad='t'+tt+'c'+cc+'='+g; break; } } if(rangeBad) break; }
    ok('core.stars.range', rangeBad==='', rangeBad);
    var monoBad=''; var prevS=-1;
    for(var ai=0;ai<=100;ai++){ var acc=ai/100; var gs=st(acc,100,Math.round(acc*100)); if(gs<prevS){ monoBad=acc+':'+prevS+'->'+gs; break; } prevS=gs; }
    ok('core.stars.mono', monoBad==='', monoBad);

    ok('core.clock.basic', rm.formatClock(0)==='0:00' && rm.formatClock(5)==='0:05' && rm.formatClock(65)==='1:05' && rm.formatClock(600)==='10:00' && rm.formatClock(3599)==='59:59',
       [rm.formatClock(0),rm.formatClock(5),rm.formatClock(65),rm.formatClock(600),rm.formatClock(3599)].join(','));
    ok('core.clock.bad', rm.formatClock(-5)==='0:00' && rm.formatClock(NaN)==='0:00' && rm.formatClock(-1000)==='0:00',
       [rm.formatClock(-5),rm.formatClock(NaN),rm.formatClock(-1000)].join(','));

    var bkBad=[];
    ['time','count'].forEach(function(m){ for(var l=1;l<=4;l++){ var k=rm.bestKey(l,m); if(k!=='randommath.best.'+l+'.'+m) bkBad.push(String(k)); } });
    ok('core.bestKey.shape', bkBad.length===0, bkBad.slice(0,3).join(','));
    var keys=[];
    ['time','count'].forEach(function(m){ for(var l=1;l<=4;l++) keys.push(String(rm.bestKey(l,m))); });
    var uniq={}; keys.forEach(function(k){ uniq[k]=1; });
    ok('core.bestKey.unique', Object.keys(uniq).length===8, 'uniq='+Object.keys(uniq).length);
  }

  L.push('RMCHECK_END');
  var pre=document.getElementById('rmcheck');
  if(pre) pre.textContent=L.join('\n');
})();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------- 探针页（全流程 / URL 参数）
$headHook = @'
<script>
/* rm-verifier 自写探针：尽早挂上错误与外部请求监听（独立于页面实现） */
(function(){
  window.__rmExternal=[]; window.__rmErrors=[];
  window.addEventListener('error', function(e){ try{ window.__rmErrors.push(String((e&&e.message)||e.type)); }catch(_){} });
  window.addEventListener('unhandledrejection', function(e){ try{ window.__rmErrors.push('rejection:'+String(e&&e.reason)); }catch(_){} });
  try{
    var of=window.fetch;
    if(of){ window.fetch=function(u){ try{ var s=String(u); if(/^https?:/i.test(s)) window.__rmExternal.push(s); }catch(_){} return of.apply(this, arguments); }; }
  }catch(_){}
  try{
    var oo=XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open=function(m,u){ try{ var s=String(u); if(/^https?:/i.test(s)) window.__rmExternal.push(s); }catch(_){} return oo.apply(this, arguments); };
  }catch(_){}
})();
</script>
'@

$probeJs = @'
<script>
/* rm-verifier 自写探针（独立断言，不读取页面 selftest 的结论） */
(function(){
  var RM_TAG='__RM_TAG__';
  var ALL_IDS=['screenMenu','screenPlay','screenResult','levelBtns','modeBtns','startBtn','score','combo','progress','acc','timerBar','question','answerInput','keypad','submitBtn','feedback','rScore','rAcc','rStars','rBest','againBtn','menuBtn','themeBtn','soundBtn','selftest'];
  var L=[];
  function san(s){ return String(s==null?'':s).replace(/[|\r\n\t]/g,' ').replace(/[^\x20-\x7E]/g,'.').slice(0,180); }
  function raw(n,c,d){ L.push('RM|'+(c?1:0)+'|'+n+'|'+san(d==null?'':d)); }
  function C(n,c,d){ raw(RM_TAG+'.'+n, c, d); }
  function I(n,v){ L.push('RM|I|'+RM_TAG+'.'+n+'|'+san(v==null?'':v)); }
  /* 视口守卫：证明「宽屏/窄屏」两组断言跑在预期宽度下，避免溢出断言被空转 */
  function viewportGuard(){
    var w=window.innerWidth;
    if(RM_TAG.indexOf('narrow')===0) C('viewport.narrow', w<=520, 'innerWidth='+w);
    else C('viewport.wide', w>=900, 'innerWidth='+w);
    I('viewport', w+'x'+window.innerHeight);
  }
  function el(id){ return document.getElementById(id); }
  function txt(id){ var e=el(id); return e?(e.textContent==null?'':e.textContent):null; }
  function vis(id){
    var e=el(id); if(!e||e.hidden) return false;
    try{ var cs=window.getComputedStyle(e); if(cs){ if(cs.display==='none'||cs.visibility==='hidden'||cs.opacity==='0') return false; } }catch(err){}
    var r=e.getBoundingClientRect();
    return (r.width>0 && r.height>0);
  }
  function dirty(s){ return /NaN|undefined/.test(String(s==null?'':s)); }
  function api(){ return window.randommath; }
  function core(){ var a=api(); return a?a.core:null; }
  function state(){ try{ return api().state(); }catch(e){ return {__err:String((e&&e.message)||e)}; } }
  function setInput(v){
    var i=el('answerInput'); if(!i) return;
    i.value=String(v);
    try{ i.dispatchEvent(new Event('input',{bubbles:true})); i.dispatchEvent(new Event('change',{bubbles:true})); }catch(e){}
  }
  function pressSubmit(){ var b=el('submitBtn'); if(b) b.click(); }
  function parseNum(s){ if(s==null) return NaN; var m=String(s).match(/-?\d+(\.\d+)?/); return m?parseFloat(m[0]):NaN; }
  function accNum(s){
    var t=String(s==null?'':s);
    var m=t.match(/(\d+(\.\d+)?)\s*%/); if(m) return parseFloat(m[1]);
    var m2=t.match(/(\d+(\.\d+)?)/); if(!m2) return NaN;
    var v=parseFloat(m2[1]); return v<=1?v*100:v;
  }
  function starsFromDom(){
    var t=String(txt('rStars')==null?'':txt('rStars'));
    var filled=(t.match(/\u2605/g)||[]).length;
    if(filled===0 && t.indexOf('\u2606')<0){ var m=t.match(/\d+/); if(m) filled=parseInt(m[0],10); }
    return filled;
  }
  function overflow(){
    var d=document.documentElement, b=document.body;
    var sw=Math.max(d?d.scrollWidth:0, b?b.scrollWidth:0);
    return sw - window.innerWidth;
  }
  /* 只收集可见 UI 的文本：body.textContent 会把 <script> 源码也算进来，
     页面与探针的源码里本来就有 'NaN'/'undefined' 字面量，必须排除 */
  function visibleText(root){
    var out='', stack=[root];
    while(stack.length){
      var n=stack.pop();
      if(!n || !n.childNodes) continue;
      for(var i=0;i<n.childNodes.length;i++){
        var c=n.childNodes[i];
        if(c.nodeType===3){ out+=' '+c.nodeValue; }
        else if(c.nodeType===1 && c.tagName!=='SCRIPT' && c.tagName!=='STYLE'){ stack.push(c); }
      }
    }
    return out;
  }
  function themeSig(){
    var a=[];
    try{ a.push(document.documentElement.getAttribute('data-theme')||''); }catch(e){}
    try{ a.push(document.documentElement.className||''); }catch(e){}
    try{ a.push(document.body.className||''); }catch(e){}
    try{ a.push(document.body.getAttribute('data-theme')||''); }catch(e){}
    try{ a.push(localStorage.getItem('randommath.theme')||''); }catch(e){}
    return a.join('|');
  }
  function externalResources(){
    var out=[];
    try{
      var rs=performance.getEntriesByType('resource')||[];
      for(var i=0;i<rs.length;i++){ if(!/^(file|data|blob):/i.test(rs[i].name)) out.push(rs[i].name); }
    }catch(e){}
    try{
      var els=document.querySelectorAll('[src],[href]');
      for(var j=0;j<els.length;j++){
        var u=els[j].getAttribute('src')||els[j].getAttribute('href')||'';
        if(/^https?:/i.test(u)) out.push(u);
      }
    }catch(e){}
    return out;
  }
  function keypadInfo(){
    var kp=el('keypad');
    var info={digits:{},back:null,submit:null,n:0};
    if(!kp) return info;
    var nodes=kp.querySelectorAll('*');
    for(var i=0;i<nodes.length;i++){
      var n=nodes[i], key=String(n.getAttribute('data-key')||n.getAttribute('data-value')||n.getAttribute('data-num')||'');
      var t=String(n.textContent==null?'':n.textContent).replace(/\s/g,'');
      info.n++;
      if(/^[0-9]$/.test(key) && !info.digits[key]) info.digits[key]=n;
      if(/^[0-9]$/.test(t) && !info.digits[t]) info.digits[t]=n;
      if(!info.back && (/^(del|back|backspace|delete|clear)$/i.test(key) || /^(\u232b|\u2190|\u9000\u683c|\u5220\u9664|\u6e05\u7a7a)$/.test(t))) info.back=n;
      if(!info.submit && (/^(submit|ok|enter|go|confirm)$/i.test(key) || /^(\u63d0\u4ea4|\u786e\u5b9a|\u786e\u8ba4|\u7b54\u9898|=|\u2713)$/.test(t))) info.submit=n;
    }
    return info;
  }
  function stateShapeOk(s){
    if(!s || typeof s!=='object') return false;
    var keys=['screen','level','mode','score','combo','correct','wrong','index','total','remaining','question','lastResult'];
    for(var i=0;i<keys.length;i++){ if(!(keys[i] in s)) return false; }
    if(['menu','play','result'].indexOf(s.screen)<0) return false;
    if(['time','count'].indexOf(s.mode)<0) return false;
    var nums=['score','combo','correct','wrong','index','total','remaining'];
    for(var j=0;j<nums.length;j++){ if(typeof s[nums[j]]!=='number' || !isFinite(s[nums[j]])) return false; }
    if(s.question!==null && !(typeof s.question==='object' && typeof s.question.text==='string' && typeof s.question.answer==='number')) return false;
    if([null,'correct','wrong'].indexOf(s.lastResult)<0) return false;
    return true;
  }
  function noExternal(label){
    var ext=(window.__rmExternal||[]).concat(externalResources());
    C(label+'.noExternal', ext.length===0, ext.slice(0,3).join(' '));
    I(label+'.externalRequests', ext.length);
  }
  function noJsError(label){
    var errs=window.__rmErrors||[];
    C(label+'.noJsError', errs.length===0, errs.slice(0,3).join(' | '));
  }

  function urlChecks(why){
    var a=api(), c=core();
    viewportGuard();
    I('overflow', overflow()+'px');
    I('result.score', txt('rScore'));
    I('result.acc', txt('rAcc'));
    I('result.stars', starsFromDom()+'/3');
    I('result.best', txt('rBest'));
    I('state.counts', 'correct='+state().correct+' wrong='+state().wrong);
    C('url.screen.result', state().screen==='result', 'wait='+why+' screen='+state().screen+' q='+location.search);
    C('url.result.visible', vis('screenResult') && !vis('screenPlay'));
    C('url.result.noNaN', !dirty(txt('screenResult')) && !dirty(txt('rScore')+txt('rAcc')+txt('rStars')+txt('rBest')));
    C('url.result.rScore', parseNum(txt('rScore'))===state().score, 'dom='+txt('rScore')+' state='+state().score);
    var att=state().correct+state().wrong;
    var exp=c?c.starsFor(att?state().correct/att:0, att, state().correct):-1;
    C('url.result.rStars', starsFromDom()===exp, 'dom='+starsFromDom()+' core='+exp);
    C('url.result.rBest', txt('rBest')!==null && String(txt('rBest')).replace(/\s/g,'').length>0 && !dirty(txt('rBest')));
    C('url.hud.noNaN', !dirty(txt('score')+txt('combo')+txt('progress')+txt('acc')+txt('question')));
    C('url.dom.idsAll', ALL_IDS.every(function(id){ return !!el(id); }));
    C('url.overflow', overflow()<=1, 'overflow='+overflow()+'px');
    noExternal('url');
    noJsError('url');
    if(/miss=2/.test(location.search)) C('url.miss.counts', state().correct===4 && state().wrong===2, JSON.stringify({c:state().correct,w:state().wrong}));
    if(/count=4/.test(location.search) && /solve=4/.test(location.search)) C('url.solve.counts', state().correct===4 && state().wrong===0, JSON.stringify({c:state().correct,w:state().wrong}));
    if(/mode=time/.test(location.search)) C('url.time.ended', state().mode==='time' && state().screen==='result', 'mode='+state().mode);
    if(/theme=dark/.test(location.search)) C('url.theme.dark', themeSig().indexOf('dark')>=0, themeSig().slice(0,60));
  }

  function flow(){
    var i, a=api(), c=core();
    viewportGuard();
    /* --- DOM id 齐备（逐条） --- */
    var missing=[];
    for(i=0;i<ALL_IDS.length;i++){
      var e=el(ALL_IDS[i]);
      C('dom.id.'+ALL_IDS[i], !!e, e?'':'missing');
      if(!e) missing.push(ALL_IDS[i]);
    }
    C('dom.idsAll', missing.length===0, 'missing='+missing.join(','));
    C('api.object', !!a && typeof a==='object');
    C('api.fns', !!(a && ['state','start','submit','ff','selftest'].every(function(f){ return typeof a[f]==='function'; })));
    C('api.core', !!(c && typeof c.makeQuestion==='function' && typeof c.makeQuestion==='function' && c.LEVELS!==undefined));
    C('state.shape', stateShapeOk(state()), JSON.stringify(state()).slice(0,120));

    /* --- 菜单 --- */
    C('menu.state', state().screen==='menu', 'screen='+state().screen);
    C('menu.visible', vis('screenMenu') && !vis('screenPlay') && !vis('screenResult'));
    C('menu.noNaN', !dirty(txt('screenMenu')));
    C('menu.overflow', overflow()<=1, 'overflow='+overflow()+'px');
    I('overflow.menu', overflow()+'px');
    C('menu.levelBtns4', !!(el('levelBtns') && el('levelBtns').querySelectorAll('[data-level]').length===4), el('levelBtns')?String(el('levelBtns').querySelectorAll('[data-level]').length):'no-el');
    var lvOk=[1,2,3,4].every(function(n){ return !!(el('levelBtns') && el('levelBtns').querySelector('[data-level="'+n+'"]')); });
    C('menu.levelBtnsData', lvOk);
    C('menu.modeBtns', !!(el('modeBtns') && el('modeBtns').querySelector('[data-mode="time"]') && el('modeBtns').querySelector('[data-mode="count"]')));
    C('menu.answerInputIsInput', !!(el('answerInput') && el('answerInput').tagName==='INPUT'));
    var kp=keypadInfo();
    var digitsOk=[0,1,2,3,4,5,6,7,8,9].every(function(d){ return !!kp.digits[String(d)]; });
    C('menu.keypadDigits', digitsOk, 'found='+Object.keys(kp.digits).join(''));
    C('menu.keypadBackspace', !!kp.back);
    C('menu.keypadSubmit', !!kp.submit);
    C('menu.selftestHost', !!(el('selftest')));

    /* --- 菜单→游戏（点真实控件） --- */
    if(el('levelBtns')){ var lb=el('levelBtns').querySelector('[data-level="2"]'); if(lb) lb.click(); }
    if(el('modeBtns')){ var mb=el('modeBtns').querySelector('[data-mode="count"]'); if(mb) mb.click(); }
    if(el('startBtn')) el('startBtn').click();
    C('ui.start.screen', state().screen==='play', 'screen='+state().screen);
    C('ui.start.level', state().level===2, 'level='+state().level);
    C('ui.start.mode', state().mode==='count', 'mode='+state().mode);
    C('play.visible', vis('screenPlay') && !vis('screenMenu'));

    /* --- 固定题数：5 题，共 4 对 1 错（反馈期间停留原题，用 ff 清反馈推进下一题） --- */
    a.start({level:2, mode:'count', count:5, seed:42});
    var s=state();
    C('start.screen', s.screen==='play', 'screen='+s.screen);
    C('start.total', s.total===5, 'total='+s.total);
    C('start.index', s.index===1 && s.asked===1, 'index='+s.index+' asked='+s.asked);
    C('start.remaining', s.remaining===4, 'remaining='+s.remaining);
    C('start.reset', s.score===0 && s.combo===0 && s.correct===0 && s.wrong===0, JSON.stringify({sc:s.score,cb:s.combo,ok:s.correct,no:s.wrong}));
    C('start.question', !!(s.question && typeof s.question.text==='string' && s.question.text.length>0 && typeof s.question.answer==='number'), JSON.stringify(s.question));
    var det=(c && c.makeQuestions(2,5,42)||[])[0];
    C('start.deterministic', !!(det && s.question && det.text===s.question.text), 'state='+(s.question&&s.question.text)+' core='+(det&&det.text));
    var qtxt=txt('question');
    C('play.questionDom', !!(qtxt && s.question && qtxt.indexOf(s.question.text)>=0 && qtxt.indexOf('?')>=0), 'dom='+qtxt);
    C('play.hudNoNaN', !dirty(txt('score')+txt('combo')+txt('progress')+txt('acc')));
    C('play.timerBarNoNaN', !dirty(el('timerBar')?el('timerBar').outerHTML:'no-el'));
    C('play.hudScoreZero', parseNum(txt('score'))===0, 'dom='+txt('score'));
    C('play.overflow', overflow()<=1, 'overflow='+overflow()+'px');
    I('overflow.play', overflow()+'px');
    noExternal('play');
    noJsError('play');

    /* 第 1 题：答对 */
    var q1=s.question;
    setInput(q1.answer); pressSubmit();
    var s2=state();
    C('answer.correctFlag', s2.lastResult==='correct', 'lastResult='+s2.lastResult);
    C('answer.correctCount', s2.correct===1 && s2.wrong===0, JSON.stringify({c:s2.correct,w:s2.wrong}));
    C('answer.comboUp', s2.combo===1, 'combo='+s2.combo);
    C('answer.scoreUp', s2.score>0 && Math.floor(s2.score)===s2.score, 'score='+s2.score);
    C('answer.heldDuringFeedback', s2.index===1 && s2.question!==null, 'index='+s2.index);
    C('answer.hudScore', parseNum(txt('score'))===s2.score, 'dom='+txt('score')+' state='+s2.score);
    var fbCorrect=String(txt('feedback')==null?'':txt('feedback'));
    C('answer.feedbackShown', fbCorrect.replace(/\s/g,'').length>0 && !dirty(fbCorrect), 'feedback='+fbCorrect);
    a.ff(2);
    var s2b=state();
    C('answer.advancedAfterFeedback', s2b.index===2 && s2b.question!==null && s2b.lastResult===null, JSON.stringify({i:s2b.index,q:!!s2b.question,lr:s2b.lastResult}));
    C('answer.feedbackCleared', String(txt('feedback')||'').replace(/\s/g,'').length===0, 'feedback='+txt('feedback'));

    /* 第 2 题：答错（用输入框 + 提交按钮） */
    var q2=state().question, wrongVal=Number(q2.answer)+1;
    setInput(wrongVal); pressSubmit();
    var s3=state();
    C('wrong.correctFlag', s3.lastResult==='wrong', 'lastResult='+s3.lastResult);
    C('wrong.counts', s3.wrong===1 && s3.correct===1, JSON.stringify({c:s3.correct,w:s3.wrong}));
    C('wrong.comboCleared', s3.combo===0, 'combo='+s3.combo);
    C('wrong.scoreUnchanged', s3.score===s2.score, 'before='+s2.score+' after='+s3.score);
    var fbWrong=String(txt('feedback')==null?'':txt('feedback'));
    C('wrong.feedbackShown', fbWrong.replace(/\s/g,'').length>0 && !dirty(fbWrong), 'feedback='+fbWrong);
    C('wrong.feedbackDiffers', fbWrong!==fbCorrect, 'correct='+fbCorrect+' wrong='+fbWrong);
    a.ff(3);
    C('wrong.advancedAfterFeedback', state().index===3, 'index='+state().index);

    /* 全角输入经 submit 归一化判对 + 输入框只保留数字与负号 */
    a.start({level:2, mode:'count', count:5, seed:6});
    var fwq=state().question;
    var fw=fwq?String(fwq.answer).replace(/[0-9]/g,function(d){ return String.fromCharCode(d.charCodeAt(0)+0xFEE0); }):'';
    var fwOk=false;
    try{ fwOk=a.submit(fw); }catch(e){}
    C('answer.fullwidthSubmit', fwOk===true && state().lastResult==='correct', 'fw='+fw+' submitted='+fwOk+' lr='+state().lastResult);
    a.ff(2);
    setInput('a1\uff12b-3');
    var iv=String(el('answerInput').value);
    C('answer.inputSanitized', /^[0-9-]*$/.test(iv) && iv.length>0, 'value='+iv);
    a.ff(2);

    /* 屏幕数字键盘点击答题 */
    a.start({level:1, mode:'count', count:4, seed:6});
    var sK=state(), kp2=keypadInfo(), want=String(sK.question.answer);
    setInput('');
    for(i=0;i<want.length;i++){ var db=kp2.digits[want.charAt(i)]; if(db) db.click(); }
    C('keypad.typing', String(el('answerInput').value)===want, 'input='+el('answerInput').value+' want='+want);
    if(kp2.submit) kp2.submit.click(); else pressSubmit();
    C('keypad.answerAccepted', state().lastResult==='correct', 'lastResult='+state().lastResult);
    a.ff(2);

    /* 连击与得分递增（连着答对 3 题） */
    a.start({level:3, mode:'count', count:8, seed:21});
    var combos=[], scores=[];
    for(i=0;i<3;i++){ var qc=state().question; setInput(qc.answer); pressSubmit(); var sc=state(); combos.push(sc.combo); scores.push(sc.score); a.ff(2); }
    C('combo.grows', combos[0]===1 && combos[1]===2 && combos[2]===3, combos.join(','));
    C('score.grows', scores[0]<scores[1] && scores[1]<scores[2], scores.join(','));

    /* submit 空输入不加分、不崩 */
    a.start({level:2, mode:'count', count:5, seed:5});
    var b0=state().score;
    var emptyErr='';
    try{ a.submit(''); }catch(e){ emptyErr=String((e&&e.message)||e); }
    C('submit.emptyNoScore', emptyErr==='' && state().score===b0, emptyErr||('score='+state().score));

    /* 固定题数结束条件 */
    a.start({level:2, mode:'count', count:5, seed:42});
    C('count.ffKeepsPlay', (function(){ a.ff(2); return state().screen==='play'; })(), 'screen='+state().screen);
    setInput(state().question.answer); pressSubmit(); a.ff(2);                 // 1 对
    setInput(Number(state().question.answer)+1); pressSubmit(); a.ff(3);      // 1 错
    var guard=0;
    while(state().screen==='play' && guard++<60){
      var stq=state();
      if(!stq.question) break;
      setInput(stq.question.answer); pressSubmit(); a.ff(2);
    }
    var s4=state();
    C('count.end', s4.screen==='result', 'screen='+s4.screen+' guard='+guard);
    C('count.exact', (s4.correct+s4.wrong)===5 && s4.correct===4 && s4.wrong===1 && s4.asked===5, JSON.stringify({c:s4.correct,w:s4.wrong,asked:s4.asked}));
    C('count.playHidden', !vis('screenPlay'));
    C('result.visible', vis('screenResult'));
    C('result.noNaN', !dirty(txt('screenResult')) && !dirty(txt('rScore')+txt('rAcc')+txt('rStars')+txt('rBest')));
    var bodyTxt=visibleText(document.body);
    var selfTxt=String(txt('selftest')||'');
    if(selfTxt) bodyTxt=bodyTxt.split(selfTxt).join('');
    var rmTxt=String(txt('rmcheck')||'');
    if(rmTxt) bodyTxt=bodyTxt.split(rmTxt).join('');
    C('result.bodyNoNaN', !dirty(bodyTxt), bodyTxt.replace(/\s+/g,' ').slice(0,120));
    C('result.rScore', parseNum(txt('rScore'))===s4.score, 'dom='+txt('rScore')+' state='+s4.score);
    C('result.rAcc', Math.abs(accNum(txt('rAcc'))-80)<=1.5, 'acc='+txt('rAcc')+' expect~80');
    var expStars=c?c.starsFor(s4.total?s4.correct/s4.total:0, s4.total, s4.correct):-1;
    var domStars=starsFromDom();
    C('result.rStars', domStars===expStars && domStars>=0 && domStars<=3, 'dom='+domStars+' core='+expStars);
    C('result.rBestFilled', txt('rBest')!==null && String(txt('rBest')).replace(/\s/g,'').length>0 && !dirty(txt('rBest')), 'rBest='+txt('rBest'));
    var key=c?c.bestKey(2,'count'):'randommath.best.2.count';
    var stored=null, storeErr='';
    try{ stored=localStorage.getItem(key); }catch(e){ storeErr=String((e&&e.name)||e); }
    var expBest=Math.max(Number(prevBest(2,'count'))||0, s4.score);
    C('result.bestStored', storeErr==='' && stored!==null && Number(stored)===expBest, storeErr||('stored='+stored+' exp='+expBest));
    C('result.bestTextMatches', parseNum(txt('rBest'))===expBest, 'dom='+txt('rBest')+' exp='+expBest);
    C('result.overflow', overflow()<=1, 'overflow='+overflow()+'px');
    I('overflow.result', overflow()+'px');
    I('result.counts', 'correct='+s4.correct+' wrong='+s4.wrong+' score='+s4.score+' stars='+domStars+' best='+txt('rBest'));
    noExternal('result');
    noJsError('result');

    /* 最佳成绩只增不减：再来一局全错，最佳保持 */
    a.start({level:2, mode:'count', count:4, seed:9});
    var g2=0;
    while(state().screen==='play' && g2++<30){
      var stw=state();
      if(!stw.question) break;
      setInput(Number(stw.question.answer)+1); pressSubmit(); a.ff(3);
    }
    var s5=state(), stored2=null;
    try{ stored2=localStorage.getItem(key); }catch(e){}
    C('best.monotonic', s5.screen==='result' && (Number(stored2)===Math.max(expBest, s5.score)), 'stored='+stored2+' exp='+Math.max(expBest, s5.score)+' score='+s5.score);
    C('best.lowScoreZeroStars', starsFromDom()===0 && s5.correct===0, 'stars='+starsFromDom()+' correct='+s5.correct);

    /* 再来一次 / 返回菜单按钮 */
    C('again.startsPlay', (function(){ if(el('againBtn')) el('againBtn').click(); return state().screen==='play'; })(), 'screen='+state().screen);
    C('menuBtn.returnsMenu', (function(){ if(el('menuBtn')) el('menuBtn').click(); return state().screen==='menu'; })(), 'screen='+state().screen);

    /* 主题切换 */
    var t0=themeSig();
    if(el('themeBtn')) el('themeBtn').click();
    var t1=themeSig();
    C('theme.toggles', t0!==t1, 'before/after same');
    if(el('soundBtn')) el('soundBtn').click();
    C('sound.clickSafe', state().screen==='menu', 'screen='+state().screen);

    /* 限时模式：ff 递减并结束 */
    a.start({level:1, mode:'time', seed:11});
    var tA=state();
    C('time.start', tA.screen==='play' && tA.mode==='time', JSON.stringify({s:tA.screen,m:tA.mode}));
    C('time.remainingNumber', typeof tA.remaining==='number' && isFinite(tA.remaining) && tA.remaining>0, 'remaining='+tA.remaining);
    a.ff(3);
    var tB=state();
    C('time.ffDecreases', tB.remaining<=tA.remaining-2 && tB.remaining>=0, 'before='+tA.remaining+' after='+tB.remaining);
    C('time.ffNotEndedEarly', tB.screen==='play', 'screen='+tB.screen);
    a.ff(9999);
    var tC=state();
    C('time.end', tC.screen==='result', 'screen='+tC.screen+' remaining='+tC.remaining);
    C('time.resultVisible', vis('screenResult'));
    C('time.resultNoNaN', !dirty(txt('screenResult')) && !dirty(txt('rScore')+txt('rAcc')+txt('rStars')+txt('rBest')));
    var att2=tC.correct+tC.wrong;
    var expStars2=c?c.starsFor(att2?tC.correct/att2:0, att2, tC.correct):-1;
    C('time.resultStars', starsFromDom()===expStars2, 'dom='+starsFromDom()+' core='+expStars2+' att='+att2);
    C('time.resultScore', parseNum(txt('rScore'))===tC.score, 'dom='+txt('rScore')+' state='+tC.score);
    I('time.counts', 'att='+att2+' score='+tC.score+' stars='+starsFromDom()+' remaining='+tC.remaining);
    noJsError('time');

    /* 页内 selftest API 可调用（不作为结论，只验证接口） */
    var slErr='';
    try{ a.selftest(); }catch(e){ slErr=String((e&&e.message)||e); }
    C('api.selftest.runs', slErr==='', slErr);
  }

  function prevBest(level, mode){
    var c=core();
    var key=c?c.bestKey(level,mode):('randommath.best.'+level+'.'+mode);
    try{ return localStorage.getItem(key); }catch(e){ return null; }
  }

  function finish(){
    C('probe.finished', true, 'tag='+RM_TAG);
    L.push('RMCHECK_END');
    var pre=el('rmcheck');
    if(!pre){
      pre=document.createElement('pre');
      pre.id='rmcheck';
      if(document.body) document.body.appendChild(pre);
    }
    if(pre) pre.textContent=L.join('\n');
  }
  /* URL 自动化是异步的（每题模拟 1.0-2.4 秒作答耗时），所以轮询等到结算页再断言 */
  function waitResult(cb, maxTries){
    var tries=0;
    (function poll(){
      tries++;
      var s=state();
      if(s && s.screen==='result'){ cb('result@'+tries); return; }
      if(tries>=maxTries){ cb('timeout:screen='+(s&&s.screen)); return; }
      setTimeout(poll, 100);
    })();
  }
  function run(){
    try{
      if(/\brmprobe=url\b/.test(location.search)){
        waitResult(function(why){
          try{ urlChecks(why); }catch(e){ C('probe.exception', false, String((e&&e.message)||e)); }
          finish();
        }, 300);
        return;
      }
      flow();
      finish();
    }catch(e){
      C('probe.exception', false, String((e&&e.message)||e));
      finish();
    }
  }
  function boot(){ setTimeout(run, 60); }
  if(document.readyState==='complete') boot(); else window.addEventListener('load', boot);
})();
</script>
'@

# ---------------------------------------------------------------- 环境
Write-Host ''
Write-Host '== random-math 独立验证（无头 Edge）==' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $script:Work)) { New-Item -ItemType Directory -Path $script:Work -Force | Out-Null }
else { Get-ChildItem -LiteralPath $script:Work -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }

$script:Edge = $EdgeExe
if (-not $script:Edge) {
  $script:Edge = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
  ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
$edgeVersion = ''
if ($script:Edge) { $edgeVersion = (Get-Item -LiteralPath $script:Edge).VersionInfo.ProductVersion }
$psEd = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
$psVersion = $PSVersionTable.PSVersion.ToString()
$hasPwsh = [bool](Get-Command pwsh -ErrorAction SilentlyContinue)

Check 'env.edgeFound' ([bool]$script:Edge) '未找到 msedge.exe'
if ($script:Edge) { Check 'env.edgeRunnable' ([bool]$edgeVersion) "版本=$edgeVersion" }

# ---------------------------------------------------------------- A. 静态检查
$pageExists = Test-Path -LiteralPath $script:PagePath
Check 'page.exists' $pageExists $script:PagePath
$src = ''
if ($pageExists) { $src = Read-TextFile $script:PagePath }
$pageSha = Sha256 $script:PagePath
Check 'page.nonEmpty' ($src.Length -gt 2000) ("长度=" + $src.Length)

$coreMatch = [regex]::Match($src, '(?s)/\*\s*__CORE_START__\s*\*/(.*?)/\*\s*__CORE_END__\s*\*/')
$coreSrc = if ($coreMatch.Success) { $coreMatch.Groups[1].Value } else { '' }
$uiMatch = [regex]::Match($src, '(?s)/\*\s*__UI_START__\s*\*/(.*?)/\*\s*__UI_END__\s*\*/')

Check 'html.coreMarkers' ($coreMatch.Success) '缺少 /* __CORE_START__ */ .. /* __CORE_END__ */'
Check 'html.uiMarkers' ($uiMatch.Success) '缺少 /* __UI_START__ */ .. /* __UI_END__ */'
Check 'html.coreSize' ($coreSrc.Length -gt 500) ('核心长度=' + $coreSrc.Length)
Check 'html.corePureNoDom' (-not ($coreSrc -match '\bdocument\s*\.' -or $coreSrc -match '\bwindow\s*\.' -or $coreSrc -match '\blocalStorage\b')) '内核区块里出现 document/window/localStorage'

$httpAttr = [regex]::Matches($src, '(?i)\b(src|href|data-src|xlink:href)\s*=\s*["'']\s*https?://')
Check 'html.noHttpAttrs' ($httpAttr.Count -eq 0) ('命中=' + (($httpAttr | ForEach-Object { $_.Value }) -join ' '))
Check 'html.noCssImport' (-not ($src -match '(?i)@import')) ''
Check 'html.noCssUrlHttp' (-not ($src -match '(?i)url\(\s*[''"]?https?://')) ''
$allUrls = [regex]::Matches($src, '(?i)https?://[^\s"''<>)]+')
$badUrls = @($allUrls | Where-Object { $_.Value -notmatch '(?i)^https?://www\.w3\.org/' })
Check 'html.noExternalUrlLiteral' ($badUrls.Count -eq 0) (($badUrls | ForEach-Object { $_.Value }) -join ' ')
Check 'html.noScriptSrc' (-not ($src -match '(?i)<script[^>]*\ssrc\s*=')) ''
Check 'html.noStylesheetLink' (-not ($src -match '(?i)<link[^>]*rel\s*=\s*["'']?stylesheet')) ''
Check 'html.noImgExternal' (-not ($src -match '(?i)<img[^>]*\ssrc\s*=\s*["''](?!data:)')) ''
Check 'html.charsetMeta' ([bool]([regex]::IsMatch($src, '(?i)<meta[^>]+charset'))) '缺少 <meta charset>'
Check 'html.bodyClose' ([bool]($src -match '(?i)</body>')) ''
Check 'html.windowApiSource' ([bool]($src -match 'randommath')) '源码里没有 window.randommath'
Check 'html.bestKeyPrefix' ([bool]($src -match 'randommath\.best\.')) '源码里没有 randommath.best. 前缀'
Check 'html.localStorageUsed' ([bool]($src -match 'localStorage')) '源码里没有 localStorage（最佳成绩）'
Check 'html.solveParam' ([bool]($src -match 'solve')) '源码里没有 ?solve= 自动化参数'
Check 'html.freezeParam' ([bool]($src -match 'freeze')) '源码里没有 ?freeze= 自动化参数'

$requiredIds = @('screenMenu','screenPlay','screenResult','levelBtns','modeBtns','startBtn','score','combo','progress','acc','timerBar','question','answerInput','keypad','submitBtn','feedback','rScore','rAcc','rStars','rBest','againBtn','menuBtn','themeBtn','soundBtn','selftest')
$missingSrcIds = @()
foreach ($id in $requiredIds) { if ($src -notmatch ('id\s*=\s*["'']' + [regex]::Escape($id) + '["'']')) { $missingSrcIds += $id } }
Check 'html.requiredIdsInSource' ($missingSrcIds.Count -eq 0) ('缺少=' + ($missingSrcIds -join ','))

# ---------------------------------------------------------------- E. 基线 / 集成
Check 'baseline.randomMathAbsent' (-not (Test-Path -LiteralPath (Join-Path $script:Baseline 'random-math.html'))) 'origin/main 基线里竟然已有 random-math.html'
$baseIndex = Join-Path $script:Baseline 'index.html'
if (Test-Path -LiteralPath $baseIndex) {
  $baseSrc = Read-TextFile $baseIndex
  Check 'baseline.indexHasNoCard' (-not ($baseSrc -match 'random-math\.html')) '基线首页已含卡片，改前证据不成立'
} else {
  Check 'baseline.indexHasNoCard' $false '缺少 .verify/main-baseline/index.html'
}

$indexPath = Join-Path $script:Root 'index.html'
if ($SkipIndexCard) {
  Skip 'index.card' 'rm-docs 尚未定稿，-SkipIndexCard'
  Skip 'index.cardFields' 'rm-docs 尚未定稿，-SkipIndexCard'
} elseif (-not (Test-Path -LiteralPath $indexPath)) {
  Check 'index.card' $false 'index.html 不存在'
} else {
  $indexSrc = Read-TextFile $indexPath
  $pStart = $indexSrc.IndexOf('const PAGES')
  $pBlock = ''
  if ($pStart -ge 0) {
    $pEnd = $indexSrc.IndexOf('];', $pStart)
    if ($pEnd -gt $pStart) { $pBlock = $indexSrc.Substring($pStart, $pEnd - $pStart) } else { $pBlock = $indexSrc.Substring($pStart) }
  }
  Check 'index.pagesBlockFound' ($pBlock.Length -gt 0) 'index.html 里找不到 const PAGES = ['
  $cardOk = ($pBlock -match 'random-math\.html')
  Check 'index.card' $cardOk 'PAGES 里没有 random-math.html 卡片'
  $cardLine = ''
  if ($cardOk) {
    $lm = [regex]::Match($pBlock, "(?s)\{[^{}]*random-math\.html[^{}]*\}")
    if ($lm.Success) { $cardLine = $lm.Value }
  }
  Check 'index.cardFields' ($cardLine -match "cat\s*:\s*'learn'" -and $cardLine -match 'emoji' -and $cardLine -match 'name' -and $cardLine -match 'desc') '卡片字段不完整（需要 emoji/name/desc/cat:learn）'
}

# ---------------------------------------------------------------- B. 内核断言页
if ($coreSrc) {
  $corePage = $corePageTemplate.Replace('__RM_CORE_SOURCE__', ($coreSrc -replace '</script', '<\/script'))
  Write-TextFile (Join-Path $script:Work 'core.html') $corePage
  $r = Invoke-EdgeDom -Url ('file:///' + ((Join-Path $script:Work 'core.html') -replace '\\', '/')) -W 1100 -H 900 -Budget $Budget -Tag 'core'
  Check 'core.edgeOutput' $r.ok (Get-EdgeHint 'core')
  if ($r.ok) { Import-ProbeResult 'core' $r.url $r.dump }
} else {
  Check 'core.edgeOutput' $false '没有抽到内核区块，跳过内核断言页'
}

# ---------------------------------------------------------------- C/D. 探针页
if ($pageExists) {
  $html = $src
  if (-not ($html -match '(?i)<meta[^>]+charset')) {
    $h = $html.IndexOf('<head')
    if ($h -ge 0) { $gt = $html.IndexOf('>', $h); if ($gt -ge 0) { $html = $html.Substring(0, $gt + 1) + "`n<meta charset=`"utf-8`">" + $html.Substring($gt + 1) } }
  }
  $h = $html.IndexOf('<head')
  if ($h -ge 0) {
    $gt = $html.IndexOf('>', $h)
    if ($gt -ge 0) { $html = $html.Substring(0, $gt + 1) + "`n" + $headHook + $html.Substring($gt + 1) }
  }

  $autoBudget = [Math]::Max($Budget, 45000)
  $probeRuns = @(
    @{ Tag = 'flow';      Query = '';                                                                                        W = 1280; H = 900; Budget = $Budget },
    @{ Tag = 'narrow504'; Query = '';                                                                                        W = 504;  H = 900; Budget = $Budget },
    @{ Tag = 'urlCount';  Query = '?auto=1&level=3&mode=count&count=4&seed=5&solve=4&sound=off&ff=30&freeze=1&rmprobe=url';    W = 1280; H = 900; Budget = $autoBudget },
    @{ Tag = 'urlMiss';   Query = '?auto=1&level=2&mode=count&count=6&seed=8&miss=2&solve=4&sound=off&ff=30&freeze=1&rmprobe=url'; W = 1280; H = 900; Budget = $autoBudget },
    @{ Tag = 'urlTime';   Query = '?auto=1&level=1&mode=time&ff=9999&freeze=1&sound=off&rmprobe=url';                         W = 1280; H = 900; Budget = $autoBudget },
    @{ Tag = 'urlDark';   Query = '?auto=1&level=2&mode=count&count=4&seed=6&solve=4&sound=off&ff=30&theme=dark&freeze=1&rmprobe=url'; W = 1100; H = 900; Budget = $autoBudget }
  )

  foreach ($run in $probeRuns) {
    $tag = $run.Tag
    $probeFile = Join-Path $script:Work ($tag + '.html')
    $js = $probeJs.Replace('__RM_TAG__', $tag)
    $doc = $html
    $b = $doc.LastIndexOf('</body>')
    $sink = "`n<pre id=`"rmcheck`"></pre>`n"
    if ($b -ge 0) { $doc = $doc.Substring(0, $b) + $sink + $js + "`n" + $doc.Substring($b) }
    else {
      $hb = $doc.LastIndexOf('</html>')
      if ($hb -ge 0) { $doc = $doc.Substring(0, $hb) + $sink + $js + "`n" + $doc.Substring($hb) }
      else { $doc = $doc + $sink + $js }
    }
    Write-TextFile $probeFile $doc
    $u = 'file:///' + ($probeFile -replace '\\', '/') + $run.Query
    $r = Invoke-EdgeDom -Url $u -W $run.W -H $run.H -Budget $run.Budget -Tag $tag
    Check "$tag.edgeOutput" $r.ok (Get-EdgeHint $tag)
    if ($r.ok) { Import-ProbeResult $tag $r.url $r.dump }
  }

  # 页内 selftest：只作为参考证据记进报告，不作为通过条件（通过与否由本脚本的独立断言判定）
  $r = Invoke-EdgeDom -Url ($script:PageUrl + '?selftest=1') -W 1280 -H 1600 -Budget $Budget -Tag 'selftest'
  if ($r.ok) {
    $m = [regex]::Match($r.text, '(?s)<[^>]*id="selftest"[^>]*>(.*?)</')
    if ($m.Success) {
      $script:SelftestInfo = (($m.Groups[1].Value -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
    }
  }

  # 清理本次运行留下的无头 Edge 进程（只动 --user-data-dir 指向本脚本 rm-check 的那些）
  try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.CommandLine -and $_.CommandLine -match 'rm-check\\edge-profile') {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
} else {
  Check 'flow.edgeOutput' $false '页面不存在，跳过全流程探针'
}

# ---------------------------------------------------------------- 报告
$okCount = @($script:Results | Where-Object { $_.Ok }).Count
$bad = @($script:Results | Where-Object { -not $_.Ok })
$total = $script:Results.Count
$skipCount = $script:Skips.Count

$lines = New-Object System.Collections.ArrayList
function RL([string]$s) { [void]$lines.Add($s) }

RL '========================================================'
RL 'random-math.html 独立验证报告（rm-verifier / task-2）'
RL ('时间          : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
RL ('仓库          : ' + $script:Root)
RL ('页面          : ' + $script:PagePath)
RL ('页面 SHA256   : ' + $pageSha)
if ($pageExists) { RL ('页面大小/时间 : ' + (Get-Item -LiteralPath $script:PagePath).Length + ' bytes / ' + (Get-Item -LiteralPath $script:PagePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) }
RL ('Edge          : ' + $script:Edge + '  v' + $edgeVersion)
RL ('PowerShell    : ' + $psVersion + ' (' + $psEd + ')')
if (-not $hasPwsh) { RL '说明          : 本机未安装 pwsh 7；等价运行命令 powershell -NoProfile -File tools\random-math-check.ps1（脚本兼容两者）' }
RL ('Edge 参数      : --headless --disable-gpu --hide-scrollbars --no-first-run --window-size=W,H --virtual-time-budget=' + $Budget + ' --dump-dom "<file:///...>"（URL 必须带引号，否则带空格路径会被拆成多 target）')
RL ('结果          : 通过 ' + $okCount + ' / 共 ' + $total + '，失败 ' + $bad.Count + '，跳过 ' + $skipCount)
if ($script:SelftestInfo) { RL ('页内 selftest : ' + $script:SelftestInfo + '   （仅参考证据，不参与通过判定）') }
RL '========================================================'
RL ''
foreach ($res in $script:Results) {
  $tag = if ($res.Ok) { '[ok]  ' } else { '[FAIL]' }
  $line = $tag + ' ' + $res.Name
  if (-not $res.Ok -and $res.Detail) { $line += '  :: ' + $res.Detail }
  RL $line
}
if ($script:Infos.Count) {
  RL ''
  RL '---- 证据（探针实测值，不计入断言）----'
  foreach ($inf in $script:Infos) { RL ($inf.Name + ' = ' + $inf.Value) }
}
if ($skipCount) {
  RL ''
  RL '---- 跳过 ----'
  foreach ($s in $script:Skips) { RL ('[skip] ' + $s.Name + ' :: ' + $s.Why) }
}
RL ''
RL '---- 无头 Edge 运行 ----'
foreach ($run in $script:Runs) {
  RL ('[' + $run.Tag + '] ' + $run.W + 'x' + $run.H + '  ' + $run.Bytes + ' bytes  exit=' + $run.Exit + '  ' + $run.Url)
  if ($run.Dump) { RL ('        dump: ' + $run.Dump) }
}
if ($script:EdgeErrors.Count) {
  RL ''
  RL '---- Edge 启动诊断（拿不到 DOM 时）----'
  foreach ($ee in $script:EdgeErrors) {
    RL ('[' + $ee.Tag + '] 尝试 ' + $ee.Attempts + ' 次，exit=' + $ee.Exit + '  stderr: ' + $ee.Log)
  }
}
if ($bad.Count) {
  RL ''
  RL '---- 失败项（可复现）----'
  foreach ($res in $bad) {
    RL ('* ' + $res.Name + '  [' + $res.Source + ']')
    if ($res.Detail) { RL ('    detail : ' + $res.Detail) }
    if ($res.Url) {
      RL ('    url    : ' + $res.Url)
      $repro = 'powershell -NoProfile -Command "& ' + "'" + $script:Edge + "'" + ' --headless --disable-gpu --hide-scrollbars --no-first-run --window-size=1280,900 --virtual-time-budget=' + $Budget + ' --dump-dom ' + "'" + $res.Url + "'" + '"'
      RL ('    repro  : ' + $repro)
    }
  }
}
RL ''
if ($bad.Count) { RL ('结论: 未通过（' + $bad.Count + ' 项失败）') } else { RL '结论: 全部通过' }

Write-TextFile $script:ReportPath ($lines -join "`r`n")

Write-Host ''
Write-Host ('通过 ' + $okCount + ' / 共 ' + $total + '，失败 ' + $bad.Count + '，跳过 ' + $skipCount) -ForegroundColor Cyan
Write-Host ('报告: ' + $script:ReportPath)
if ($bad.Count) {
  Write-Host '失败项:' -ForegroundColor Red
  foreach ($res in $bad) { Write-Host ('  - ' + $res.Name + $(if ($res.Detail) { ' :: ' + $res.Detail } else { '' })) -ForegroundColor Red }
  exit 1
}
Write-Host 'random-math 独立验证通过' -ForegroundColor Green
exit 0
