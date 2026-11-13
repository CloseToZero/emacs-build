<!-- SPDX-FileCopyrightText: 2026 Chen Zhexuan -->
<!-- SPDX-License-Identifier: MIT -->
# Upstream Emacs 31 Windows patch selection

`emacs/upstream-31.series` preserves the effective patch set of the previous x64 UCRT64 release,
with native compilation enabled and MPS disabled. It was checked on upstream revision
`a2d49cab4db0c498cca73026e1e178503bc8eef1` (2026-11-12). That revision includes the tall-image
redisplay fix `9e5d32b597f4361951b7af84a5895267af48ea5a`.

Apply the series to a fresh checkout with `--patch-series patches/emacs/upstream-31.series` during
`--clone`. A selected patch failure is fatal. The source revision and complete patch payloads must
be recorded with a package; a successful compiler exit is not proof that private fixes were applied.
Run `bash scripts/tests/test-patches.sh` to check selection, order, failure propagation and CRLF input.

## Retained behavior

The series contains 25 unchanged existing payloads plus downstream patches 0038 and 0039,
in dependency order.
In particular, it retains:

- 0033 and 0034: title-bar visibility control and captionless maximized-window work-area handling.
- 0035: process status notifications and Windows wait wakeups.
- 0036: windowless thread-timer dispatch, including the earlier Weasel indicator correction.
- 0037: extended-length Windows file I/O, checked filename conversions, watches, DLL/native-Lisp
  loading and image paths. Its ARM64 manifest dependency is supplied by selected patch 0015;
  no manifest hunk is silently dropped for the x64 build.
- Applicable inherited correctness, input/startup and build policies from the previous release.
  Native compilation retries remain, but final package validation must reject incomplete output.
- 0038: stop a partial-cursor retry when the post-hook window start is already point and the
  existing forced-visibility phase has ended. This fixes an unscrollable multiline display prefix
  without disabling conservative scrolling or changing image/Agent-specific behavior. See the
  [graphical redisplay checks](../scripts/tests/README-redisplay.md).
- 0039: reserve retired Windows readers and their descriptors until actual thread exit, with
  nonblocking reclamation and independent retirement. Reselect after 0035's callbacks instead
  of consuming stale readiness, while retaining its prompt idle-completion behavior. See the
  [pipe lifecycle checks](../scripts/tests/README-w32-pipes.md).

The long-path and timer contracts and tests are documented in
[`README-w32-long-path.md`](../scripts/tests/README-w32-long-path.md) and
[`README-ime.md`](../scripts/tests/README-ime.md). Their earlier results are not acceptance results
for a new binary. Validate the actual newly packaged and relocated executable and matching dump.

## Unselected inherited patches

The previous builder ignored patch failures. Sequential index-only checks against its recorded
base, `769bd89281062bcf19fcb7985051b06fb0c0849b`, found that these 11 patches did not apply there
either. The selected existing patches do not silently lose behavior present in that recorded build;
0038 and 0039 are additional downstream fixes.

| Patches | Scope and disposition |
| --- | --- |
| 0002, 0003, 0006, 0020 | IGC/MPS or fork-specific prerequisites are absent from this upstream/MPS-off target. |
| 0005 | Experimental marker/text-index changes conflict with this source line; not part of the effective previous release. |
| 0018 | Broad Windows caching/performance bundle conflicts as a whole; not part of the effective previous release. |
| 0021, 0022 | Fork-specific emacsclient signal implementation and its dependent repair did not apply to the previous upstream base. |
| 0024 | Hook deletion conflicts with the source tree; selected 0023 still disables hook installation. |
| 0028 | The inherited Info-generation patch did not apply to the recorded previous base; verify clean documentation generation separately. |
| 0031 | The mixed IGC/thread-wait patch did not apply to the recorded previous base. Ordinary process/file-notification tests still matter with MPS disabled. |

These findings do not prove that every idea in an unselected patch is obsolete or already upstream.
The patch files remain available for separately reviewed fork targets. A new conflict in a selected
patch requires investigation, not a change to this list merely to make the build pass.
