<!-- SPDX-FileCopyrightText: 2026 Chen Zhexuan -->
<!-- SPDX-License-Identifier: MIT -->
# Graphical redisplay regression

Patch `0038-Stop-retrying-unscrollable-display-prefix.patch` fixes a conservative-scrolling retry
that cannot make progress when a multiline display prefix leaves the cursor row partially visible
and the effective window start is already point. It returns to the existing fallback only after
the normal forced-visibility phase. The global scrolling preference is not changed.

The existing upstream tall-image fix does not cover this prefix case. The new test uses a tiny
synthetic PBM scaled for display, not a user's clipboard or screenshot, and has no Agent dependency.
It requires a real graphical Emacs and uses an external timeout because a native redisplay loop
cannot reliably be interrupted by a Lisp timeout or C-g.

From PowerShell at the build-repository root:

```powershell
./scripts/tests/test-redisplay.ps1

# Test the actual packaged executable too.
./scripts/tests/test-redisplay.ps1 -Emacs ./pkg/emacs-31-mingw-w64-ucrt-x86_64_full/bin/emacs.exe

# A focused baseline check; an affected binary times out in this test.
./scripts/tests/test-redisplay.ps1 -Emacs C:/baseline/bin/emacs.exe `
  -Selector '^redisplay-tests-empty' -TimeoutSeconds 20
```

The runner starts an owned graphical process with disposable HOME, application state, temporary
files and an explicit init directory. Its watchdog terminates only that process. It never attaches
to an existing editor. Logs remain under `build/redisplay-tests/<unique-run>/`.

Five ERT cases exercise:

- Empty-buffer prefixes, including point at the buffer end.
- Nonempty prefixes, both at their anchor and after the prefix.
- Inline tall rows preceded by a display-only prefix, through below/equal/above-window geometries.
- A first row clipped by positive pixel vscroll, retaining the existing top-clipping behavior.
- Ordinary wrapped, variable-height text under policies 1, 100 and 101, zero/nonzero scroll margins,
  and a benign scroll hook that adjusts the start once.

The height sweeps test 150 through 400 total window pixels, including partial-row boundaries.
Successful ERT completion is followed by a separate timer callback, proving that the event loop
continues after redisplay. No skipped graphical cases are accepted as a passing run.

This does not guarantee termination of arbitrary mutating Lisp scroll hooks, make an arbitrarily
large display prefix fit into a small input window, or replace viewport-specific layout design.
