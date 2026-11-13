# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
param(
    [string]$Emacs = 'build/emacs-31-mingw-w64-ucrt-x86_64/src/emacs.exe',
    [int]$TimeoutSeconds = 90,
    [string]$Selector = '^redisplay-tests-'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$exe = (Resolve-Path $Emacs).Path
$state = Join-Path $root ('build/redisplay-tests/' + [guid]::NewGuid().ToString('N'))
$names = @('HOME', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'PATH',
           'REDISPLAY_TEST_STATE', 'REDISPLAY_TEST_SELECTOR',
           'EMACS_SERVER_FILE', 'EMACS_SOCKET_NAME')
$old = @{}
foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name) }
$result = @{ executable = $exe; state = $state; success = $false }
try {
    foreach ($name in @('HOME', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')) {
        $directory = Join-Path $state $name.ToLowerInvariant()
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [Environment]::SetEnvironmentVariable($name, $directory)
    }
    $env:PATH = "$root/msys64/ucrt64/bin;" + $old['PATH']
    $env:REDISPLAY_TEST_STATE = $state
    $env:REDISPLAY_TEST_SELECTOR = $Selector
    $env:EMACS_SERVER_FILE = $null
    $env:EMACS_SOCKET_NAME = $null
    $init = Join-Path $state 'init'
    [IO.Directory]::CreateDirectory($init) | Out-Null
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $exe
    $process.StartInfo.Arguments = ('-Q --init-directory "' + $init + '" --load "' +
                                   (Join-Path $PSScriptRoot 'redisplay-tests.el') + '"')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        $null = $process.Start()
        $result.pid = $process.Id
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            $result.timedOut = $true
        }
        $process.WaitForExit()
        [IO.File]::WriteAllText((Join-Path $state 'stdout.log'), $out.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $state 'stderr.log'), $err.GetAwaiter().GetResult())
        $result.exitCode = $process.ExitCode
        $progress = Join-Path $state 'progress.log'
        $result.timerServiced = ((Test-Path $progress) -and
            ([IO.File]::ReadAllText($progress).Contains('post-redisplay timer serviced')))
        $result.success = ($process.ExitCode -eq 0 -and !$result.timedOut -and $result.timerServiced)
    } finally {
        if ($result.pid -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) }
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state 'result.json') -Encoding utf8
}
$result | ConvertTo-Json
if (!$result.success) { throw "Graphical redisplay regression failed; see $state" }
