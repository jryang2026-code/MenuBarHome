# A cold run or a cache miss still downloads the bundler tools, so retry once when the only
# failure is an HTTP 5xx download. Compile errors do not match and fail immediately.
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$log = Join-Path $tempRoot 'tauri-build.log'
Remove-Item $log -ErrorAction SilentlyContinue
function Invoke-TauriBuild {
    & npx tauri build -- --locked 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
    $script:tauriExitCode = $LASTEXITCODE
}
Invoke-TauriBuild
$exitCode = $script:tauriExitCode
if ($exitCode -ne 0) {
    $output = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
    if ($output -match 'http status:\s*5\d\d') {
        Write-Host '::warning::Tauri bundler download returned an HTTP 5xx; retrying once'
        Invoke-TauriBuild
        $exitCode = $script:tauriExitCode
    }
}
if ($null -eq $exitCode) { $exitCode = 1 }
exit $exitCode
