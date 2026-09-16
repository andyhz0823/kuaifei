<#
.SYNOPSIS
  把已发布的 Kuaifei GitHub Release 投放到客户端更新通道（xz.kuaity.top/Downloads）。

.DESCRIPTION
  本地手动执行版 —— 仓库内不保存任何服务器私钥。

  执行流程：
    1. 从 GitHub Release 元数据生成三份清单
       latest.json / latest-windows.json / appcast.xml
    2. 上传远端镜像脚本到服务器
    3. 服务器直连 GitHub 拉取产物 -> SHA-256 校验 -> 镜像到分发目录
    4. 上传三份清单并对齐属主/权限
    5. 公网复验：清单逐字节比对 + 产物 Range 请求

  产物不经过本机中转（服务器直连 GitHub 下载），本机只传 KB 级清单。

.PARAMETER Tag
  Release 标签，例如 v4.1.14。

.EXAMPLE
  # 推荐：私钥路径走环境变量，避免把本机路径写进脚本
  $env:KUAIFEI_DEPLOY_SSH_KEY = 'D:\path\to\deploy.pem'
  .\deploy-update-channel.ps1 -Tag v4.1.14

.EXAMPLE
  .\deploy-update-channel.ps1 -Tag v4.1.14 -SshKeyPath 'C:\keys\deploy.pem' -SkipVerify
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Tag,

  [string]$Repo = 'andyhz0823/kuaifei',
  [string]$SshKeyPath = $env:KUAIFEI_DEPLOY_SSH_KEY,
  [string]$DeployHost = '216.18.193.108',
  [string]$DeployUser = 'root',
  [int]$SshPort = 22,
  [string]$RemotePath = '/www/wwwroot/kuaifei.top/Downloads',
  [string]$BaseUrl = 'https://xz.kuaity.top/Downloads',
  [string]$PythonExe = '',
  [switch]$SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

function Info([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die([string]$m) {
  Write-Host "ERROR: $m" -ForegroundColor Red
  # 直接写 stderr：避免 exit 时管道未 flush 导致错误信息丢失
  try { [Console]::Error.WriteLine("ERROR: $m") } catch { }
  exit 1
}

# ---------------------------------------------------------------- 前置检查
if ($Tag -notmatch '^v\d+(\.\d+)*$') {
  Die "标签格式不合法：$Tag（应形如 v4.1.14）"
}
if ([string]::IsNullOrWhiteSpace($SshKeyPath)) {
  Die @"
未提供 SSH 私钥路径。请任选其一：
    - 设置环境变量：`$env:KUAIFEI_DEPLOY_SSH_KEY = '<私钥路径>'
    - 显式传参：     -SshKeyPath '<私钥路径>'
"@
}
if (-not (Test-Path -LiteralPath $SshKeyPath)) {
  Die "找不到 SSH 私钥：$SshKeyPath"
}
foreach ($exe in 'ssh', 'scp') {
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
    Die "PATH 中找不到 $exe（需要 Windows OpenSSH 客户端）"
  }
}

function Resolve-Python([string]$Explicit) {
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath $Explicit)) { Die "指定的 Python 不存在：$Explicit" }
    return $Explicit
  }
  $candidates = @(
    'C:\Users\Administrator\.workbuddy\binaries\python\versions\3.13.12\python.exe'
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  foreach ($name in 'python', 'py') {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  Die ' 找不到 Python，请用 -PythonExe 指定解释器路径'
}
$python = Resolve-Python $PythonExe

$scriptDir = $PSScriptRoot
$genScript = Join-Path $scriptDir 'gen_update_manifests.py'
$mirrorScript = Join-Path $scriptDir 'remote_mirror_release.sh'
foreach ($f in @($genScript, $mirrorScript)) {
  if (-not (Test-Path -LiteralPath $f)) { Die "缺少依赖脚本：$f" }
}

# ---------------------------------------------------------------- 工作目录
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('kuaifei-channel-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$manifestsDir = Join-Path $work 'manifests'
New-Item -ItemType Directory -Path $manifestsDir -Force | Out-Null

# Windows OpenSSH 会拒绝权限过宽的私钥文件，且原路径可能含非 ASCII 字符，
# 故复制一份到纯 ASCII 临时路径；finally 中删除。
$keyCopy = Join-Path $work 'id_deploy'
Copy-Item -LiteralPath $SshKeyPath -Destination $keyCopy -Force
# Windows OpenSSH 会拒用权限过宽的私钥（临时目录默认继承宽松 ACL），
# 这里断开 ACL 继承并只保留当前用户的完全控制。
& icacls $keyCopy /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
if ($LASTEXITCODE -ne 0) { Die "无法收敛私钥副本的权限：$keyCopy" }

$sshOpts = @(
  '-i', $keyCopy,
  '-p', "$SshPort",
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', 'BatchMode=yes',
  '-o', 'ConnectTimeout=20'
)
$scpOpts = @(
  '-i', $keyCopy,
  '-P', "$SshPort",
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', 'BatchMode=yes'
)
$remote = "$DeployUser@$DeployHost"
$dlBase = "https://github.com/$Repo/releases/download/$Tag"

try {
  # ------------------------------------------------------------ 1. 生成清单
  Info "生成更新清单（$Tag）"
  & $python $genScript --tag $Tag --repo $Repo --base-url $BaseUrl --out $manifestsDir --require-assets
  if ($LASTEXITCODE -ne 0) { Die "清单生成失败（退出码 $LASTEXITCODE）" }

  $assetList = @(
    Get-Content -LiteralPath (Join-Path $manifestsDir 'channel-assets.txt') |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' }
  )
  if ($assetList.Count -eq 0) { Die 'channel-assets.txt 为空，无可投放产物' }
  Info "待镜像产物（$($assetList.Count) 个）：$($assetList -join ' ')"

  # ------------------------------------------------------------ 2. 上传远端脚本
  Info "上传远端投放脚本到 $remote"
  & scp @scpOpts $mirrorScript "${remote}:/tmp/kuaifei-remote-mirror.sh"
  if ($LASTEXITCODE -ne 0) { Die '远端脚本上传失败' }

  # ------------------------------------------------------------ 3. 远端拉取 + 镜像
  $quoted = ($assetList | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
  $remoteCmd = "bash /tmp/kuaifei-remote-mirror.sh '$Tag' '$RemotePath' '$dlBase' $quoted; rc=`$?; rm -f /tmp/kuaifei-remote-mirror.sh; exit `$rc"

  Info "服务器直连 GitHub 拉取产物并镜像到 $RemotePath"
  & ssh @sshOpts $remote $remoteCmd
  if ($LASTEXITCODE -ne 0) { Die "远端镜像失败（退出码 $LASTEXITCODE）" }

  # ------------------------------------------------------------ 4. 上传清单
  Info '上传三份更新清单'
  $manifestFiles = @('latest.json', 'latest-windows.json', 'appcast.xml') |
    ForEach-Object { Join-Path $manifestsDir $_ }
  & scp @scpOpts @manifestFiles "${remote}:$RemotePath/"
  if ($LASTEXITCODE -ne 0) { Die '清单上传失败' }

  $chownCmd = "cd '$RemotePath' && chown --reference=`"`$(find . -maxdepth 1 -type f -print -quit)`" latest.json latest-windows.json appcast.xml 2>/dev/null || chown 1000:1000 latest.json latest-windows.json appcast.xml; chmod 644 latest.json latest-windows.json appcast.xml; ls -la latest.json latest-windows.json appcast.xml"
  & ssh @sshOpts $remote $chownCmd
  if ($LASTEXITCODE -ne 0) { Die '清单属主/权限设置失败' }

  # ------------------------------------------------------------ 5. 公网复验
  if ($SkipVerify) {
    Warn '已跳过公网复验（-SkipVerify）'
  }
  else {
    Info '公网复验'
    foreach ($name in @('latest.json', 'latest-windows.json', 'appcast.xml')) {
      $localFile = Join-Path $manifestsDir $name
      $remoteFile = Join-Path $work "verify_$name"
      & curl.exe -fsSL --retry 3 -o $remoteFile "$BaseUrl/$name"
      if ($LASTEXITCODE -ne 0) { Die "清单不可访问：$BaseUrl/$name" }

      $localHash = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash
      $remoteHash = (Get-FileHash -LiteralPath $remoteFile -Algorithm SHA256).Hash
      if ($localHash -ne $remoteHash) { Die "清单内容与本地不一致：$name" }
      Ok "$name 内容一致"
    }

    foreach ($asset in $assetList) {
      # 注意：不能用 -o $null（PowerShell 会把 $null 参数整个吞掉），Windows 空设备是 NUL
      $code = & curl.exe -sS -o NUL -w '%{http_code}' --range 0-0 "$BaseUrl/$asset"
      if ($code -ne '200' -and $code -ne '206') { Die "产物不可访问：$asset（HTTP $code）" }
      Ok "$asset 可访问（HTTP $code）"
    }
  }

  Info "更新通道投放完成：$Tag -> $BaseUrl"
}
finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
