# tools/random-math-shots.ps1
# 用无头 Edge 抓取「随机计算」改前 / 改后对比证据。
# 运行： powershell -ExecutionPolicy Bypass -File tools\random-math-shots.ps1
#
#   改前：.verify/main-baseline/index.html —— origin/main 的真实首页，此时没有随机计算卡片，
#         并断言 .verify/main-baseline/random-math.html 不存在（main 上没有这个页面）。
#   改后：本分支 index.html 导航页（含新卡片）+ random-math.html 的运行画面。
# 同场景、同视口、同主题成对；缺图或断言失败时非零退出。脚本可重复运行（覆盖旧图）。
#
# 本机没有 Node，所以这里用 PowerShell + 无头 Edge；所有画面都靠页面已实现的 URL 参数复现
# （?seed= ?auto=1 ?solve= ?miss= ?ff= ?freeze= ?theme= ?sound=off ?selftest=1），见 .verify/CONTRACT.md。
param(
  [string]$EdgeExe = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'docs\screenshots'
New-Item -ItemType Directory -Path $out -Force | Out-Null

$edge = $EdgeExe
if (-not $edge) {
  $edge = @('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
            'C:/Program Files/Microsoft/Edge/Application/msedge.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $edge) { throw '未找到 Edge，可用 -EdgeExe 指定路径' }
if (-not (Test-Path $edge)) { throw "Edge 路径不存在：$edge" }

$script:bad = 0

function FileUrl([string]$path, [string]$query = '') {
  return 'file:///' + ($path -replace '\\', '/') + $query
}

function Shot([string]$url, [string]$png, [int]$w, [int]$h, [int]$budget = 8000) {
  $dest = Join-Path $out $png
  Remove-Item $dest -Force -ErrorAction SilentlyContinue
  $prevEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & $edge --headless --disable-gpu --hide-scrollbars --no-first-run --force-device-scale-factor=1 `
    --window-size="$w,$h" "--screenshot=$dest" "--virtual-time-budget=$budget" $url 2>$null | Out-Null
  $ErrorActionPreference = $prevEA
  $ok = (Test-Path $dest) -and ((Get-Item $dest).Length -gt 5000)
  $mark = if ($ok) { 'ok    ' } else { 'FAIL  ' }
  $size = if ($ok) { '  (' + [math]::Round((Get-Item $dest).Length / 1024) + ' KB)' } else { '' }
  Write-Host ($mark + $png + $size)
  if (-not $ok) { $script:bad++ }
  return $ok
}

# 取渲染后的 DOM，用来断言导航页里到底有没有这张卡片（不依赖肉眼看截图）。
# 注意：本机 Edge 的 stdout 无法被 PowerShell 管道捕获（读回来是空的），
# 所以这里用 cmd 重定向落到临时文件再读。
function DumpDom([string]$url, [int]$budget = 5000) {
  $tmp = Join-Path $env:TEMP ('rm-dom-' + (Get-Random) + '.html')
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  $prevEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  cmd /c "`"$edge`" --headless --disable-gpu --no-first-run --virtual-time-budget=$budget --dump-dom `"$url`" > `"$tmp`" 2>nul" | Out-Null
  $ErrorActionPreference = $prevEA
  $text = ''
  if (Test-Path $tmp) { $text = (Get-Content -Raw -LiteralPath $tmp) }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return ($text -as [string])
}

function Check([bool]$cond, [string]$label) {
  if ($cond) { Write-Host ('ok    ' + $label) } else { Write-Host ('FAIL  ' + $label); $script:bad++ }
}

# ---- 前置检查：本分支页面已定稿，改前基线里没有它 ----
$page = Join-Path $root 'random-math.html'
$beforeIndex = Join-Path $root '.verify\main-baseline\index.html'
if (-not (Test-Path $page)) { throw "本分支还没有 random-math.html，等页面定稿后再抓图：$page" }
if (-not (Test-Path $beforeIndex)) { throw "缺少改前基线：$beforeIndex" }

Check (-not (Test-Path (Join-Path $root '.verify\main-baseline\random-math.html'))) `
  '确认 random-math.html 在 origin/main 基线里不存在（改前）'

$navUrl = FileUrl (Join-Path $root 'index.html')
$navBaseUrl = FileUrl $beforeIndex

# ---- 改前：origin/main 的真实首页（没有随机计算卡片）----
[void](Shot ($navBaseUrl + '?theme=light') 'before-random-math-main-index.png' 1280 1000)
# 注意：--dump-dom 会把 <script> 源码一起吐出来，而源码里就写着 '❌' 和 '全部通过' 这些字面量，
# 所以断言必须只看「渲染出来的那一块」，不能直接在整个 DOM 文本里搜。
$domBefore = DumpDom ($navBaseUrl + '?theme=light')
Check (-not $domBefore.Contains('href="random-math.html"')) '改前首页渲染结果里没有 random-math.html 卡片链接'

# ---- 改后：本分支导航页（含新卡片），与改前同视口、同主题 ----
[void](Shot ($navUrl + '?theme=light') 'after-random-math-index-nav.png' 1280 1000)
$domAfter = DumpDom ($navUrl + '?theme=light')
Check ($domAfter.Contains('href="random-math.html"')) '改后首页渲染出了 random-math.html 卡片链接'
Check ($domAfter.Contains('随机计算')) '改后首页 DOM 里有「随机计算」卡片文案'

# ---- 改后：random-math.html 运行画面 ----
# 每个场景只用 URL 参数复现，参数与自动化语义见 .verify/CONTRACT.md「自动化参数」一节。
# 关键语义：solve/miss 的最后一题会停在反馈上（不自动推进），ff 再快进、freeze 定格。
$light = '&theme=light&sound=off'
$scenes = @(
  # 菜单：默认浅色（默认玩法就是固定题数），难度 1–4 与两种玩法都在
  @{ q = '?freeze=1' + $light;                                              f = 'after-random-math-menu.png';            w = 1280; h = 1000 },
  # 限时挑战答题中：答对 3 题后快进 12 秒，停在第 4 题（剩余 0:42）
  @{ q = '?auto=1&mode=time&level=1&seed=5&solve=3&ff=12&freeze=1' + $light;       f = 'after-random-math-play-time.png';       w = 1280; h = 900 },
  # 答对反馈
  @{ q = '?auto=1&level=2&seed=6&solve=1&freeze=1' + $light;                       f = 'after-random-math-correct.png';         w = 1280; h = 900 },
  # 答错反馈：第 1 题故意答错
  @{ q = '?auto=1&level=2&seed=7&miss=1&freeze=1' + $light;                        f = 'after-random-math-wrong.png';           w = 1280; h = 900 },
  # 结算：固定 8 题全答对（星级、最佳成绩、新纪录）
  @{ q = '?auto=1&level=3&mode=count&count=8&seed=8&solve=8&ff=4&freeze=1' + $light; f = 'after-random-math-result.png';         w = 1280; h = 1000 },
  # 深色主题：与「限时挑战答题中」同场景、同视口、同 seed，只换主题
  @{ q = '?auto=1&mode=time&level=1&seed=5&solve=3&ff=12&freeze=1&theme=dark&sound=off'; f = 'after-random-math-dark.png';       w = 1280; h = 900 },
  # 窄屏 504×900（本机无头 Edge 会把 CSS 视口下限钳制到约 504px）
  @{ q = '?auto=1&level=1&mode=count&count=10&seed=9&solve=2&freeze=1' + $light;   f = 'after-random-math-narrow-504x900.png';  w = 504;  h = 900 },
  # 页内自检全绿
  @{ q = '?selftest=1' + $light;                                            f = 'after-random-math-selftest.png';        w = 1280; h = 1800 }
)
foreach ($s in $scenes) { [void](Shot (FileUrl $page $s.q) $s.f $s.w $s.h) }

# 自检截图必须真的写着「全部通过」，不是只截了个框。
# --dump-dom 连 <script>/<style> 源码一起吐出来，而源码里就有 '❌' 与 '全部通过' 这两个字面量，
# 所以先剥掉脚本/样式，再只看渲染出来的 #selftest 那一块。
$domSelf = DumpDom (FileUrl $page ('?selftest=1' + $light)) 8000
$visible = $domSelf -replace '(?s)<script.*?</script>', '' -replace '(?s)<style.*?</style>', ''
Check ($visible.Contains('全部通过')) '页内自检渲染结果里有「全部通过」'
Check (-not $visible.Contains('❌')) '页内自检渲染结果里没有 ❌ 失败项'
# 自检跑完会给盒子加 class="show"，所以这里要允许 id 后面还有别的属性
$box = [regex]::Match($visible, '(?s)<div id="selftest"[^>]*>(.*?)</div>')
Check ($box.Success -and $box.Groups[1].Value.Contains('全部通过')) '渲染出的 #selftest 写着「全部通过」'
Check ($box.Success -and $box.Groups[1].Value.Contains('共 46 项')) '渲染出的 #selftest 写着「共 46 项」'
Check ($box.Success -and ([regex]::Matches($box.Groups[1].Value, '✅')).Count -eq 46) '自检 ✅ 项数 = 46'

Write-Host ''
if ($script:bad) { Write-Host "$($script:bad) 项截图/断言未通过"; exit 1 } else { Write-Host '截图全部写出' }
