param(
    [string]$Emacs = 'build/emacs-31-mingw-w64-ucrt-x86_64/src/emacs.exe',
    [string]$BaselineEmacs,
    [string]$Source = 'git/emacs-31',
    [string]$Build = 'build/emacs-31-mingw-w64-ucrt-x86_64'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$names = @('PATH', 'EMACS_W32_LONG_PATH_MODULE', 'EMACS_W32_LONG_PATH_CLEANUP_FILE',
           'EMACS_W32_LONG_PATH_CLEANUP_ROOT')
$old = @{}
foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name) }
Push-Location $root
try {
    $artifacts = [IO.Path]::Combine($root, 'build/w32-long-path')
    [IO.Directory]::CreateDirectory($artifacts) | Out-Null
    $gcc = "$root/msys64/ucrt64/bin/gcc.exe"
    $env:PATH = "$root/msys64/ucrt64/bin;" + $old['PATH']
    $env:EMACS_W32_LONG_PATH_MODULE = "$artifacts/probe.dll"
    $env:EMACS_W32_LONG_PATH_CLEANUP_FILE = "$artifacts/loaded-module-root.txt"
    Remove-Item $env:EMACS_W32_LONG_PATH_CLEANUP_FILE -ErrorAction SilentlyContinue

    & $gcc -shared -O2 -Wall -Wextra -Wno-unused-parameter "-I$Build/src" `
        "$Source/test/src/w32-long-path-resources/probe.c" -o $env:EMACS_W32_LONG_PATH_MODULE
    if ($LASTEXITCODE -ne 0) { throw 'Native fixture compilation failed' }

    # Test the implementation itself, not a second hand-maintained copy.
    $sourceText = [IO.File]::ReadAllText((Join-Path $root "$Source/src/w32.c"))
    $begin = $sourceText.IndexOf('/* Keep errno and GetLastError consistent,')
    $end = $sourceText.IndexOf('/* The directory where we started,', $begin)
    if ($begin -lt 0 -or $end -lt 0) { throw 'Cannot locate filename converters' }
    [IO.File]::WriteAllText("$artifacts/filename-under-test.c",
        $sourceText.Substring($begin, $end - $begin), [Text.UTF8Encoding]::new($false))
    & $gcc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare `
        "-I$artifacts" "$PSScriptRoot/w32-filename-test.c" -o "$artifacts/filename-test.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Converter test compilation failed' }
    & "$artifacts/filename-test.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Converter tests failed' }

    function Invoke-TestEmacs([string]$Exe, [string]$Label, [string]$Expression) {
        $exePath = (Resolve-Path $Exe).Path
        $testFile = (Resolve-Path "$Source/test/src/w32-long-path-tests.el").Path
        $stdout = "$artifacts/$Label.stdout.log"
        $stderr = "$artifacts/$Label.log"
        $arguments = @('-Q', '--batch', '-l', ('"' + $testFile + '"'),
                       '--eval', ('"' + $Expression.Replace('"', '\"') + '"'))
        # Own the process handle from creation.  Start-Process can lose
        # the exit code of a very short-lived cleanup process on PS 5.1.
        $process = [Diagnostics.Process]::new()
        $process.StartInfo.FileName = $exePath
        $process.StartInfo.Arguments = $arguments -join ' '
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $process.StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
        try {
            $null = $process.Start()
            $outTask = $process.StandardOutput.ReadToEndAsync()
            $errTask = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(120000)) {
                $process.Kill()
                throw "$Label timed out"
            }
            $process.WaitForExit()
            [IO.File]::WriteAllText($stdout, $outTask.GetAwaiter().GetResult())
            [IO.File]::WriteAllText($stderr, $errTask.GetAwaiter().GetResult())
            Get-Content $stdout -Encoding UTF8 | Write-Host
            Get-Content $stderr -Encoding UTF8 | Write-Host
            return $process.ExitCode
        } finally {
            $process.Dispose()
        }
    }

    if ($BaselineEmacs) {
        $status = Invoke-TestEmacs $BaselineEmacs 'baseline' `
            '(ert-run-tests-batch-and-exit "w32-long-path-tests-native-262")'
        $baselineLog = [IO.File]::ReadAllText("$artifacts/baseline.log")
        if ($status -eq 0) { throw 'Baseline unexpectedly passed; check the supplied binary' }
        if ($baselineLog -notmatch 'FAILED\s+1/1\s+w32-long-path-tests-native-262' -or
            $baselineLog -notmatch 'should \(file-exists-p file\)') {
            throw 'Baseline failed for a reason other than the expected existence-check regression'
        }
        Write-Host 'BASELINE: independently created 262-unit path reproduced the failure.'
    }

    try {
        $status = Invoke-TestEmacs $Emacs 'patched' `
            '(ert-run-tests-batch-and-exit "w32-long-path-tests-")'
    } finally {
        # A module cannot be unloaded while its Emacs is running.  Clean its
        # long-path copy after exit, using the same independent native fixture.
        if (Test-Path $env:EMACS_W32_LONG_PATH_CLEANUP_FILE) {
            $number = 0
            foreach ($fixtureRoot in [IO.File]::ReadAllLines($env:EMACS_W32_LONG_PATH_CLEANUP_FILE)) {
                if (!$fixtureRoot.Trim()) { continue }
                $env:EMACS_W32_LONG_PATH_CLEANUP_ROOT = $fixtureRoot.Trim()
                $cleanup = Invoke-TestEmacs $Emacs "cleanup-$number" `
                    '(kill-emacs (if (= 0 (w32-long-path-tests--native "remove" (getenv "EMACS_W32_LONG_PATH_CLEANUP_ROOT"))) 0 1))'
                if ($cleanup -ne 0) { throw "Loaded fixture cleanup failed: $fixtureRoot" }
                $number++
            }
            Remove-Item $env:EMACS_W32_LONG_PATH_CLEANUP_FILE
        }
    }
    if ($status -ne 0) { throw "Long-path regressions failed: exit=$status" }
    Write-Host "PASS: Win32 long-path regressions. Logs: $artifacts"
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) }
    Pop-Location
}
