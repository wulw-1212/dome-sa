# tools/word-copy-server.ps1
# Word 文件复制页的本地助手：只监听 127.0.0.1 的极简 HTTP 服务。
# 它只做三件事：提供 word-copy.html 页面、报告状态、递归找出源目录及所有子目录里的
# Word 文档（.docx/.doc），并把文件**平铺**复制到目标目录（不复制目录结构）。
# 不删除任何文件，不提供任意文件读写接口。
# 用法：  powershell -ExecutionPolicy Bypass -File tools\word-copy-server.ps1 [-Port 8765]
# 然后浏览器打开  http://127.0.0.1:8765/ （Ctrl+C 或关窗口即停止）
param(
  [int]$Port = 8765
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$page = Join-Path $root 'word-copy.html'

# 只复制 Word 文档
$WordExts = @('.docx', '.doc')

function Send-Response($stream, [int]$code, [string]$status, [string]$contentType, [byte[]]$body) {
  $headers = @(
    "HTTP/1.1 $code $status",
    "Content-Type: $contentType",
    'Access-Control-Allow-Origin: *',
    'Access-Control-Allow-Methods: GET, POST, OPTIONS',
    'Access-Control-Allow-Headers: Content-Type',
    'Cache-Control: no-store',
    'Connection: close'
  )
  if ($code -ne 204) { $headers += "Content-Length: $($body.Length)" }
  $head = [Text.Encoding]::UTF8.GetBytes(($headers -join "`r`n") + "`r`n`r`n")
  $stream.Write($head, 0, $head.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}
function UTF8-Bytes([string]$s) { [Text.Encoding]::UTF8.GetBytes($s) }
function Json($obj) { ($obj | ConvertTo-Json -Depth 8 -Compress) }
function UnixSeconds([DateTime]$t) { [datetimeoffset]::new($t.ToUniversalTime()).ToUnixTimeSeconds() }

function Get-FlatNames($files) {
  # 与页面内核 flatNames 同规则：先出现的保留原名；
  # 不同子目录里的同名 Word 文件用上级目录名做前缀改名，保证互不覆盖。
  $used = @{}
  $out = @()
  foreach ($f in $files) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $ext = [IO.Path]::GetExtension($f.Name)
    $name = $f.Name
    $key = $name.ToLower()
    if (-not $used.ContainsKey($key)) {
      $used[$key] = $true
    } else {
      $parent = Split-Path -Leaf (Split-Path -Parent $f.FullName)
      $name = if ($parent) { "${parent}_${stem}${ext}" } else { "${stem}${ext}" }
      $i = 2
      while ($used.ContainsKey($name.ToLower())) { $name = if ($parent) { "${parent}_${stem}_${i}${ext}" } else { "${stem}_${i}${ext}" }; $i++ }
      $used[$name.ToLower()] = $true
    }
    $out += [pscustomobject]@{ file = $f; name = $name }
  }
  return ,$out
}

function Invoke-CopyApi([string]$jsonBody) {
  $req = $jsonBody | ConvertFrom-Json
  $src = [string]$req.src
  $dst = [string]$req.dst
  $overwrite = -not ($null -ne $req.overwrite -and ($req.overwrite -eq $false))
  $preview = [bool]$req.preview

  if (-not $src) { throw '请填写源目录。' }
  if (-not $dst) { throw '请填写目标目录。' }
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "源目录不存在：$src" }
  if ($src.TrimEnd('\', '/') -eq $dst.TrimEnd('\', '/')) { throw '源目录和目标目录是同一个，无需复制。' }

  # 递归找源目录及所有子目录里的 Word 文件；排序保证与页面内核给出同样的改名结果
  $all = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $WordExts -contains $_.Extension.ToLower() -and $_.Name -notlike '~`$*' -and $_.Name -notlike '.*' } |
    Sort-Object { ($_.FullName.Split('\').Count) }, { $_.FullName })

  $srcFull = (Get-Item -LiteralPath $src).FullName.TrimEnd('\')
  $jobs = @()
  $sum = [ordered]@{ total = 0; copy = 0; overwrite = 0; skip = 0; fail = 0; bytes = 0 }
  foreach ($item in (Get-FlatNames $all)) {
    $f = $item.file
    $rel = $f.FullName.Substring($srcFull.Length).TrimStart('\') -replace '\\', '/'
    $target = Join-Path $dst $item.name          # 平铺：目标目录 + 文件名，绝不拼子目录
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    $action = 'copy'; $reason = ''
    if ($exists) {
      $ti = Get-Item -LiteralPath $target
      if (-not $overwrite) { $action = 'skip-exist'; $reason = '目标已存在同名文件（未勾选覆盖）' }
      elseif ($ti.Length -eq $f.Length -and (UnixSeconds $ti.LastWriteTimeUtc) -eq (UnixSeconds $f.LastWriteTimeUtc)) {
        $action = 'skip-same'; $reason = '文件没有修改（大小与修改时间都相同），不重复写入'
      } else { $action = 'overwrite' }
    }
    if (-not $preview -and ($action -eq 'copy' -or $action -eq 'overwrite')) {
      try {
        if (-not (Test-Path -LiteralPath $dst -PathType Container)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
      } catch { $action = 'fail'; $reason = $_.Exception.Message }
    }
    $size = [int64]$f.Length
    if ($action -eq 'copy') { $sum.copy++; $sum.bytes += $size }
    elseif ($action -eq 'overwrite') { $sum.overwrite++; $sum.bytes += $size }
    elseif ($action -eq 'fail') { $sum.fail++ }
    else { $sum.skip++ }
    $sum.total++
    $jobs += [ordered]@{ rel = $rel; name = $item.name; size = $size; target = $target; action = $action; reason = $reason }
  }
  [ordered]@{ ok = $true; preview = $preview; flat = $true; recursive = $true; jobs = $jobs; summary = $sum }
}

function Read-Exact($stream, [int]$count) {
  $out = New-Object byte[] $count
  $got = 0
  while ($got -lt $count) {
    $n = $stream.Read($out, $got, $count - $got)
    if ($n -le 0) { break }
    $got += $n
  }
  if ($got -lt $count) { $out = $out[0..($got - 1)] }
  return ,$out
}
function Read-Line($stream, [byte[]]$one, $sb) {
  [void]$sb.Clear()
  while ($true) {
    $n = $stream.Read($one, 0, 1)
    if ($n -le 0) { if ($sb.Length -gt 0) { return $sb.ToString() } return $null }
    if ($one[0] -eq 10) { return $sb.ToString().TrimEnd([char]13) }
    [void]$sb.Append([char]$one[0])
  }
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "Word 复制助手已启动： http://127.0.0.1:$Port/  （Ctrl+C 停止；只监听本机，只复制 Word 文件）"
try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $one = New-Object byte[] 1
      $sb = New-Object Text.StringBuilder
      $contentLength = 0
      $reqLine = $null
      while ($null -ne ($l = Read-Line $stream $one $sb)) {
        if ($l -eq '') { break }
        if ($null -eq $reqLine) { $reqLine = $l }
        elseif ($l -match '(?i)^content-length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
      }
      if ($null -eq $reqLine) { $client.Close(); continue }
      $body = ''
      if ($contentLength -gt 0) { $body = [Text.Encoding]::UTF8.GetString((Read-Exact $stream $contentLength)) }
      $parts = $reqLine -split ' '
      $method = $parts[0]
      $path = (($parts[1]) -split '\?')[0]

      if ($method -eq 'OPTIONS') {
        Send-Response $stream 204 'No Content' 'text/plain' (UTF8-Bytes '')
      }
      elseif ($path -eq '/api/status') {
        Send-Response $stream 200 'OK' 'application/json; charset=utf-8' (UTF8-Bytes (Json ([ordered]@{ app = 'word-copy-helper'; root = $root; exts = $WordExts; flat = $true })))
      }
      elseif ($path -eq '/api/copy' -and $method -eq 'POST') {
        try {
          $res = Invoke-CopyApi $body
          Send-Response $stream 200 'OK' 'application/json; charset=utf-8' (UTF8-Bytes (Json $res))
        } catch {
          Send-Response $stream 400 'Bad Request' 'application/json; charset=utf-8' (UTF8-Bytes (Json ([ordered]@{ ok = $false; error = $_.Exception.Message })))
        }
      }
      elseif (($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/word-copy.html') -and $method -eq 'GET' -and (Test-Path -LiteralPath $page)) {
        Send-Response $stream 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($page))
      }
      else {
        Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' (UTF8-Bytes 'not found')
      }
    } catch { Write-Host "请求处理失败: $($_.Exception.Message)" }
    finally { try { $client.Close() } catch {} }
  }
} finally { $listener.Stop() }
