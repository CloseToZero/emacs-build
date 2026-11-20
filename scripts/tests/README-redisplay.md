<!-- SPDX-FileCopyrightText: 2026 Chen Zhexuan -->
<!-- SPDX-License-Identifier: MIT -->
# Graphical redisplay and screen-line motion regressions

Patch `0038-Stop-retrying-unscrollable-display-prefix.patch` fixes a conservative-scrolling retry
that cannot make progress when a multiline display prefix leaves the cursor row partially visible
and the effective window start is already point. It returns to the existing fallback only after
the normal forced-visibility phase. The global scrolling preference is not changed.

The existing upstream tall-image fix does not cover this prefix case. The new test uses a tiny
synthetic PBM scaled for display, not a user's clipboard or screenshot, and has no Agent dependency.
It requires a real graphical Emacs and uses an external timeout because a native redisplay loop
cannot reliably be interrupted by a Lisp timeout or C-g.

Patch `0040-Keep-backward-screen-line-motion-past-overlay-tails.patch` also requires graphical
redisplay. A trailing `display ""` replacement followed by a newline-bearing `after-string`
can absorb the previous-line candidate at the end of a buffer. The fix uses the preceding
raw line boundary before counting steps and preserves the screen-line scan for wrapped source.
The reproduction uses only ordinary Emacs buffers and overlays; it needs neither Evil nor Agent.

From PowerShell at the build-repository root:

```powershell
./scripts/tests/test-redisplay.ps1

# Test the actual packaged executable too.
./scripts/tests/test-redisplay.ps1 -Emacs ./pkg/emacs-31-mingw-w64-ucrt-x86_64_full/bin/emacs.exe

# A focused baseline check; an affected binary times out in this test.
./scripts/tests/test-redisplay.ps1 -Emacs C:/baseline/bin/emacs.exe `
  -Selector '^redisplay-tests-empty' -TimeoutSeconds 20

# An affected executable also fails to move away from the overlay tail.
./scripts/tests/test-redisplay.ps1 -Emacs C:/baseline/bin/emacs.exe `
  -Selector '^redisplay-tests-backward-motion-'
```

The runner starts an owned graphical process with disposable HOME, application state, temporary
files and an explicit init directory. Its watchdog terminates only that process. It never attaches
to an existing editor. Logs remain under `build/redisplay-tests/<unique-run>/`.

The conservative-scrolling cases exercise:

- Empty-buffer prefixes, including point at the buffer end.
- Nonempty prefixes, both at their anchor and after the prefix.
- Inline tall rows preceded by a display-only prefix, through below/equal/above-window geometries.
- A first row clipped by positive pixel vscroll, retaining the existing top-clipping behavior.
- Ordinary wrapped, variable-height text under policies 1, 100 and 101, zero/nonzero scroll margins,
  and a benign scroll hook that adjusts the start once.

The height sweeps test 150 through 400 total window pixels, including partial-row boundaries.
Successful ERT completion is followed by a separate timer callback, proving that the event loop
continues after redisplay. No skipped graphical cases are accepted as a passing run.
The motion cases check a virtual tail with one, several, or wrapped display rows, the actual
Previous Line command, counted motion, a wrapped preceding source line, narrowing and genuine
buffer edges.

This does not guarantee termination of arbitrary mutating Lisp scroll hooks, make an arbitrarily
large display prefix fit into a small input window, or replace viewport-specific layout design.
