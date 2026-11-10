# tools/word-copy-check.ps1
# Word 复制页的无头验证：助手复制逻辑断言 +（可选）HTTP 接口 + 无头 Edge 页内自检与全链路。
# 运行： powershell -ExecutionPolicy Bypass -File tools\word-copy-check.ps1
#   不带参数：跑「助手复制逻辑」全部断言；若本机 127.0.0.1:8765 有助手在跑，再跑 HTTP 与 Edge 阶段。
#   -HelperPort 8765：指定已在运行的助手端口。
param(
  [int]$HelperPort = 0,
  [string]$EdgeExe = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$verify = Join-Path $root '.verify'
$src = Join-Path $verify 'wc-src'
$dst = Join-Path $verify 'wc-dst'

function New-Fixture {
  Remove-Item $src, $dst -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path (Join-Path $src 'sub') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $src 'sub2') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $src 'report.docx') -Value ('A' * 5000) -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'letter.doc') -Value ('B' * 1200) -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'notes.txt') -Value 'ignore me' -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'pic.png') -Value 'notword' -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'old.rtf') -Value 'rtfnope' -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'manual.odt') -Value 'odtnope' -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'notes.wps') -Value 'wpsnope' -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'sub\deep.docx') -Value ('C' * 900) -NoNewline
  Set-Content -LiteralPath (Join-Path $src 'sub2\deep.docx') -Value ('D' * 700) -NoNewline
  Set-Content -LiteralPath (Join-Path $src ('~$' + 'report.docx')) -Value 'lock' -NoNewline
  Set-Content -LiteralPath (Join-Path $src '.hidden.docx') -Value 'hid' -NoNewline
}
New-Fixture

$script:bad = 0
function Edge-Dom([string]$url, [int]$w, [int]$h, [int]$budget) {
  # Edge 会往 stderr 写无关警告；Windows PowerShell 5.1 下 2>$null 会把 stdout 一起吞掉，
  # 所以走 cmd 的 2>nul 重定向，并用临时文件接 stdout。
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $outFile = Join-Path $env:TEMP ("wc-edge-" + [guid]::NewGuid().ToString('N') + ".html")
  try {
    $a = '"' + $edge + '" --headless --disable-gpu --no-first-run --window-size=' + $w + ',' + $h +
         ' --virtual-time-budget=' + $budget + ' --dump-dom "' + $url + '"'
    cmd /c ("$a 2>nul > `"" + $outFile + "`"") | Out-Null
    if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) } else { '' }
  } finally { Remove-Item $outFile -Force -ErrorAction SilentlyContinue; $ErrorActionPreference = $prev }
}
function Check([string]$name, [bool]$cond) {
  if ($cond) { Write-Host "ok    $name" } else { Write-Host "FAIL  $name"; $script:bad++ }
}

# ---------- 1) 助手复制逻辑（直接调用函数，不起服务） ----------
$ps1 = Get-Content -Raw -LiteralPath (Join-Path $root 'tools\word-copy-server.ps1')
$start = $ps1.IndexOf('$WordExts = @'); $end = $ps1.IndexOf('$listener =')
Invoke-Expression $ps1.Substring($start, $end - $start)
Check '助手 Word 范围只有 .docx/.doc' ($ps1 -match "\`$WordExts\s*=\s*@\('\.docx',\s*'\.doc'\)")
Check '助手取文件用 -Recurse（递归子目录）' (($ps1 -split "`n" | Where-Object { $_ -match 'Get-ChildItem' -and $_ -match '-Recurse' }).Count -ge 1)

function Req($o) { ConvertTo-Json $o }
$r = Invoke-CopyApi (Req @{ src = $src; dst = $dst; overwrite = $true })
Check '递归复制 4 个 Word 文件' ($r.summary.copy -eq 4 -and $r.summary.total -eq 4)
Check 'rtf/odt/wps/txt/png 都不算 Word' (-not ($r.jobs | Where-Object { $_.name -match '\.(rtf|odt|wps|txt|png)$' }))
Check '排除 ~$ 锁文件与隐藏文件' (-not ($r.jobs | Where-Object { $_.name -like '~*' -or $_.name -like '.*' }))
Check '字节合计=7800' ($r.summary.bytes -eq 7800)
Check '目标平铺写入 4 个文件' (@(Get-ChildItem $dst -File).Count -eq 4)
Check '平铺：目标里没有子目录' (@(Get-ChildItem $dst -Directory).Count -eq 0)
Check '同名不同目录 -> 自动改名不覆盖' ((Test-Path (Join-Path $dst 'deep.docx')) -and ((Get-ChildItem $dst -Filter '*deep*.docx').Count -eq 2))
Check '两份 deep.docx 内容各归其主' (((Get-Content -Raw (Join-Path $dst 'deep.docx')).Length -eq 900) -or ((Get-Content -Raw (Join-Path $dst 'deep.docx')).Length -eq 700))
Check 'job.target 全部平铺在目标目录下' (@($r.jobs | Where-Object { (Split-Path -Parent $_.target) -ne $dst }).Count -eq 0)

$r2 = Invoke-CopyApi (Req @{ src = $src; dst = $dst; overwrite = $true })
Check '再跑一次 -> 全部跳过（文件没有修改，不重复写入）' ($r2.summary.skip -eq 4 -and $r2.summary.copy -eq 0)
Check '跳过原因写明不重复写入' (@($r2.jobs | Where-Object { $_.reason -like '*不重复写入*' }).Count -eq 4)
$before = (Get-Item (Join-Path $dst 'report.docx')).LastWriteTimeUtc
Start-Sleep -Milliseconds 300
$r2b = Invoke-CopyApi (Req @{ src = $src; dst = $dst; overwrite = $true })
Check '跳过时不触碰目标文件（时间戳不变）' ((Get-Item (Join-Path $dst 'report.docx')).LastWriteTimeUtc -eq $before -and $r2b.summary.copy -eq 0)

Set-Content -LiteralPath (Join-Path $src 'report.docx') -Value ('A' * 7000) -NoNewline
$r3 = Invoke-CopyApi (Req @{ src = $src; dst = $dst; overwrite = $true })
Check '内容有差 -> 覆盖 1 个' ($r3.summary.overwrite -eq 1 -and $r3.summary.copy -eq 0)
Check '覆盖后大小更新' ((Get-Item (Join-Path $dst 'report.docx')).Length -eq 7000)

$r4 = Invoke-CopyApi (Req @{ src = $src; dst = $dst; overwrite = $false })
Check '不勾选覆盖 -> 同名全部跳过' ($r4.summary.skip -eq 4 -and $r4.summary.copy -eq 0)

$never = Join-Path $verify 'wc-never'
Remove-Item $never -Recurse -Force -ErrorAction SilentlyContinue
$prev = Invoke-CopyApi (Req @{ src = $src; dst = $never; overwrite = $true; preview = $true })
Check '预览：报计划但不落盘、不建目录' ((Test-Path $never) -eq $false -and $prev.summary.total -eq 4)

$auto = Join-Path $verify 'wc-autocreate'
Remove-Item $auto -Recurse -Force -ErrorAction SilentlyContinue
$ac = Invoke-CopyApi (Req @{ src = $src; dst = $auto; overwrite = $true })
Check '目标目录不存在时自动创建' ((Test-Path $auto) -and $ac.summary.copy -eq 4)

try { Invoke-CopyApi (Req @{ src = 'Z:\nope'; dst = $dst }) | Out-Null; Check '源目录不存在报错' $false }
catch { Check '源目录不存在报错' ($_.Exception.Message -like '*源目录不存在*') }
try { Invoke-CopyApi (Req @{ src = $src; dst = $src }) | Out-Null; Check '同源同目标报错' $false }
catch { Check '同源同目标报错' ($_.Exception.Message -like '*同一个*') }
try { Invoke-CopyApi (Req @{ src = ''; dst = $dst }) | Out-Null; Check '缺源目录报错' $false }
catch { Check '缺源目录报错' ($_.Exception.Message -like '*源目录*') }

# ---------- 1b) 免授权启动器 word-copy.bat（静态检查） ----------
$bat = Join-Path $root 'word-copy.bat'
Check 'word-copy.bat 存在' (Test-Path -LiteralPath $bat)
$batBytes = [IO.File]::ReadAllBytes($bat)
Check 'word-copy.bat 纯 ASCII（cmd 默认代码页下不会被截断）' (@($batBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
$batText = [Text.Encoding]::ASCII.GetString($batBytes)
Check 'bat 用 -File 且给 -Port' ($batText -match '-File\s+"tools\\word-copy-server\.ps1"' -and $batText -match '-Port')
Check 'bat 助手已在跑时不重复启动' ($batText -match 'exit 7' -and $batText -match 'word-copy-helper')
Check 'bat 先等助手绑端口再开浏览器' ($batText -match 'Start-Sleep' -and $batText -match 'start ""')

# ---------- 2) HTTP 接口（需要一个已在运行的助手；没有就 SKIP） ----------
function Probe-Helper([int]$p) {
  try { $s = Invoke-RestMethod -Uri "http://127.0.0.1:$p/api/status" -TimeoutSec 3; return ($s.app -eq 'word-copy-helper') } catch { return $false }
}
$Port = $HelperPort
if (-not $Port) { foreach ($p in 8765, 8766, 8791, 8795) { if (Probe-Helper $p) { $Port = $p; break } } }
if (-not $Port) {
  Write-Host 'SKIP  未发现运行中的助手进程（HTTP 与全链路阶段跳过）。'
  Write-Host '      先跑：powershell -ExecutionPolicy Bypass -File tools\word-copy-server.ps1  再跑本脚本'
} else {
  Check "助手已在 127.0.0.1:$Port 响应 /api/status" (Probe-Helper $Port)
  $page = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 8
  Check 'GET / 返回页面本体' ($page.Content -like '*Word 文件复制*' -and $page.Content -like '*文件复制*')
  New-Fixture
  Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
  $json = Req @{ src = $src; dst = $dst; overwrite = $true }
  $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/copy" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20
  Check 'POST /api/copy 平铺复制成功' ($resp.ok -and $resp.summary.copy -eq 4 -and (@(Get-ChildItem $dst -File).Count -eq 4))
  Check 'POST 回报含 rel 相对路径' ($resp.jobs.rel -contains 'sub/deep.docx')
  Check 'POST 回报 flat + recursive 标记' ($resp.flat -eq $true -and $resp.recursive -eq $true)
  $badReq = Req @{ src = 'Q:\missing'; dst = $dst }
  try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/copy" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($badReq)) -TimeoutSec 10 | Out-Null; Check '错误走 HTTP 400 通道' $false }
  catch { Check '错误走 HTTP 400 通道' ($_.Exception.Message -like '*400*') }

  # ---------- 3) 无头 Edge：页内自检 + 浏览器→助手全链路 ----------
  $edge = $EdgeExe
  if (-not $edge) {
    $edge = @('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Microsoft/Edge/Application/msedge.exe') |
      Where-Object { Test-Path $_ } | Select-Object -First 1
  }
  if (-not $edge) {
    Write-Host 'SKIP  未找到 Edge，跳过页内自检与全链路'
  } else {
    $dom = Edge-Dom ("file:///" + ((Join-Path $root 'word-copy.html') -replace '\\', '/') + '?selftest=1') 1280 1700 9000
    if ($dom -match '页内自检：(\d+)/(\d+) 通过') { Check "页内自检 $($Matches[1])/$($Matches[2]) 全绿" ($Matches[1] -eq $Matches[2]) }
    else { Check '页内自检输出可见' $false }
    Check '页内自检无 FAIL 项' (([regex]::Matches($dom, 'class="fail"')).Count -eq 0)

    New-Fixture
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    $u = "http://127.0.0.1:$Port/?helper=http://127.0.0.1:$Port&src=$([uri]::EscapeDataString($src))&dst=$([uri]::EscapeDataString($dst))&autocopy=1"
    $dom2 = Edge-Dom $u 1280 1200 24000
    Check '浏览器全链路：检测到本地助手' ($dom2 -like '*本地助手在线*')
    Check '浏览器全链路：状态报完成 4 个' ($dom2 -match '完成：复制 4 个')
    Check '浏览器全链路：磁盘上确有 4 个平铺文件' (@(Get-ChildItem $dst -File -ErrorAction SilentlyContinue).Count -eq 4)
    Check '浏览器全链路：默认源目录写进输入框' ($dom2 -like '*DeepTutor*')

    # 免授权主路径：直接双击 word-copy.html（file://），助手在线时用两个默认目录，只要预览
    $fileUrl = "file:///" + ((Join-Path $root 'word-copy.html') -replace '\\', '/')
    $dom3 = Edge-Dom ($fileUrl + '?helper=http://127.0.0.1:' + $Port + '&preview=1&autocopy=1') 1280 1300 26000
    Check '免授权（file:// 双击）：检测到本地助手' ($dom3 -like '*本地助手在线*')
    Check '免授权：用默认目录给出计划，不要求授权' ($dom3 -match '个 Word 文件待复制到 E:\\word' -and $dom3 -notmatch '请分别授权')
    Check '免授权：授权按钮已隐藏' ($dom3 -match 'id="pickSrc"[^>]*display: *none')
    Check '免授权：助手在线时不显示启动提示' (([regex]::Match($dom3, '<div class="helper-hint" id="helperHint"([^>]*)>')).Groups[1].Value -match 'hidden')

    # 助手离线时：页面给出免授权的启动办法（双击 bat / 一条命令 / 重新探测）
    $dom4 = Edge-Dom ($fileUrl + '?helper=http://127.0.0.1:1&preview=1') 1280 1300 20000
    Check '助手离线：显示免授权启动提示' ($dom4 -like '*不需要授权任何文件夹*')
    Check '助手离线：提示里给出 word-copy.bat 路径' ($dom4 -match 'word-copy\.bat')
    Check '助手离线：提供重新探测按钮' ($dom4 -like '*重新探测助手*')

    # 点授权按钮自动跳回上次目录（页内假句柄异步断言已在 selftest 里，这里核对展示态与说明文案）
    $dom5 = Edge-Dom ($fileUrl + '?demoAuth=1') 1280 1250 20000
    Check '跳回展示态：记忆条已显示' (([regex]::Match($dom5, '<div class="remembered"([^>]*)>')).Groups[1].Value -notmatch 'hidden')
    Check '跳回展示态：记忆条显示两个目录名' ($dom5 -match 'id="memSrc">源：workspaces' -and $dom5 -match 'id="memDst">目标：word')
    Check '跳回展示态：状态条提示不用再选文件夹' ($dom5 -like '*已自动跳回上次授权的源目录与目标目录*')
    Check '授权按钮提示写明自动跳回' ($dom5 -like '*记住后下次自动跳回*')
    Check '说明写明不重复写入与自动跳回' ($dom5 -like '*文件没有修改就不重复写入*' -and $dom5 -like '*会自动跳到对应目录*')
    Check '覆盖选项写明不重复写入' ($dom5 -like '*没改过的仍不重复写入*')
  }
}

Write-Host ''
if ($script:bad) { Write-Host "$($script:bad) 项失败"; exit 1 } else { Write-Host 'word-copy 验证通过（含 SKIP 项时见上）' }
