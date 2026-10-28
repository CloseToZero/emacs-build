# Private Windows long-path patch

Patch: `patches/emacs/0037-Support-extended-length-W32-file-paths.patch`.
The active source checkout is `git/emacs-31`; the executable produced here is
`build/emacs-31-mingw-w64-ucrt-x86_64/src/emacs.exe`. The installed Emacs is not
replaced by this change.

## What changes

- Keep `MAX_PATH` and `MAXPATHLEN` unchanged for Windows/CRT ABI compatibility.
  Introduce a separate 32,768-unit UTF-16 path capacity and corresponding UTF-8
  storage. Filename transcoding takes the destination's actual capacity;
  pointer destinations explicitly supply it rather than using the array macros.
- Normalize long paths before adding `\\?\` or `\\?\UNC\` at filesystem API
  boundaries. Relative symlink targets are only transcoded, not absolutized.
  Strip internally added prefixes from paths returned to Lisp.
- Cover existence/access checks, attributes/stat, open/create/read/write,
  mkdir/rmdir, directory enumeration, chmod/timestamps, copy (including ACLs),
  rename/replace, unlink, hard links, symlink/readlink handling, and realpath.
- Cover directory watches, module/DLL loading, Unicode GDI+ paths, clipboard
  image output, and sound filename conversion. Pass extended ANSI spellings to
  external UCRT-based consumers, including the native compiler.
- Propagate conversion and mapping errors instead of using uninitialized or
  truncated buffers. Overlong UTF-8 mapping fails explicitly, not via a fake
  `"?"` filename. Keep append space for directory search wildcards and trash's
  double-null terminator. Correct wide-API element counts and dirent sizing.
- Add `longPathAware` to x86, x64 and ARM64 manifests. Actual Unicode file I/O
  uses extended paths, rather than relying solely on the registry opt-in.

## Build and test

From PowerShell at the repository root:

```powershell
$env:MSYSTEM = 'UCRT64'
.\scripts\msys2.cmd -c 'make -C build/emacs-31-mingw-w64-ucrt-x86_64 -j8'

.\scripts\tests\test-w32-long-path.ps1

# Optional: reproduce the original failure with an unpatched binary first.
.\scripts\tests\test-w32-long-path.ps1 `
  -BaselineEmacs D:/software/emacs/bin/emacs.exe
```

The runner builds an independent Win32 dynamic-module fixture. It creates the
262-UTF-16-unit, 17-byte test file directly through Windows, in the same Emacs
process, without starting a filesystem helper. The baseline check must fail
specifically at `file-exists-p`, not just with any nonzero exit status.

The converter harness extracts the **actual functions from the patched
`src/w32.c`**, then performs 80 checks: destination canaries, exact capacities,
invalid UTF-8, errno/Win32 errors, DOS/UNC namespace conversion, relative and dot
paths, supplementary Unicode, and the 32K conversion boundary.

The ERT suite checks real operations at 247/248/255/259/260/261/262/263/1024/4096
UTF-16 units, non-ASCII/emoji directories, both stat implementations, append,
ACL-preserving copy, replacement rename, hard links, normal visits/saves and both
backup strategies, native notifications, loading a long-path DLL, compiling and
loading a long-path ELN, actual GDI+ image input/output, negative cases, and trash
failure safety. Symlink integration is skipped explicitly if the short-path
permission probe fails. DLL/ELN fixture trees are removed after their processes
exit, because Windows retains loaded modules.

Logs and intermediate test binaries are in `build/w32-long-path/`.

### Verified on this checkout

- UCRT64 x64 rebuild succeeded (`emacs-31.0.91.21.exe`).
- Converter harness: 80 checks passed.
- Long-path ERT: 10 passed, 1 skipped because Windows denied creation of the
  short-path symlink permission probe (`EPERM`). No unexpected failures.
- Existing `fileio-tests.el` plus `filelock-tests.el`: 23 passed, 2 existing
  platform skips. No unexpected failures.
- Old installed binary reproduced the exact 262-unit existence-check failure;
  the patched binary also read the independently created 17-byte contents.
- Patch forward/reverse application checks passed; all 16 resulting files
  matched the tested source after normalizing Git's line endings.

## Deliberate limits

- Windows still limits individual path components and the total native path.
  UTF-8 bytes, Lisp characters and UTF-16 units must not be conflated.
- `w32-unicode-filenames = nil` remains a legacy ANSI mode; it is not silently
  upgraded to Unicode. Overlong names fail safely in that mode.
- `SHFileOperation`, used for the old recycle-bin interface, does not support
  extended paths. Long-path trash requests fail **before** chmod or deletion;
  there is no fallback to permanent deletion.
- This does not rewrite the ANSI `CreateProcessA`/cmdproxy/emacsclient protocol,
  or make arbitrary third-party libraries and child programs long-path aware.
  Their conversion failures are checked instead of proceeding with bad buffers.
- Real SMB I/O was not tested: UNC encoding/decoding is covered by converter
  tests. x64 UCRT is the built/tested configuration; x86/ARM64 manifests are
  updated, but those targets were not compiled here.

The patch is downstream/private and is not an upstream submission.
