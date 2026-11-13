# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
param(
    [Parameter(Mandatory=$true)][string]$Fixture,
    [Parameter(Mandatory=$true)][string]$Tools,
    [Parameter(Mandatory=$true)][string]$Bash
)
$ErrorActionPreference = 'Stop'
$names = @('PATCH_TEST_FIXTURE', 'PATCH_TEST_TOOLS', 'LC_ALL')
$old = @{}
foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name) }
$handle = $null
try {
    $env:PATCH_TEST_FIXTURE = $Fixture
    $env:PATCH_TEST_TOOLS = $Tools
    $env:LC_ALL = 'C'
    $script = Join-Path $Fixture 'invoke-locked-series.sh'
    $text = @'
# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
source "$(cygpath -u "$PATCH_TEST_TOOLS")"
emacs_build_root="$(cygpath -u "$PATCH_TEST_FIXTURE")"
apply_patches "$emacs_build_root/source" series
'@
    [IO.File]::WriteAllText($script, $text.Replace("`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $series = Join-Path $Fixture 'series'
    $handle = [IO.File]::Open($series, [IO.FileMode]::Open,
                             [IO.FileAccess]::Read, [IO.FileShare]::None)
    if (!(Test-Path -LiteralPath $series -PathType Leaf)) {
        throw 'Fixture did not retain an existing regular series file'
    }
    $log = Join-Path $Fixture 'locked-series.log'
    $command = ('"' + $Bash + '" --noprofile --norc "' + $script +
                '" > "' + $log + '" 2>&1')
    & $env:COMSPEC /d /s /c $command
    $status = $LASTEXITCODE
    $diagnostic = [IO.File]::ReadAllText($log)
    Write-Output $diagnostic
    if ($status -eq 0) { throw 'An existing but unopenable series was reported as successful' }
    if ($diagnostic -notmatch 'Patch series could not be opened:') {
        throw 'Failure was not the expected series-opening diagnostic'
    }
    Write-Output 'PASS: an existing locked series fails preparation explicitly'
} finally {
    if ($handle) { $handle.Dispose() }
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name]) }
}
