# tools/hunter-bird-word-repeat-shots.ps1
# 用无头 Edge 抓取 hunter-bird-game.html 单词模式「单词重复发音直到被打中」的改前 / 改后对比证据。
#
#   运行： powershell -NoProfile -ExecutionPolicy Bypass -File tools\hunter-bird-word-repeat-shots.ps1
#
#   改前：.verify/hb-baseline/hunter-bird-game.html —— 由 `git show origin/main:hunter-bird-game.html`
#         导出的真实 main 版本（本机没有 Node，画面全部靠页面已有的 URL 参数复现）。
#   改后：本分支 hunter-bird-game.html。
#   成对画面用同一 mode / seed / theme / steps 与同一视口，可直接对比；缺图或断言失败时非零退出。
#
# 关键场景（1 帧 = 1/60 秒，steps=N 就是「开局后第 N 帧、期间一次都不开枪」）：
#   steps=900  → 15 秒没打中。改前状态条写「发音 已播完」（一个词只读一遍就沉默了）；
#               改后写「本词已读 7 遍 · 发音 重复中」，单词卡底部写着「一直读到打中为止」。
#   steps=300  → 5 秒没打中，改后已经读到第 3 遍。
#   auto=1&steps=330 → AI 打中的那一帧，改后显示「发音 已停（打中）」、devstats 里 sayT=0。
param(
  [string]$EdgeExe = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'docs\screenshots'
$baseDir = Join-Path $root '.verify\hb-baseline'
New-Item -ItemType Directory -Path $out -Force | Out-Null
New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

$edge = $EdgeExe
if (-not $edge) {
  $edge = @('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
            'C:/Program Files/Microsoft/Edge/Application/msedge.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $edge) { throw '未找到 Edge，可用 -EdgeExe 指定路径' }

$script:bad = 0
$page = Join-Path $root 'hunter-bird-game.html'
$before = Join-Path $baseDir 'hunter-bird-game.html'

# ---- 改前基线：必须是 origin/main 上真实的那一份 ----
git show 'origin/main:hunter-bird-game.html' | Set-Content -Encoding UTF8 $before
if (-not (Test-Path $before) -or (Get-Item $before).Length -lt 20000) { throw "改前基线导出失败：$before" }
$beforeText = Get-Content -Raw -LiteralPath $before
if ($beforeText.Contains('sayCount')) { throw '改前基线里不该出现 sayCount（说明取错了版本）' }

function FileUrl([string]$path, [string]$query = '') {
  return 'file:///' + ($path -replace '\\', '/') + $query
}

function RunEdge([string]$url, [int]$w, [int]$h, [int]$budget, [string]$mode, [string]$dest) {
  $prof = Join-Path $env:TEMP ('hb-shots-p-' + (Get-Random))
  $prevEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  if ($mode -eq 'shot') {
    & $edge --headless=old --disable-gpu --hide-scrollbars --no-first-run `
      --force-device-scale-factor=1 --user-data-dir="$prof" `
      --window-size="$w,$h" "--screenshot=$dest" "--virtual-time-budget=$budget" $url 2>$null | Out-Null
  } else {
    cmd /c "`"$edge`" --headless=old --disable-gpu --no-first-run --user-data-dir=`"$prof`" --window-size=$w,$h --virtual-time-budget=$budget --dump-dom `"$url`" > `"$dest`" 2>nul" | Out-Null
  }
  $ErrorActionPreference = $prevEA
  Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
}

function Shot([string]$url, [string]$png, [int]$w, [int]$h, [int]$budget = 15000) {
  $dest = Join-Path $out $png
  Remove-Item $dest -Force -ErrorAction SilentlyContinue
  RunEdge $url $w $h $budget 'shot' $dest
  $ok = (Test-Path $dest) -and ((Get-Item $dest).Length -gt 5000)
  $tag = if ($ok) { 'ok    ' } else { 'FAIL  ' }
  $size = if ($ok) { '  (' + [math]::Round((Get-Item $dest).Length / 1024) + ' KB)' } else { '' }
  Write-Host ($tag + $png + $size)
  if (-not $ok) { $script:bad++ }
}

# 渲染后的可见文本（剥掉 <script>/<style>，否则源码里的字面量会污染断言）
function VisibleText([string]$url, [int]$w = 1280, [int]$h = 900, [int]$budget = 15000) {
  $tmp = Join-Path $env:TEMP ('hb-dom-' + (Get-Random) + '.html')
  RunEdge $url $w $h $budget 'dom' $tmp
  $text = ''
  if (Test-Path $tmp) { $text = Get-Content -Raw -LiteralPath $tmp }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  $vis = ($text -as [string]) -replace '(?s)<script.*?</script>', ' ' -replace '(?s)<style.*?</style>', ' '
  # devstats 那段 JSON 在 <pre> 里，去掉标签后仍然保留，所以断言可以直接搜 sayCount
  return ($vis -replace '<[^>]+>', ' ')
}

function Check([bool]$cond, [string]$label) {
  if ($cond) { Write-Host ('ok    ' + $label) } else { Write-Host ('FAIL  ' + $label); $script:bad++ }
}

$idle15 = '?mode=word&seed=5&theme=light&steps=900'
$idle5  = '?mode=word&seed=5&theme=light&steps=300'
$hitNow = '?mode=word&seed=5&theme=light&auto=1&steps=330'
$grade3 = '?mode=word&seed=5&theme=light&grade=3&steps=600'

Write-Host '--- 改前（origin/main 的真实文件）---'
Shot (FileUrl $before $idle15) 'before-hunterbird-word-repeat-idle15s.png' 1280 900
Shot (FileUrl $before $hitNow) 'before-hunterbird-word-repeat-hit.png' 1280 900

Write-Host '--- 改后（本分支）---'
Shot (FileUrl $page $idle15) 'after-hunterbird-word-repeat-idle15s.png' 1280 900
Shot (FileUrl $page $idle5)  'after-hunterbird-word-repeat-idle5s.png' 1280 900
Shot (FileUrl $page $hitNow) 'after-hunterbird-word-repeat-hit.png' 1280 900
Shot (FileUrl $page $grade3) 'after-hunterbird-word-repeat-grade3.png' 1280 900
Shot (FileUrl $page $idle5)  'after-hunterbird-word-repeat-narrow-504x900.png' 504 900
Shot (FileUrl $page '?selftest=1&theme=light') 'after-hunterbird-word-repeat-selftest.png' 1280 2100 30000

Write-Host '--- 可见 DOM 断言 ---'
# devstats 只加在断言用的探针 URL 上（截图不带它，画面保持干净）：
# ?devstats=1 会把本帧状态 JSON 打进 <pre id="devstats">，剥掉标签后仍可搜到 sayCount。
$dev = '&devstats=1'
$beforeDom15 = VisibleText (FileUrl $before ($idle15 + $dev))
$afterDom15  = VisibleText (FileUrl $page  ($idle15 + $dev))
$afterDom5   = VisibleText (FileUrl $page  ($idle5 + $dev))
$hitDom      = VisibleText (FileUrl $page  ($hitNow + $dev))
Check ($beforeDom15.Contains('已播完')) '改前：15 秒没打中时状态条写「发音 已播完」（一个词只读一遍）'
Check (-not $beforeDom15.Contains('已读')) '改前：没有任何「已读 N 遍」重复计数'
Check (-not $beforeDom15.Contains('sayCount')) '改前：devstats 里没有 sayCount 字段'
Check ($afterDom15.Contains('"sayCount":7')) '改后：15 秒没打中时 devstats 里 sayCount=7（读了 7 遍）'
Check ($afterDom15.Contains('本词已读 7 遍')) '改后：状态条写「本词已读 7 遍 · 发音 重复中」'
Check ($afterDom15.Contains('读到打中为止')) '改后：单词卡底部写着「读到打中为止」'
Check ($afterDom15.Contains('一个单词一颗子弹 · 读到打中为止')) '改后：底部提示说明发音规则'
Check ($afterDom5.Contains('"sayCount":3')) '改后：5 秒没打中时已经读到第 3 遍（不是只读一遍）'
Check ($hitDom.Contains('"sayCount":1') -and $hitDom.Contains('"sayT":0')) '改后：AI 打中那一帧 sayCount=1 且 sayT=0（读到第 1 遍就打中，随后停止）'
Check ($hitDom.Contains('已停')) '改后：打中那一帧状态条显示发音已停'

$selfDom = VisibleText (FileUrl $page '?selftest=1&theme=light') 1280 2100 30000
Check ($selfDom.Contains('74/74 passed')) '改后：页内自检 74/74 全部通过'
Check (-not ($selfDom -match 'FAIL ')) '改后：页内自检没有 FAIL 项'
Check ($selfDom.Contains('an unhit word keeps being read over and over')) '改后：自检里含「没打中就一遍遍读」这项'
Check ($selfDom.Contains('the repeating stops the moment the bird is hit')) '改后：自检里含「打中瞬间停止重复」这项'

Write-Host ''
if ($script:bad) { Write-Host "$($script:bad) 项截图/断言未通过"; exit 1 } else { Write-Host '截图与断言全部通过' }
