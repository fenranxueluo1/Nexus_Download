param(
  [string]$FfmpegPath = '',
  [string]$YtDlpPath = '',
  [string]$DenoPath = '',
  [switch]$SkipBuild,
  [string]$OutputDirectory = '',
  [string]$CertificateThumbprint = '',
  [string]$PfxPath = '',
  [string]$PfxPassword = '',
  [string]$TimestampUrl = 'http://timestamp.digicert.com',
  [string]$SignToolPath = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-SignTool([string]$configured) {
  if ($configured) {
    if (-not (Test-Path -LiteralPath $configured)) {
      throw "找不到 signtool：$configured"
    }
    return (Resolve-Path -LiteralPath $configured).Path
  }
  $command = Get-Command 'signtool.exe' -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -match '\\x64\\signtool\.exe$' } |
    Select-Object -First 1
  if ($command) {
    return $command.Source
  }
  $command = Get-Command 'signtool.exe' -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }
  $kitRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
  if (Test-Path -LiteralPath $kitRoot) {
    $candidate = Get-ChildItem -LiteralPath $kitRoot -Directory |
      Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
      Where-Object { Test-Path -LiteralPath $_ } |
      Select-Object -First 1
    if ($candidate) {
      return $candidate
    }
  }
  throw '找不到 signtool.exe，请安装 Windows SDK 或用 -SignToolPath 指定。'
}

$root = Split-Path -Parent $PSScriptRoot
$release = Join-Path $root 'build\windows\x64\runner\Release'
$dist = if ($OutputDirectory) {
  [IO.Path]::GetFullPath($OutputDirectory)
} else {
  Join-Path $root 'dist'
}
$cache = Join-Path $dist '_cache'
$stage = Join-Path $dist 'Nexus-Windows-x64'
$zip = Join-Path $dist 'NexusDownload-Windows-x64.zip'

function Get-ToolPath([string]$configured, [string]$defaultPath, [string]$label) {
  if ($configured) {
    if (-not (Test-Path -LiteralPath $configured)) {
      throw "$label 不存在：$configured"
    }
    return (Resolve-Path -LiteralPath $configured).Path
  }
  if ($defaultPath -and (Test-Path -LiteralPath $defaultPath)) {
    return (Resolve-Path -LiteralPath $defaultPath).Path
  }
  return ''
}

if (-not $SkipBuild) {
  Push-Location $root
  try {
    Write-Host '构建 Windows Release...'
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
      throw "flutter build windows 失败，退出码 $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $release 'nexus_download.exe'))) {
  throw "找不到 Release 产物：$release"
}

New-Item -ItemType Directory -Force -Path $cache | Out-Null

$appTools = Join-Path $env:APPDATA 'com.example\nexus_download\tools'
$ytDlp = Get-ToolPath $YtDlpPath (Join-Path $appTools 'yt-dlp.exe') 'yt-dlp'
if (-not $ytDlp) {
  $ytDlp = Join-Path $cache 'yt-dlp.exe'
  if (-not (Test-Path -LiteralPath $ytDlp)) {
    Write-Host '下载 yt-dlp...'
    Invoke-WebRequest -Uri 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -OutFile $ytDlp
  }
}

$deno = Get-ToolPath $DenoPath (Join-Path $appTools 'deno.exe') 'Deno'
if (-not $deno) {
  $deno = Join-Path $cache 'deno.exe'
  if (-not (Test-Path -LiteralPath $deno)) {
    $denoZip = Join-Path $cache 'deno.zip'
    Write-Host '下载 Deno...'
    Invoke-WebRequest -Uri 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' -OutFile $denoZip
    $denoDir = Join-Path $cache 'deno'
    if (Test-Path -LiteralPath $denoDir) {
      Remove-Item -LiteralPath $denoDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $denoZip -DestinationPath $denoDir -Force
    $deno = Join-Path $denoDir 'deno.exe'
  }
}

if (-not $FfmpegPath) {
  $command = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($command) {
    $FfmpegPath = $command.Source
  }
}
if (-not $FfmpegPath) {
  $common = @(
    'C:\ffmpeg\bin\ffmpeg.exe',
    'D:\ffmpeg\bin\ffmpeg.exe',
    (Join-Path $root 'ffmpeg\ffmpeg.exe'),
    (Join-Path $root 'ffmpeg\bin\ffmpeg.exe')
  )
  foreach ($candidate in $common) {
    if (Test-Path -LiteralPath $candidate) {
      $FfmpegPath = $candidate
      break
    }
  }
}
if (-not $FfmpegPath -or -not (Test-Path -LiteralPath $FfmpegPath)) {
  throw '找不到 ffmpeg.exe。请用 -FfmpegPath 指定，或把 ffmpeg 加入 PATH。'
}
$FfmpegPath = (Resolve-Path -LiteralPath $FfmpegPath).Path

if (Test-Path -LiteralPath $stage) {
  Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Get-ChildItem -LiteralPath $release -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force
}

Get-ChildItem -LiteralPath $stage -Recurse -Directory -Filter '*.WebView2' -ErrorAction SilentlyContinue |
  Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $stage -Recurse -File |
  Where-Object { $_.Extension -eq '.pdb' } |
  Remove-Item -Force

$tools = Join-Path $stage 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null
Copy-Item -LiteralPath $ytDlp -Destination (Join-Path $tools 'yt-dlp.exe') -Force
Copy-Item -LiteralPath $deno -Destination (Join-Path $tools 'deno.exe') -Force

$ffmpegDir = Join-Path $stage 'ffmpeg'
New-Item -ItemType Directory -Force -Path $ffmpegDir | Out-Null
Copy-Item -LiteralPath $FfmpegPath -Destination (Join-Path $ffmpegDir 'ffmpeg.exe') -Force

$runtimeNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
foreach ($name in $runtimeNames) {
  $source = Join-Path $env:WINDIR "System32\$name"
  if (Test-Path -LiteralPath $source) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Force
  }
}

$redist = Join-Path $stage 'redist'
New-Item -ItemType Directory -Force -Path $redist | Out-Null
$webViewSetup = Join-Path $cache 'MicrosoftEdgeWebView2Setup.exe'
if (-not (Test-Path -LiteralPath $webViewSetup)) {
  try {
    Write-Host '下载 WebView2 Runtime 安装引导（可选）...'
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $webViewSetup
  } catch {
    Write-Warning "WebView2 安装引导下载失败：$($_.Exception.Message)"
  }
}
if (Test-Path -LiteralPath $webViewSetup) {
  Copy-Item -LiteralPath $webViewSetup -Destination (Join-Path $redist 'MicrosoftEdgeWebView2Setup.exe') -Force
}

if (Test-Path -LiteralPath (Join-Path $root 'LICENSE')) {
  Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $stage 'LICENSE') -Force
}

@'
Nexus Download - Windows x64

运行方式
1. 解压整个目录，不要只移动 nexus_download.exe。
2. 双击 nexus_download.exe。

已内置
- FFmpeg：ffmpeg\ffmpeg.exe
- yt-dlp：tools\yt-dlp.exe
- Deno：tools\deno.exe

因此 YouTube 解析不再需要从 GitHub 首次下载这些工具。

系统要求
- Windows 10/11 x64
- 应用内登录（YouTube、X、抖音）依赖 Microsoft Edge WebView2 Runtime。
  Windows 10/11 通常已安装；如果登录窗口空白，运行：
  redist\MicrosoftEdgeWebView2Setup.exe

网络
- B 站、YouTube、X、抖音都需要网络。
- 代理留空时应用会自动检测系统代理和常见本机代理端口，也可以手动填写，例如：
  http://127.0.0.1:7897
- 自动代理只用于应用请求，不会修改系统代理设置。

账号
- 进入“账号”页登录 B 站、YouTube、X、抖音。
- Cookie 保存在本机应用数据目录，不会写入任务文件。
- 抖音的付费/受限作品仍需要对应购买或授权，解析器不会绕过。

第三方组件
- yt-dlp：Unlicense
- Deno：MIT
- FFmpeg：按其发行版许可证分发；重新分发时请遵守对应许可证。
- 项目本体：GNU GPL v3.0，详见 LICENSE。
'@ | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8

$signTarget = Join-Path $stage 'nexus_download.exe'
if ($CertificateThumbprint -or $PfxPath) {
  $signTool = Resolve-SignTool $SignToolPath
  $signArgs = @(
    'sign',
    '/fd', 'SHA256',
    '/td', 'SHA256',
    '/tr', $TimestampUrl,
    '/d', 'Nexus Download',
    '/v'
  )
  if ($CertificateThumbprint) {
    $signArgs += @('/sha1', $CertificateThumbprint.Replace(' ', ''))
  } else {
    if (-not (Test-Path -LiteralPath $PfxPath)) {
      throw "找不到签名证书文件：$PfxPath"
    }
    $signArgs += @('/f', (Resolve-Path -LiteralPath $PfxPath).Path)
    if ($PfxPassword) {
      $signArgs += @('/p', $PfxPassword)
    }
  }
  $signArgs += $signTarget
  Write-Host '签名 nexus_download.exe...'
  & $signTool @signArgs
  if ($LASTEXITCODE -ne 0) {
    throw "代码签名失败，退出码 $LASTEXITCODE"
  }
  & $signTool verify /pa /v $signTarget
  if ($LASTEXITCODE -ne 0) {
    throw "签名校验失败，退出码 $LASTEXITCODE"
  }
} else {
  Write-Warning '未提供证书，生成的是未签名包。可用 -CertificateThumbprint 或 -PfxPath 启用签名。'
}

if (Test-Path -LiteralPath $zip) {
  Remove-Item -LiteralPath $zip -Force
}
Write-Host "压缩 $zip ..."
[IO.Compression.ZipFile]::CreateFromDirectory(
  $stage,
  $zip,
  [IO.Compression.CompressionLevel]::Optimal,
  $true
)

$item = Get-Item -LiteralPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Write-Host ''
Write-Host '打包完成'
Write-Host "路径：$($item.FullName)"
Write-Host "大小：$([Math]::Round($item.Length / 1MB, 2)) MB"
Write-Host "SHA256：$hash"
Write-Host "解压测试目录：$stage"
