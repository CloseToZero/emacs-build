# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: GPL-3.0-or-later
param(
    [Parameter(Mandatory = $true)][string]$Emacs,
    [string]$ModuleInclude,
    [string]$Compiler,
    [string]$Selector = '^emacsbuild-pipe-',
    [int]$TimeoutSeconds = 120,
    [switch]$Standalone,
    [string]$WorkDirectory
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../..").Path
$exe = (Resolve-Path $Emacs).Path
if (!$Compiler) { $Compiler = "$root/msys64/ucrt64/bin/gcc.exe" }
if (!$ModuleInclude) { $ModuleInclude = Join-Path (Split-Path $exe) '../include' }
if (!$WorkDirectory) {
    $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) "emacs-pipes-$([Guid]::NewGuid())"
}
$state = [IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Force $state, "$state/home", "$state/emacs" | Out-Null
$module = "$state/pipe-probe.dll"
$child = "$state/pipe-child.exe"
$compilerPath = $env:PATH
try {
    $env:PATH = "$(Split-Path $Compiler);$compilerPath"
    & $Compiler -O2 -shared "-I$ModuleInclude" "$PSScriptRoot/w32-pipe-probe.c" -o $module
    if ($LASTEXITCODE -ne 0) { throw 'Pipe probe module compilation failed' }
    & $Compiler -O2 -DPIPE_PROBE_CHILD "$PSScriptRoot/w32-pipe-probe.c" -o $child
    if ($LASTEXITCODE -ne 0) { throw 'Pipe probe child compilation failed' }
} finally {
    $env:PATH = $compilerPath
}
$runtimePath = "$(Split-Path $exe);$env:SystemRoot/System32;$env:SystemRoot"
if (!$Standalone) { $runtimePath = "$(Split-Path $Compiler);$runtimePath" }
foreach ($name in @('appdata', 'localappdata', 'tmp')) {
    New-Item -ItemType Directory -Force "$state/$name" | Out-Null
}
$environment = @{
    HOME = "$state/home"; USERPROFILE = "$state/home"; PATH = $runtimePath
    APPDATA = "$state/appdata"; LOCALAPPDATA = "$state/localappdata"
    TEMP = "$state/tmp"; TMP = "$state/tmp"
    XDG_CONFIG_HOME = "$state/xdg-config"; XDG_CACHE_HOME = "$state/xdg-cache"
    XDG_DATA_HOME = "$state/xdg-data"; EMACS_SERVER_FILE = $null; EMACS_SOCKET_NAME = $null
    EMACSBUILD_PIPE_MODULE = $module; EMACSBUILD_PIPE_CHILD = $child
    EMACSBUILD_PIPE_SELECTOR = $Selector
}
$old = @{}
foreach ($key in $environment.Keys) {
    $old[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $environment[$key], 'Process')
}
$process = $null
try {
    $arguments = @('--batch', '-Q', '--init-directory', ('"' + "$state/emacs" + '"'),
                   '-l', ('"' + "$PSScriptRoot/w32-pipe-tests.el" + '"'))
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput "$state/stdout.log" -RedirectStandardError "$state/stderr.log"
    $null = $process.Handle
    if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id
        throw "Pipe tests timed out; owned test PID=$($process.Id); logs=$state"
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "Pipe tests failed: exit=$($process.ExitCode); logs=$state"
    }
    Write-Output "PASS: isolated pipe tests; executable=$exe; logs=$state"
} finally {
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id }
    foreach ($key in $old.Keys) {
        [Environment]::SetEnvironmentVariable($key, $old[$key], 'Process')
    }
}
