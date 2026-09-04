param([string]$Emacs = "build/emacs-31-mingw-w64-ucrt-x86_64/src/emacs.exe")
$ErrorActionPreference = 'Stop'
$buildRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$oldPath = $env:PATH
$oldModule = $env:TIMER_PROBE_MODULE
$oldOutput = $env:TIMER_PROBE_OUTPUT
Push-Location $buildRoot
try {
    & ./scripts/msys2.cmd -c 'gcc -shared -O2 -I build/emacs-31-mingw-w64-ucrt-x86_64/src scripts/tests/w32-thread-timer.c -o build/w32-thread-timer.dll -luser32'
    if ($LASTEXITCODE -ne 0) { throw 'Probe compilation failed' }
    $env:PATH = "$buildRoot/msys64/ucrt64/bin;" + $oldPath
    $env:TIMER_PROBE_MODULE = "$buildRoot/build/w32-thread-timer.dll"
    $env:TIMER_PROBE_OUTPUT = "$buildRoot/build/timer-probe-$([Guid]::NewGuid()).txt"
    $exe = (Resolve-Path $Emacs).Path
    $testFile = "$buildRoot/scripts/tests/w32-thread-timer.el"
    $process = Start-Process -FilePath $exe -ArgumentList '-Q', '-l', ('"' + $testFile + '"') -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(15000)) {
        Stop-Process -Id $process.Id
        throw 'Probe timed out'
    }
    if (Test-Path -LiteralPath $env:TIMER_PROBE_OUTPUT) {
        $result = (Get-Content -LiteralPath $env:TIMER_PROBE_OUTPUT -Raw).Trim()
        Write-Output "Timer result=$result (1=callback lost, 2=callback executed)"
    }
    if ($process.ExitCode -ne 0) { throw "Probe failed: Emacs exit=$($process.ExitCode)" }
    Write-Output 'PASS: Emacs GUI thread dispatched the windowless timer callback.'
} finally {
    $env:PATH = $oldPath
    $env:TIMER_PROBE_MODULE = $oldModule
    $env:TIMER_PROBE_OUTPUT = $oldOutput
    Pop-Location
}
