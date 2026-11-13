param(
    [ValidateSet('a545de45259b47dfac5f3635863e47cb601f1bb2')]
    [string]$WebRtcCommit = 'a545de45259b47dfac5f3635863e47cb601f1bb2',
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$wrapper = Join-Path $root 'webrtc-work/libwebrtc'
$dir = Join-Path $wrapper 'build'
foreach ($path in @((Split-Path $wrapper), $wrapper, $dir)) {
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Bağlantı üzerinden derlenemez: $path"
    }
}
$expected = '4515f9ccdca75e2454e204f326f1d7129cad678e'
$actual = & git -C $wrapper rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw 'Önce Get-WebRtcM150Source.ps1 çalıştırın.' }
& git -C $wrapper diff --quiet HEAD -- .
if ($LASTEXITCODE -ne 0) { throw 'Sarmalayıcının izlenen dosyaları değiştirilmiş.' }
$recipe = Join-Path $dir 'libwebrtc_win_build.cmd'
$source = [IO.File]::ReadAllText($recipe)
$anchor = '(?im)^call gn\.bat gen [^\r\n]+'
if ([regex]::Matches($source, $anchor).Count -ne 1) { throw 'Yayın betiğinin GN başlangıcı tanınmadı.' }
if ($source -notmatch '(?im)^call gclient\.bat sync\b' -or
    $source -notmatch '(?im)^\s*--args="[^\r\n]*"\r?$' -or
    $source -notmatch '(?im)^ninja\.exe .+\blibwebrtc\b') {
    throw 'Yayın betiğinin sync, GN veya Ninja adımları tanınmadı.'
}
$patched = Join-Path $dir 'kanko-libwebrtc-win-build.cmd'
$stage = Join-Path $PSScriptRoot 'Apply-WebRtcM150BuildPatch.ps1'
$insertion = @"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$stage" -WebRtcRoot "%~dp0src" -WebRtcCommit $WebRtcCommit
if errorlevel 1 exit /b 1
"@
$source = $source -replace '(?im)^set (?:GYP_MSVS_VERSION|vs2019_install)=[^\r\n]*\r?\n', ''
$source = $source -replace '(?im)^call git clean -df\s*\r?\n', ''
$source = $source -replace '(?im)^if exist "%ARTIFACTS_DIR%" \(\r?\n +rmdir /s /q "%ARTIFACTS_DIR%"\r?\n\)\r?\n', ''
if ($source -match '(?im)^\s*(?:call\s+)?(?:git clean|rmdir)\b') { throw 'Yayın tarifinde beklenmeyen temizleme komutu var.' }
$source = $source -replace '(?im)^(call gclient\.bat sync[^\r\n]*)', ('$1 --revision src@' + $WebRtcCommit)
$source = [regex]::Replace($source, '(?im)^(pushd src|cd src|call git checkout -f [^\r\n]*|(?:call )?git clone [^\r\n]*)', '$1' + "`r`nif errorlevel 1 exit /b 1")
$source = $source -replace '(?im)^@echo off', ('@echo off' + "`r`ncd /d `"%~dp0`" || exit /b 1")
$source = [regex]::Replace($source, $anchor, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $insertion + "`r`n" + $m.Value })
$source = [regex]::Replace($source, '(?im)^(call (?:git apply|gclient\.bat sync)[^\r\n]*)', '$1' + "`r`nif errorlevel 1 exit /b 1")
$source = [regex]::Replace($source, '(?im)^(cd src\r?\nif errorlevel 1 exit /b 1)', ('$1' + "`r`ngit rev-parse HEAD | findstr /i /x /c:`"$WebRtcCommit`" >nul || exit /b 1"))
$source = $source -replace '(?im)^(\s*--args="[^\r\n]*")\r?$', ('$1' + "`r`nif errorlevel 1 exit /b 1")
Write-Output $source
if (!$Build) { return }

$policy = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'Get-ExecutionPolicy'
if ($LASTEXITCODE -ne 0 -or "$policy".Trim() -ne 'Bypass') {
    throw "Alt PowerShell betiği çalıştırılamıyor. Etkin ilke: $policy. MachinePolicy/UserPolicy ayarlarını kontrol edin."
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Visual Studio Installer (vswhere.exe) bulunamadı.' }
$vs = & $vswhere -latest -products '*' -version '[18.0,19.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$vs) { throw 'Visual Studio 2026 x64 C++ araçları bulunamadı. Visual Studio Installer içinden kurulu C++ bileşenlerini kontrol edin.' }
$toolsVersion = Join-Path $vs 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt'
if (!(Test-Path -LiteralPath $toolsVersion -PathType Leaf)) { throw 'Visual Studio 2026 varsayılan MSVC araç sürümü bulunamadı.' }
$msvc = Join-Path $vs ('VC/Tools/MSVC/' + (Get-Content -LiteralPath $toolsVersion -Raw).Trim())
if (!(Test-Path -LiteralPath (Join-Path $msvc 'bin/Hostx64/x64/cl.exe') -PathType Leaf) -or
    !(Test-Path -LiteralPath (Join-Path $msvc 'lib/x64/msvcprt.lib') -PathType Leaf)) { throw 'Visual Studio 2026 MSVC x64 derleyicisi veya kitaplıkları eksik.' }
$sdk = if ($env:WINDOWSSDKDIR) { $env:WINDOWSSDKDIR } else { Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10' }
foreach ($file in @('Include/10.0.26100.0/um/audioclient.h', 'Lib/10.0.26100.0/um/x64/kernel32.lib', 'Lib/10.0.26100.0/ucrt/x64/ucrt.lib')) {
    if (!(Test-Path -LiteralPath (Join-Path $sdk $file) -PathType Leaf)) { throw "Windows SDK 10.0.26100.0 x64 bileşeni eksik: $file" }
}
if (!(Select-String -LiteralPath (Join-Path $sdk 'Include/10.0.26100.0/um/audioclient.h') -Pattern '__IAudioClientDuckingControl_INTERFACE_DEFINED__' -Quiet)) {
    throw 'Windows SDK başlığında NO_DUCK arayüzü bulunamadı.'
}
$ninja = Get-Command ninja.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$ninjaPath = if ($ninja) { $ninja.Source } else { Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe' }
if (!(Test-Path -LiteralPath $ninjaPath -PathType Leaf)) { throw 'Ninja bulunamadı. Visual Studio CMake araçlarını kontrol edin veya ninja.exe dosyasını PATH üzerinde erişilebilir yapın.' }
Write-Host "M150 araç zinciri: $vs | SDK: $sdk (10.0.26100.0) | Ninja: $ninjaPath"
foreach ($name in @('src', 'depot_tools', 'libwebrtc-x64-release', 'kanko-libwebrtc-win-build.cmd')) {
    if (Test-Path -LiteralPath (Join-Path $dir $name)) { throw "Derleme için boş yayın çalışma kopyası gerekli. Mevcut yol: $dir\$name" }
}
$gclient = Join-Path $dir '.gclient'
$gclientSource = [IO.File]::ReadAllText($gclient)
$saved = @{}
$buildEnv = @{ vs2026_install = $vs; GYP_MSVS_OVERRIDE_PATH = $vs; WINDOWSSDKDIR = $sdk; Path = "$(Split-Path $ninjaPath);$env:Path" }
Push-Location -LiteralPath $dir
try {
    foreach ($name in $buildEnv.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $buildEnv[$name], 'Process')
    }
    if ($gclientSource -notmatch '(?m)^\s*target_os\s*=') {
        [IO.File]::AppendAllText($gclient, "`r`ntarget_os = [`"win`"]`r`n")
    }
    [IO.File]::WriteAllText($patched, $source, [Text.Encoding]::ASCII)
    & $patched --arch x64 --profile release --commit $WebRtcCommit
    if ($LASTEXITCODE -ne 0) { throw "Yayın derlemesi başarısız: $LASTEXITCODE" }
    $artifacts = Join-Path $dir 'libwebrtc-x64-release'
    foreach ($file in @('lib/libwebrtc.dll', 'lib/libwebrtc.dll.lib')) {
        Get-FileHash -LiteralPath (Join-Path $artifacts $file) -Algorithm SHA256
    }
    Write-Output "Aday çıktı: $artifacts"
} finally {
    Pop-Location
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    [IO.File]::WriteAllText($gclient, $gclientSource)
}
