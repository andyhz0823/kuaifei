param(
  [string]$ReleaseDirectory = "build\windows\x64\runner\Release",
  [string]$CertificateThumbprint = "8D7D1EB3CC198FE12416EC855C355B2C215EDAE5",
  [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

$certificate = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) {
  throw "The Kuaifei signing certificate does not have a private key."
}

$signTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" `
  -Filter signtool.exe -File -Recurse -ErrorAction Stop |
  Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
  Sort-Object FullName -Descending |
  Select-Object -First 1 -ExpandProperty FullName

if (-not $signTool) {
  throw "signtool.exe was not found in the Windows SDK."
}

$allTargets = Get-ChildItem $ReleaseDirectory -Recurse -File |
  Where-Object { $_.Extension -in ".exe", ".dll" }
$targets = $allTargets | Where-Object {
  (Get-AuthenticodeSignature $_.FullName).Status -ne "Valid"
}

foreach ($target in $allTargets) {
  & $signTool sign /sha1 $CertificateThumbprint /s My /fd SHA256 /td SHA256 /tr $TimestampUrl /d "Kuaifei" $target.FullName
  if ($LASTEXITCODE -ne 0) {
    throw "Signing failed: $($target.FullName)"
  }
}

foreach ($target in $targets) {
  & $signTool verify /pa /all $target.FullName | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Signature verification failed: $($target.FullName)"
  }
}

Write-Host "Signed $($targets.Count) binaries and verified $($allTargets.Count) binaries."
