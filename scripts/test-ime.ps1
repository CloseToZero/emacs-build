# Launch the patched build with -Q for an IME compatibility check.
$ErrorActionPreference = 'Stop'
$buildRoot = (Resolve-Path "$PSScriptRoot/..").Path
$exe = "$buildRoot/build/emacs-31-mingw-w64-ucrt-x86_64/src/emacs.exe"
if (!(Test-Path -LiteralPath $exe)) { throw "Build missing: $exe" }
$oldPath = $env:PATH
try {
    $env:PATH = "$buildRoot/msys64/ucrt64/bin;" + $oldPath
    Start-Process -FilePath $exe -ArgumentList '-Q' -WindowStyle Hidden
} finally {
    $env:PATH = $oldPath
}
