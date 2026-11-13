param(
    [Parameter(Mandatory)][string]$WebRtcRoot,
    [ValidateSet('audio_device_core_win.cc', 'core_audio_base_win.cc', 'core_audio_output_win.cc')]
    [string]$SourceFile = 'audio_device_core_win.cc',
    [ValidateRange(0, 2147483647)][int]$RenderStartLine = 0,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSourceSha256,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = (Resolve-Path -LiteralPath $WebRtcRoot).Path
if (!$root.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'WebRTC kaynak kopyası Kanko klasörünün altında olmalı.'
}
$path = Join-Path $root "modules/audio_device/win/$SourceFile"
for ($item = Get-Item -LiteralPath $path; $item -and $item.FullName -ne $workspace; $item = Get-Item -LiteralPath (Split-Path -Parent $item.FullName)) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Bağlantı üzerinden kaynak değiştirilemez: $($item.FullName)"
    }
}
$source = [IO.File]::ReadAllText($path)
if ($source.Contains('Kanko WASAPI ducking')) { throw 'Yama zaten uygulanmış.' }
$hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
if ($ExpectedSourceSha256 -and $hash -ne $ExpectedSourceSha256) {
    throw "Kaynak SHA256 uyuşmuyor: $hash"
}
if ($Apply -and !$ExpectedSourceSha256) { throw 'Uygulama için kaynak SHA256 değeri gerekli.' }
$newline = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = [Collections.Generic.List[string]]::new()
$lines.AddRange([string[]]($source -split '\r?\n'))
if ($RenderStartLine -eq 0) {
    if ($SourceFile -ne 'audio_device_core_win.cc') { throw 'Render Start satırı gerekli.' }
    $anchors = @(for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^  hr = _ptrClientOut->Start\(\);\s*$') { $i }
    })
    if ($anchors.Count -ne 1 -or $source -notmatch '_ptrClientOut->Initialize\(') {
        throw 'M150 render Initialize/Start bağlamı bulunamadı.'
    }
    $RenderStartLine = $anchors[0] + 1
}
if ($RenderStartLine -gt $lines.Count) { throw 'Satır dosya dışında.' }
$line = $lines[$RenderStartLine - 1]
$start = [regex]::Match($line, '^(?<indent> +)(?:(?:const )?(?:HRESULT|auto)\s+\w+\s*=\s*|\w+\s*=\s*|return\s+)?(?<client>[A-Za-z_]\w*(?:(?:\.|->)[A-Za-z_]\w*(?:\(\))?)*)->Start\(\);\s*$')
if (!$start.Success) { throw 'Satır, tek başına bir IAudioClient Start çağrısı olmalı.' }

$client = $start.Groups['client'].Value
$indent = $start.Groups['indent'].Value
$block = @'
// This client has been initialized for eRender. Apply before starting it.
#if defined(__IAudioClientDuckingControl_INTERFACE_DEFINED__)
{
  IAudioClientDuckingControl* ducking_control = nullptr;
  const HRESULT service_hr = CLIENT->GetService(IID_PPV_ARGS(&ducking_control));
  char diagnostic[160];
  sprintf_s(diagnostic,
            "Kanko WASAPI ducking flow=eRender GetService HRESULT=0x%08lX\n",
            static_cast<unsigned long>(service_hr));
  OutputDebugStringA(diagnostic);
  if (SUCCEEDED(service_hr) && ducking_control != nullptr) {
    const HRESULT options_hr = ducking_control->SetDuckingOptionsForCurrentStream(
        AUDIO_DUCKING_OPTIONS_DO_NOT_DUCK_OTHER_STREAMS);
    sprintf_s(diagnostic,
              "Kanko WASAPI ducking flow=eRender SetDuckingOptions HRESULT=0x%08lX\n",
              static_cast<unsigned long>(options_hr));
    OutputDebugStringA(diagnostic);
    ducking_control->Release();
  }
}
#else
OutputDebugStringA("Kanko WASAPI ducking flow=eRender unavailable in Windows SDK\n");
#endif
'@
$blockLines = @($block.Replace('CLIENT', $client) -split '\r?\n' | ForEach-Object {
    if ($_.StartsWith('#')) { $_ } else { $indent + $_ }
})
$lines.InsertRange($RenderStartLine - 1, [string[]]$blockLines)
$result = $lines -join $newline
if ($result -notmatch '(?m)^#include <windows.h>\s*$') {
    throw 'Windows başlığı bulunamadı. Kaynak bağlamını inceleyin.'
}
if ($result -notmatch '(?m)^#include <stdio.h>\s*$') {
    $result = $result.Replace('#include <windows.h>', "#include <windows.h>${newline}#include <stdio.h>")
}
Write-Output "$($path):$RenderStartLine"
Write-Output "Kaynak SHA256: $hash"
$blockLines | Write-Output
if ($Apply) {
    [IO.File]::WriteAllText($path, $result)
}
