param(
    [Parameter(Mandatory)][string]$WebRtcRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$WebRtcCommit
)

$ErrorActionPreference = 'Stop'
$actual = & git -C $WebRtcRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual -ne $WebRtcCommit) { throw "WebRTC commit uyuşmuyor: $actual" }
$file = Join-Path $WebRtcRoot 'modules/audio_device/win/audio_device_core_win.cc'
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
& (Join-Path $PSScriptRoot 'webrtc-m150-render-ducking.patch.ps1') -WebRtcRoot $WebRtcRoot -ExpectedSourceSha256 $hash -Apply
