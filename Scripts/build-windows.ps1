# Builds and tests the Windows receiver. Usage: build-windows.ps1 [build|test|smoke|all] [Debug|Release]
# Needs the .NET 10 SDK. The WinUI app (build, smoke) needs Windows; test also runs elsewhere
# (Windows-only platform tests skip themselves).
param(
    [ValidateSet('build', 'test', 'smoke', 'all')][string]$Action = 'build',
    [ValidateSet('Debug', 'Release')][string]$Config = 'Release'
)
$ErrorActionPreference = 'Stop'
$Root = Join-Path $PSScriptRoot '..\Apps\SpatialBridge-Windows' | Resolve-Path
$App = Join-Path $Root 'src\SpatialBridge.App\SpatialBridge.App.csproj'
$Tests = @('tests\SpatialBridge.Core.Tests', 'tests\SpatialBridge.Platform.Windows.Tests') | ForEach-Object { Join-Path $Root $_ }

function Invoke-Dotnet { & dotnet @args; if ($LASTEXITCODE -ne 0) { throw "dotnet $($args -join ' ') failed ($LASTEXITCODE)" } }

function Build-App {
    Invoke-Dotnet build $App -c $Config -p:Platform=x64 -r win-x64 -warnaserror
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
    'all' { Build-App; Test-All; Invoke-Smoke }
}
