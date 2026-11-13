# tools/word-copy-shots.ps1
# 用无头 Edge 抓取 word-copy.html 的改前 / 改后对比证据。
# 运行： powershell -ExecutionPolicy Bypass -File tools\word-copy-shots.ps1 [-HelperPort 8765]
# 改前基线 = origin/main 的实际内容（main 上没有这个页面，抓的是当时的 index.html）。
param(
  [int]$HelperPort = 0,
  [string]$EdgeExe = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'docs\screenshots'
$shots = Join-Path $root '.verify\shots'
New-Item -ItemType Directory -Path $out, $shots -Force | Out-Null

$edge = $EdgeExe
if (-not $edge) {
  $edge = @('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Microsoft/Edge/Application/msedge.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $edge) { throw '未找到 Edge，可用 -EdgeExe 指定路径' }

function Shot([string]$url, [string]$png, [int]$w, [int]$h, [int]$budget = 9000) {
  $dest = Join-Path $out $png
  $prevEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  # 每次都用全新的 user-data-dir：否则无头 Edge 会共用默认配置，
  # 把上一次跑测试时留下的「已记住授权目录」带进截图，画面和说明对不上
  $prof = Join-Path $env:TEMP ("wc-shot-" + [guid]::NewGuid().ToString('N'))
  & $edge --headless --disable-gpu --hide-scrollbars --no-first-run "--user-data-dir=$prof" `
    --window-size="$w,$h" "--screenshot=$dest" "--virtual-time-budget=$budget" $url 2>$null | Out-Null
  Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
  $ok = (Test-Path $dest) -and ((Get-Item $dest).Length -gt 5000)
  $mark = if ($ok) { 'ok    ' } else { 'FAIL  ' }
  $size = if ($ok) { '  (' + [math]::Round((Get-Item $dest).Length / 1024) + ' KB)' } else { '' }
  Write-Host ($mark + $png + $size)
  return $ok
}

# ---- 改前基线：origin/main 的实际内容 ----
# main 上现在已有 word-copy.html（PR #20/#23 已合并），所以改前基线取 main 那份页面；
# 没有 word-copy.html 时（早期基线）退回抓 main 的 index.html。
$base = Join-Path $shots 'main-baseline'
$prevEA0 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
git -C $root rev-parse --git-dir 2>$null | Out-Null
$gitOk = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEA0
if ($gitOk) {
  Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  $prevEA = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  git -C $root fetch origin 2>$null | Out-Null
  $baseHtml = (git -C $root show origin/main:word-copy.html 2>$null) -join "`n"
  $onMain = ($LASTEXITCODE -eq 0) -and $baseHtml
  $baseFile = 'word-copy.html'
  if (-not $onMain) {
    $baseHtml = (git -C $root show origin/main:index.html 2>$null) -join "`n"
    $baseFile = 'index.html'
    Write-Host 'word-copy.html 在 origin/main 上不存在，改前基线取 main 的 index.html'
  } else {
    Write-Host '改前基线 = origin/main:word-copy.html'
  }
  $ErrorActionPreference = $prevEA
  [IO.File]::WriteAllText((Join-Path $base $baseFile), $baseHtml, (New-Object Text.UTF8Encoding($false)))
  Set-Content -LiteralPath (Join-Path $base 'which.txt') -Value $baseFile -Encoding ascii
} elseif (Test-Path (Join-Path $out 'word-copy-before-main-index.png')) {
  Write-Host 'SKIP  本机 git 仓库不可用，沿用已有的改前基线截图（word-copy-before-main-index.png）'
} else {
  throw '本机 git 仓库不可用，且没有已提交的改前基线截图，无法给出对比证据。'
}

# ---- 改后：本页运行画面（用临时输出目录，不动真实 E:\word）----
$tmpSrc = Join-Path $shots 'src'
$tmpDst = Join-Path $shots 'dst'
Remove-Item $tmpSrc, $tmpDst -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$tmpSrc\2024年报", "$tmpSrc\合同归档" -Force | Out-Null
Set-Content -LiteralPath "$tmpSrc\项目建议书.docx" -Value ('A' * 4200) -NoNewline
Set-Content -LiteralPath "$tmpSrc\会议纪要.doc" -Value ('B' * 1500) -NoNewline
Set-Content -LiteralPath "$tmpSrc\2024年报\deep.docx" -Value ('C' * 2600) -NoNewline
Set-Content -LiteralPath "$tmpSrc\合同归档\deep.docx" -Value ('D' * 1800) -NoNewline
Set-Content -LiteralPath "$tmpSrc\说明.txt" -Value 'not a word file' -NoNewline
# 按生成日期归档需要「创建时间」：给几份文件设成不同的过去日期，
# 其中两份刻意同一天（2024年报 / 合同归档 里的 deep.docx），用来展示同天重名改名
$dayX = (Get-Date).AddDays(-500).Date.AddHours(10)
$dayY = (Get-Date).AddDays(-120).Date.AddHours(10)
[IO.File]::SetCreationTime("$tmpSrc\项目建议书.docx", $dayX)
[IO.File]::SetCreationTime("$tmpSrc\2024年报\deep.docx", $dayY)
[IO.File]::SetCreationTime("$tmpSrc\合同归档\deep.docx", $dayY)

$fileUrl = 'file:///' + ((Join-Path $root 'word-copy.html') -replace '\\', '/')
$bad = 0
$baseName = 'index.html'
if (Test-Path (Join-Path $base 'which.txt')) { $baseName = (Get-Content -Raw (Join-Path $base 'which.txt')).Trim() }
$baseHtmlPath = Join-Path $base $baseName
if ((Test-Path $baseHtmlPath) -and ((Get-Item $baseHtmlPath).Length -gt 200)) {
  if (-not (Shot ("file:///" + ($baseHtmlPath -replace '\\', '/')) 'word-copy-before-main-index.png' 1280 900)) { $bad++ }
  # 改前：点授权按钮「跳回上次目录」的画面（main 上的页面，同一 ?demoAuth=1 演示态、同一视口）
  if ($baseName -eq 'word-copy.html') {
    if (-not (Shot ("file:///" + ($baseHtmlPath -replace '\\', '/') + '?demoAuth=1') 'word-copy-before-default-open.png' 1280 1250)) { $bad++ }
  }
} else {
  Write-Host 'SKIP  本机拿不到 origin/main 的基线页面（git 不可用），保留已提交的 word-copy-before-main-index.png，不重抓'
}

# ---- 改后：默认目录、配色、页内自检（file:// 直开，无需助手）----
if (-not (Shot $fileUrl 'word-copy-after-defaults.png' 1280 1000)) { $bad++ }
if (-not (Shot "$fileUrl`?theme=dark" 'word-copy-after-dark.png' 1280 1000)) { $bad++ }
if (-not (Shot "$fileUrl`?selftest=1" 'word-copy-after-selftest.png' 1280 1780)) { $bad++ }
if (-not (Shot "$fileUrl`?selftest=1" 'word-copy-after-narrow-504x900.png' 504 900)) { $bad++ }
# 点授权按钮直接打开默认目录：?demoAuth=1 展示已记住时输入框保留完整默认路径的状态，不产生任何写入
if (-not (Shot "$fileUrl`?demoAuth=1" 'word-copy-after-remember-jump.png' 1280 1250)) { $bad++ }
# 从没授权过时点授权按钮的说明态：?demoNotice=1 展示默认目录 + 免授权一步做法 + 手动选择入口，不弹选择框
if (-not (Shot "$fileUrl`?demoNotice=1" 'word-copy-after-default-notice.png' 1280 1300)) { $bad++ }

# ---- 改后：助手在线时的预览与真复制画面（用临时目录，不动真实的 E:\word）----
$helperOnline = $false
if ($HelperPort) { try { $s = Invoke-RestMethod "http://127.0.0.1:$HelperPort/api/status" -TimeoutSec 3; $helperOnline = ($s.app -eq 'word-copy-helper') } catch {} }
else { foreach ($p in 8765, 8766, 8795) { try { $s = Invoke-RestMethod "http://127.0.0.1:$p/api/status" -TimeoutSec 2; if ($s.app -eq 'word-copy-helper') { $HelperPort = $p; $helperOnline = $true; break } } catch {} } }
if ($helperOnline) {
  Write-Host "助手在线：127.0.0.1:$HelperPort（演示源 -> 目标：$tmpSrc -> $tmpDst）"
  $h = "http://127.0.0.1:$HelperPort"

  # 改前（main 上还没有「按生成日期归档」时的同一场景）：用 .verify\main-word-copy.html 跑同样的夹具
  $beforePage = Join-Path $root '.verify\main-word-copy.html'
  if (-not (Test-Path $beforePage) -and $gitOk) {
    $prevEAg = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $mw = (git -C $root show origin/main:word-copy.html 2>$null) -join "`n"
    $ErrorActionPreference = $prevEAg
    if ($mw.Length -gt 1000) { [IO.File]::WriteAllText($beforePage, $mw, (New-Object Text.UTF8Encoding($false))) }
  }
  if (Test-Path $beforePage) {
    $qb = 'file:///' + ($beforePage -replace '\\', '/') + '?helper=http://127.0.0.1:' + $HelperPort +
          '&src=' + [uri]::EscapeDataString($tmpSrc) + '&dst=' + [uri]::EscapeDataString((Join-Path $shots 'dst-before')) + '&autocopy=1'
    Remove-Item (Join-Path $shots 'dst-before') -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Shot $qb 'word-copy-before-date-mode.png' 1280 1200 24000)) { $bad++ }
    Write-Host ('改前目标目录内容：' + ((Get-ChildItem (Join-Path $shots 'dst-before') -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring((Join-Path $shots 'dst-before').Length + 1) }) -join ', '))
  } else {
    Write-Host 'SKIP  没有 .verify\main-word-copy.html（改前页面），跳过改前运行画面'
  }

  $q1 = $h + '?helper=' + [uri]::EscapeDataString($h) + '&src=' + [uri]::EscapeDataString($tmpSrc) + '&dst=' + [uri]::EscapeDataString($tmpDst) + '&preview=1&autocopy=1'
  if (-not (Shot $q1 'word-copy-after-preview.png' 1280 1150 24000)) { $bad++ }
  Remove-Item $tmpDst -Recurse -Force -ErrorAction SilentlyContinue
  $q2 = $h + '?helper=' + [uri]::EscapeDataString($h) + '&src=' + [uri]::EscapeDataString($tmpSrc) + '&dst=' + [uri]::EscapeDataString($tmpDst) + '&autocopy=1'
  if (-not (Shot $q2 'word-copy-after-done.png' 1280 1200 24000)) { $bad++ }
  Write-Host ('归档后目标目录内容：' + ((Get-ChildItem $tmpDst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($tmpDst.Length + 1) }) -join ', '))
  # 目标已有文件时取消「同名则覆盖」：应当全部跳过、不重复写入
  if (-not (Shot ($q2 + '&overwrite=0') 'word-copy-after-no-overwrite.png' 1280 1150 24000)) { $bad++ }
  # 取消归档 -> 平铺（对比用）
  Remove-Item $tmpDst -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Shot ($q2 + '&dateMode=0') 'word-copy-after-flat.png' 1280 1150 24000)) { $bad++ }

  # 建日期文件夹失败时的提示画面：目标目录里放一个与日期同名的文件占位，
  # 让助手真的建不出文件夹，核对页面给出的是中文、能定位到哪个文件夹、并说明下一步
  $evSrc = Join-Path $shots 'err-src'; $evDst = Join-Path $shots 'err-dst'
  Remove-Item $evSrc, $evDst -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $evSrc, $evDst -Force | Out-Null
  Set-Content -LiteralPath "$evSrc\报告.docx" -Value ('A' * 200) -NoNewline
  $evKey = ([IO.File]::GetCreationTime("$evSrc\报告.docx")).ToString('yyyy-MM-dd')
  Set-Content -LiteralPath "$evDst\$evKey" -Value 'blocker file' -NoNewline
  $qe = $h + '?helper=' + [uri]::EscapeDataString($h) + '&src=' + [uri]::EscapeDataString($evSrc) +
        '&dst=' + [uri]::EscapeDataString($evDst) + '&autocopy=1'
  if (-not (Shot $qe 'word-copy-after-folder-error.png' 1280 1250 24000)) { $bad++ }
  Remove-Item $evSrc, $evDst -Recurse -Force -ErrorAction SilentlyContinue

  # 免授权主路径：直接 file:// 双击页面，助手在线，两个默认目录已填好、无需授权。
  # 注意：仓库是公开的，所以这张不跑真实源目录的结果表，只证明「助手在线 + 默认路径 + 不要求授权」。
  $fileUrl2 = 'file:///' + ((Join-Path $root 'word-copy.html') -replace '\\', '/')
  $qn = $fileUrl2 + '?helper=http://127.0.0.1:' + $HelperPort
  if (-not (Shot $qn 'word-copy-after-no-auth-defaults.png' 1280 1250 20000)) { $bad++ }

  # 助手离线时的免授权提示（双击 bat / 一条命令 / 重新探测）
  $qo = $fileUrl2 + '?helper=http://127.0.0.1:1&preview=1'
  if (-not (Shot $qo 'word-copy-after-helper-offline-hint.png' 1280 1250 20000)) { $bad++ }

  # 页面默认目录（用户指定的两个路径）+ 生成的复制命令。
  # 注意：仓库是公开的，所以不抓取真实源目录的文件清单，只展示两个默认路径本身。
  $qc = $h + '?helper=' + [uri]::EscapeDataString($h) + '&cmd=1'
  if (-not (Shot $qc 'word-copy-after-defaults-command.png' 1280 1150 24000)) { $bad++ }
} else {
  Write-Host 'SKIP  未发现在线助手，跳过预览/真复制画面。先跑：'
  Write-Host '        powershell -ExecutionPolicy Bypass -File tools\word-copy-server.ps1   再重跑本脚本'
}

Write-Host ''
if ($bad) { Write-Host "$bad 张截图缺失"; exit 1 } else { Write-Host '截图全部写出' }
