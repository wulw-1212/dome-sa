# tools/home-link-shots.ps1
# 「每页跳转到主页」改前 / 改后对比证据：同一页面、同一视口、同一主题成对截图。
#   改前：.verify/main-baseline/*.html（origin/main 的真实副本，此时没有任何主页入口）
#   改后：本分支 *.html
# 运行： powershell -ExecutionPolicy Bypass -File tools\home-link-shots.ps1
# 缺图或断言失败时非零退出；脚本可重复运行（覆盖旧图）。
param([string]$EdgeExe = '')
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
  Write-Host ($mark + $png)
  if (-not $ok) { $script:bad++ }
  return $ok
}

function DumpDom([string]$url, [int]$budget = 6000) {
  $tmp = Join-Path $env:TEMP ('hl-dom-' + (Get-Random) + '.html')
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

# 每页的复现场景：只用 URL 参数定格（主题成对，窄屏另给一张）。
$pages = @(
  @{ f='word-copy.html';         q='?theme=light';                    w=1280; h=860 },
  @{ f='random-math.html';       q='?freeze=1&theme=light&sound=off'; w=1280; h=860 },
  @{ f='english-game.html';      q='?theme=light&sound=off';          w=1280; h=860 },
  @{ f='idiom-driving.html';     q='?theme=light';                    w=1280; h=860 },
  @{ f='pingpong-game.html';     q='?theme=light';                    w=1280; h=860 },
  @{ f='tortoise-hare-race.html';q='?theme=light';                    w=1280; h=860 },
  @{ f='earth-moon-story.html';  q='?theme=light';                    w=1280; h=760 },
  @{ f='hunter-bird-game.html';  q='?theme=light';                    w=1280; h=760 }
)
$base = Join-Path $root '.verify\main-baseline'

# ---- 前置检查 ----
foreach ($p in $pages) {
  if (-not (Test-Path (Join-Path $root $p.f))) { throw "本分支还没有 $($p.f)：$root" }
  $bp = Join-Path $base $p.f
  if (-not (Test-Path $bp)) { throw "缺少改前基线：$bp" }
}

foreach ($p in $pages) {
  $name = $p.f -replace '\.html$',''
  # 改前：基线副本，同场景同视口同主题
  [void](Shot (FileUrl (Join-Path $base $p.f) $p.q) "before-home-link-$name.png" $p.w $p.h)
  # 改后：本分支页面
  [void](Shot (FileUrl (Join-Path $root $p.f) $p.q) "after-home-link-$name.png" $p.w $p.h)

  # 渲染层断言：改前没有主页链接，改后必须有一个指向 index.html 的 <a class="home">
  $before = (DumpDom (FileUrl (Join-Path $base $p.f) $p.q)) -replace '(?s)<script.*?</script>','' -replace '(?s)<style.*?</style>',''
  $after  = (DumpDom (FileUrl (Join-Path $root $p.f) $p.q))  -replace '(?s)<script.*?</script>','' -replace '(?s)<style.*?</style>',''
  Check (-not ($before -match 'class="home"[^>]*href="index\.html"|href="index\.html"[^>]*class="home"')) `
    "$($p.f) 改前渲染结果里没有主页入口"
  Check ($after -match '<a[^>]*class="home"[^>]*href="index\.html"|<a[^>]*href="index\.html"[^>]*class="home"') `
    "$($p.f) 改后渲染结果里有 →index.html 的主页入口"
}

# 窄屏（504×900，本机无头 Edge 的 CSS 视口下限）验证不挤爆头部
$ns = @(
  @{ f='random-math.html';  q='?freeze=1&theme=light&sound=off' },
  @{ f='idiom-driving.html';q='?theme=light' }
)
foreach ($p in $ns) {
  $name = $p.f -replace '\.html$',''
  [void](Shot (FileUrl (Join-Path $root $p.f) $p.q) "after-home-link-$name-narrow-504x900.png" 504 900)
}

Write-Host ''
if ($script:bad) { Write-Host "$($script:bad) 项截图/断言未通过"; exit 1 } else { Write-Host '对比证据与断言全部通过' }
