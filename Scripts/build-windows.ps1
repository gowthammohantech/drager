# Builds and tests the Windows receiver. Usage: build-windows.ps1 [build|test|smoke|publish|all] [Debug|Release] [x64|ARM64]
# publish: self-contained, unpackaged app (no .NET or Windows App Runtime install needed) zipped
# into build/release/SpatialBridge-Windows-<version>-<arch>.zip.
# Needs the .NET 10 SDK. The WinUI app (build, smoke) needs Windows; test also runs elsewhere
# (Windows-only platform tests skip themselves).
param(
    [ValidateSet('build', 'test', 'smoke', 'publish', 'all')][string]$Action = 'build',
    [ValidateSet('Debug', 'Release')][string]$Config = 'Release',
    [ValidateSet('x64', 'ARM64')][string]$Arch = 'x64'
)
$ErrorActionPreference = 'Stop'
$Root = Join-Path $PSScriptRoot '..\Apps\SpatialBridge-Windows' | Resolve-Path
$App = Join-Path $Root 'src\SpatialBridge.App\SpatialBridge.App.csproj'
$Tests = @('tests\SpatialBridge.Core.Tests', 'tests\SpatialBridge.Platform.Windows.Tests') | ForEach-Object { Join-Path $Root $_ }

function Invoke-Dotnet { & dotnet @args; if ($LASTEXITCODE -ne 0) { throw "dotnet $($args -join ' ') failed ($LASTEXITCODE)" } }

function Build-App {
    Invoke-Dotnet build $App -c $Config -p:Platform=x64 -r win-x64 -warnaserror
}

function Publish-App {
    $rid = "win-$($Arch.ToLowerInvariant())"
    $version = '0.1.0'
    $out = Join-Path $PSScriptRoot "..\build\release\SpatialBridge-Windows-$version-$Arch"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    Invoke-Dotnet publish $App -c $Config -p:Platform=$Arch -r $rid --self-contained true -o $out
    $zip = "$out.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content "$zip.sha256" "$hash  $(Split-Path $zip -Leaf)"
    Write-Host "published $zip ($hash)"
}

function Test-All {
    foreach ($t in $Tests) { Invoke-Dotnet test $t -c $Config }
}

function Invoke-Smoke {
    $exe = Get-ChildItem (Join-Path $Root "src\SpatialBridge.App\bin\x64\$Config") -Recurse -Filter SpatialBridge.App.exe | Select-Object -First 1
    if (-not $exe) { throw 'SpatialBridge.App.exe not found; build first' }
    # WinExe does not block the console, so wait on the process explicitly.
    $p = Start-Process -FilePath $exe.FullName -ArgumentList '--smoke-test' -PassThru
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'smoke test timed out' }
    if ($p.ExitCode -ne 0) { throw "smoke test exited $($p.ExitCode)" }
    Write-Host 'smoke test passed'
}

switch ($Action) {
    'build' { Build-App }
    'test' { Test-All }
    'smoke' { Invoke-Smoke }
    'publish' { Publish-App }
    'all' { Build-App; Test-All; Invoke-Smoke }
}
