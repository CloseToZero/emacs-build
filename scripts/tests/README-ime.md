# W32 thread timer / IME indicator fix

Patch: `patches/emacs/0036-Dispatch-W32-thread-timer-callbacks.patch`.
It is applied to the current `git/emacs-31` checkout and included in the
normal `patches/emacs/*.patch` sequence for future source preparation.
The existing `--build` action alone does not apply new patch files.

## Change and evidence

`w32_msg_pump` used to consume every message with `hwnd == NULL` as an
Emacs thread message, silently discarding `WM_TIMER`. Windows requires
`DispatchMessage` to execute a timer's `TIMERPROC`, including windowless
timers. The patch routes `WM_TIMER` through the existing A/W dispatch
branch, retaining the nested-loop completion check and custom-message
handling. It does not change keyboard translation or IME conversion mode.

References:
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
- https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-dispatchmessagew
- https://github.com/rime/weasel/issues/1284

The user confirmed that the patched build resolves the Weasel taskbar
indicator synchronization problem on their machine. The timer regression
test independently verifies the message-pump fix; the internal Windows/TSF
call path has not been traced.

## Validation (2026-09-05)

- Built `src/emacs.exe` and its matching `emacs.pdmp` with the existing UCRT64
  build configuration.
- Patch passes forward check against the checkout's index and reverse
  check against the patched source.
- A native test module installs a hook in its own Emacs process to create
  a real windowless timer on the GUI thread. It does not replace or emulate
  Emacs's message loop.
- Existing packaged Emacs: timer created, callback lost (result 1, exit 1).
- Patched build: callback executed once (result 2, exit 0).
- User confirmed the original Weasel indicator symptom is resolved.

Run from the build repository in PowerShell:

```powershell
./scripts/tests/test-w32-thread-timer.ps1
# Expected failure on the previous packaged executable:
./scripts/tests/test-w32-thread-timer.ps1 -Emacs pkg/emacs-31-mingw-w64-ucrt-x86_64/bin/emacs.exe
```

The regression probe briefly starts its own clean GUI Emacs and exits it.

## Check the original symptom

```powershell
./scripts/test-ime.ps1
```

This starts the patched build with `-Q` and the UCRT64 DLL search path.
Select Weasel in the new window; check Chinese input, repeated Shift
switches, the taskbar indicator, clicking that indicator, and switching
between this window and another application. Also check Microsoft Pinyin.
Existing running Emacs instances and installed packages were not replaced.

To rebuild after further source changes:

```powershell
./scripts/msys2.cmd -c 'make -C build/emacs-31-mingw-w64-ucrt-x86_64/src -j8'
```

To revert just this source change, use `git apply -R` with patch 0036 from
`git/emacs-31`, remove patch 0036 from the active patch directory, and
rebuild. Preserve the other local patches.
