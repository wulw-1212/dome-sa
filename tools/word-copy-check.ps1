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
  # 给两份文件设成「过去」的创建时间，用来验证按生成日期归档；
  # sub 与 sub2 的 deep.docx 刻意设成同一天，用来验证同一天里的重名改名
  $dayA = (Get-Date).AddDays(-400).Date.AddHours(9)
  $dayB = (Get-Date).AddDays(-90).Date.AddHours(9)
  [IO.File]::SetCreationTime((Join-Path $src 'report.docx'), $dayA)
  [IO.File]::SetCreationTime((Join-Path $src 'sub\deep.docx'), $dayB)
  [IO.File]::SetCreationTime((Join-Path $src 'sub2\deep.docx'), $dayB)
  $script:DayA = $dayA.ToString('yyyy-MM-dd')
  $script:DayB = $dayB.ToString('yyyy-MM-dd')
  $script:DayNow = (Get-Date).ToString('yyyy-MM-dd')
}
New-Fixture

$script:bad = 0
function Edge-Dom([string]$url, [int]$w, [int]$h, [int]$budget) {
  # Edge 会往 stderr 写无关警告；Windows PowerShell 5.1 下 2>$null 会把 stdout 一起吞掉，
  # 所以走 cmd 的 2>nul 重定向，并用临时文件接 stdout。
  # 同时用全新的 user-data-dir：无头 Edge 共用默认配置时，会把别处留下的
  # 「已记住授权目录」带进这次断言，结果就不稳定了。
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $outFile = Join-Path $env:TEMP ("wc-edge-" + [guid]::NewGuid().ToString('N') + ".html")
  $prof = Join-Path $env:TEMP ("wc-edge-prof-" + [guid]::NewGuid().ToString('N'))
  try {
    $a = '"' + $edge + '" --headless --disable-gpu --no-first-run --user-data-dir="' + $prof +
         '" --window-size=' + $w + ',' + $h +
         ' --virtual-time-budget=' + $budget + ' --dump-dom "' + $url + '"'
    cmd /c ("$a 2>nul > `"" + $outFile + "`"") | Out-Null
    # 无头 Edge 的子进程可能还握着这个重定向文件的句柄，读到「being used by another process」时重试几次
    $text = ''
    for ($try = 0; $try -lt 20; $try++) {
      try { if (Test-Path $outFile) { $text = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) }; break }
      catch { Start-Sleep -Milliseconds 250 }
    }
    $text
  } finally {
    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference = $prev
  }
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

# ---------- 1c) 按生成日期归档（dateMode）----------
New-Fixture
$ddst = Join-Path $verify 'wc-dst-dated'
Remove-Item $ddst -Recurse -Force -ErrorAction SilentlyContinue
$d1 = Invoke-CopyApi (Req @{ src = $src; dst = $ddst; dateMode = $true; overwrite = $true })
Check '归档：4 个 Word 文件全部复制' ($d1.summary.copy -eq 4 -and $d1.summary.total -eq 4)
Check '归档：回报 dateMode=true、flat=false' ($d1.dateMode -eq $true -and $d1.flat -eq $false)
Check '归档：按创建时间建了日期文件夹' ((Test-Path (Join-Path $ddst $DayA)) -and (Test-Path (Join-Path $ddst $DayB)))
Check '归档：report.docx 落在创建那天' (Test-Path (Join-Path $ddst "$DayA\${DayA}_report.docx"))
Check '归档：文件名前带上年月日' (@(Get-ChildItem $ddst -Recurse -File | Where-Object { $_.Name -notmatch ('^\d{4}-\d{2}-\d{2}_') }).Count -eq 0)
Check '归档：文件夹名就是年月日' (@(Get-ChildItem $ddst -Directory | Where-Object { $_.Name -notmatch '^\d{4}-\d{2}-\d{2}$' }).Count -eq 0)
Check '归档：同一天不同子目录的同名文件不互相覆盖' ((Test-Path (Join-Path $ddst "$DayB\${DayB}_deep.docx")) -and
  ((Get-ChildItem (Join-Path $ddst $DayB) -File).Count -eq 2))
Check '归档：不照搬源目录结构（只有日期一层）' (@(Get-ChildItem $ddst -Recurse -Directory | Where-Object { $_.Parent.Name -ne (Split-Path $ddst -Leaf) }).Count -eq 0)
Check '归档：job 回报带 folder' (@($d1.jobs | Where-Object { $_.folder -match '^\d{4}-\d{2}-\d{2}$' }).Count -eq 4)
Check '归档：target 指向日期文件夹内' (@($d1.jobs | Where-Object { $_.target -notlike "*$($_.folder)*" }).Count -eq 0)

$d2 = Invoke-CopyApi (Req @{ src = $src; dst = $ddst; dateMode = $true; overwrite = $true })
Check '归档：再跑一次全部跳过（不重复写入）' ($d2.summary.skip -eq 4 -and $d2.summary.copy -eq 0)
$stampBefore = (Get-Item (Join-Path $ddst "$DayA\${DayA}_report.docx")).LastWriteTimeUtc
Start-Sleep -Milliseconds 300
Invoke-CopyApi (Req @{ src = $src; dst = $ddst; dateMode = $true; overwrite = $true }) | Out-Null
Check '归档：跳过时不碰目标文件时间戳' ((Get-Item (Join-Path $ddst "$DayA\${DayA}_report.docx")).LastWriteTimeUtc -eq $stampBefore)

$dprev = Invoke-CopyApi (Req @{ src = $src; dst = (Join-Path $verify 'wc-dst-never'); dateMode = $true; preview = $true })
Check '归档：预览不建日期目录' (-not (Test-Path (Join-Path $verify 'wc-dst-never')) -and $dprev.summary.total -eq 4)

$fflat = Join-Path $verify 'wc-dst-flat2'
Remove-Item $fflat -Recurse -Force -ErrorAction SilentlyContinue
$d3 = Invoke-CopyApi (Req @{ src = $src; dst = $fflat; dateMode = $false; overwrite = $true })
Check '不勾选归档时仍是平铺（无子目录）' (@(Get-ChildItem $fflat -Directory).Count -eq 0 -and @(Get-ChildItem $fflat -File).Count -eq 4)
Check '不勾选归档时文件名不带日期前缀' ((Get-ChildItem $fflat -File 'report.docx' -ErrorAction SilentlyContinue) -ne $null)

# ---------- 1d) 建日期文件夹失败要说人话（都能定位到哪个文件夹、下一步做什么） ----------
New-Fixture
$errDst = Join-Path $verify 'wc-dst-err'
Remove-Item $errDst -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $errDst -Force | Out-Null
# 用一个与日期文件夹同名的「文件」占位：这正是「Failed to create new folder」最常见的成因
Set-Content -LiteralPath (Join-Path $errDst $DayA) -Value 'this is a file' -NoNewline
try {
  Invoke-CopyApi (Req @{ src = $src; dst = $errDst; dateMode = $true; overwrite = $true }) | Out-Null
  Check '同名文件占了日期文件夹位置时明确报错' $false
} catch {
  $m = $_.Exception.Message
  Check '同名文件占了日期文件夹位置时明确报错' ($m -like "*无法创建日期文件夹*$DayA*" -and $m -like '*已经是一个文件*' -and $m -like '*改名*')
}
Remove-Item (Join-Path $errDst $DayA) -Force

# 目标目录不可写（拒绝「创建目录」）：报错要指明目标目录不可写，而不是丢一句英文
$roDst = Join-Path $verify 'wc-dst-ro'
Remove-Item $roDst -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $roDst -Force | Out-Null
$acl = Get-Acl $roDst
$rule = New-Object Security.AccessControl.FileSystemAccessRule('Everyone', 'CreateDirectories', 'Deny')
$applied = $true
try { $acl.AddAccessRule($rule); Set-Acl $roDst $acl } catch { $applied = $false }
if ($applied) {
  try {
    Invoke-CopyApi (Req @{ src = $src; dst = $roDst; dateMode = $true; overwrite = $true }) | Out-Null
    Check '目标目录不可写时说明是目录不可写' $false
  } catch {
    $m = $_.Exception.Message
    Check '目标目录不可写时说明是目录不可写' ($m -like '*无法创建日期文件夹*' -and $m -like '*可写*')
  } finally {
    $acl.RemoveAccessRule($rule) | Out-Null
    Set-Acl $roDst $acl
  }
} else {
  Write-Host 'SKIP  本机不允许改 ACL，跳过「目标目录不可写」一项'
}
Remove-Item $roDst, $errDst -Recurse -Force -ErrorAction SilentlyContinue

# 助手在 /api/status 里自报支持归档：页面据此区分新旧助手，旧助手不该被当成「已归档」
$statusRaw = [IO.File]::ReadAllText((Join-Path $root 'tools\word-copy-server.ps1'), [Text.Encoding]::UTF8)
Check '助手 status 自报支持按日期归档' ($statusRaw -match 'dateMode = \$true')

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
    # 默认就是「按生成日期归档」，所以全链路跑出来的应该是日期文件夹
    $u = "http://127.0.0.1:$Port/?helper=http://127.0.0.1:$Port&src=$([uri]::EscapeDataString($src))&dst=$([uri]::EscapeDataString($dst))&autocopy=1"
    $dom2 = Edge-Dom $u 1280 1200 24000
    Check '浏览器全链路：检测到本地助手' ($dom2 -like '*本地助手在线*')
    Check '浏览器全链路：状态报完成 4 个' ($dom2 -match '完成：复制 4 个')
    Check '浏览器全链路：状态写明按日期归档' ($dom2 -match '已按生成日期放进')
    Check '浏览器全链路：磁盘上确有 4 个文件' (@(Get-ChildItem $dst -Recurse -File -ErrorAction SilentlyContinue).Count -eq 4)
    Check '浏览器全链路：文件落在日期文件夹里' (@(Get-ChildItem $dst -Directory -ErrorAction SilentlyContinue).Count -ge 1 -and
      @(Get-ChildItem $dst -Recurse -File | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_' }).Count -eq 4)
    Check '浏览器全链路：默认源目录写进输入框' ($dom2 -like '*DeepTutor*')

    # 取消归档时仍回到平铺
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    $dom2b = Edge-Dom ($u + '&dateMode=0') 1280 1200 24000
    Check '全链路关掉归档：状态写明平铺' ($dom2b -match '全部平铺在目标目录')
    Check '全链路关掉归档：磁盘平铺 4 个、无子目录' (@(Get-ChildItem $dst -File -ErrorAction SilentlyContinue).Count -eq 4 -and
      @(Get-ChildItem $dst -Directory -ErrorAction SilentlyContinue).Count -eq 0)

    # 免授权主路径：直接双击 word-copy.html（file://），助手在线时用两个默认目录，只要预览
    $fileUrl = "file:///" + ((Join-Path $root 'word-copy.html') -replace '\\', '/')
    $dom3 = Edge-Dom ($fileUrl + '?helper=http://127.0.0.1:' + $Port + '&preview=1&autocopy=1') 1280 1300 26000
    Check '免授权（file:// 双击）：检测到本地助手' ($dom3 -like '*本地助手在线*')
    Check '免授权：用默认目录给出计划，不要求授权' ($dom3 -match '个 Word 文件待按生成日期归档到 E:\\word' -and $dom3 -notmatch '请分别授权')
    Check '免授权：授权按钮已隐藏' ($dom3 -match 'id="pickSrc"[^>]*display: *none')
    # PR #28 起：琥珀色提示框被删掉，说明改走状态条 + 一行紧凑按钮，所以这里核对的是新形态
    Check '免授权：助手在线时收起启动提示行' (([regex]::Match($dom3, '<div class="actions" id="hintRow"([^>]*)>')).Groups[1].Value -match 'hidden')
    Check '免授权：助手在线时状态条不提授权' ($dom3 -notmatch '请分别授权')

    # 助手离线时：状态条给出免授权做法（双击 bat 的路径），并留下重探测入口
    $dom4 = Edge-Dom ($fileUrl + '?helper=http://127.0.0.1:1&preview=1') 1280 1300 20000
    Check '助手离线：状态条给出免授权做法' ($dom4 -like '*未检测到本地助手*不用授权的做法*双击*')
    Check '助手离线：给出 word-copy.bat 的实际路径' ($dom4 -match 'word-copy\.bat')
    Check '助手离线：提供重新探测按钮' ($dom4 -like '*重新探测助手*')

    # 点授权按钮直接打开默认目录：已记住时输入框保留完整默认路径（?demoAuth=1 展示态）
    $dom5 = Edge-Dom ($fileUrl + '?demoAuth=1') 1280 1250 20000
    Check '直达展示态：记忆条已显示' (([regex]::Match($dom5, '<div class="remembered"([^>]*)>')).Groups[1].Value -notmatch 'hidden')
    Check '直达展示态：输入框保留完整默认路径' ($dom5 -match 'value="D:\\Programs Data\\DeepTutor\\data\\user\\workspaces"' -and $dom5 -match 'value="E:\\word"')
    Check '直达展示态：状态条写明已直接打开两个默认目录' ($dom5 -like '*已直接打开两个默认目录*')
    Check '授权按钮提示写明直接打开默认目录' ($dom5 -like '*点一下直接打开默认目录*')
    Check '说明写明不重复写入与直接打开默认目录' ($dom5 -like '*文件没有修改就不重复写入*' -and $dom5 -like '*点授权按钮直接打开默认目录*')
    Check '覆盖选项写明不重复写入' ($dom5 -like '*没改过的仍不重复写入*')

    # 没授权过时点授权按钮：立刻弹选择器（点击必有反应），同时说明默认目录 + 免授权一步做法；
    # file:// 下 IndexedDB 可能永远不回调，界面更新绝不等待存储（页内 85 项断言里有专门的回归防线）
    $dom6 = Edge-Dom ($fileUrl + '?demoNotice=1') 1280 1300 20000
    Check '未授权说明态：给出默认源目录' ($dom6 -like '*D:\\Programs Data\\DeepTutor\\data\\user\\workspaces*')
    Check '未授权说明态：写明系统选择器已打开' ($dom6 -like '*系统选择器已打开*')
    Check '未授权说明态：指向 word-copy.bat 一步免授权' ($dom6 -like '*word-copy.bat*')
    Check '未授权说明态：重选入口已显示' (([regex]::Match($dom6, '<button class="ghost" id="hintManual"([^>]*)>')).Groups[1].Value -notmatch 'hidden')
    Check '存储链路带超时（file:// 卡住也不白点）' ((Get-Content -Raw (Join-Path $root 'word-copy.html')) -match 'IDB_TIMEOUT = 1200')
    Check '选完目录先更新界面再写存储' ((Get-Content -Raw (Join-Path $root 'word-copy.html')) -match '界面先更新：file:// 下 IndexedDB 可能不回调')
  }
}

Write-Host ''
if ($script:bad) { Write-Host "$($script:bad) 项失败"; exit 1 } else { Write-Host 'word-copy 验证通过（含 SKIP 项时见上）' }
