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

The series contains 25 unchanged existing payloads plus downstream patches 0038 through 0040,
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
- 0040: start the backward screen-line search before an inaccessible tail row when
  reseating on it would jump to the same end position. This lets repeated and counted
  motions leave a virtual tail while preserving the wrapped-line scan.
  See the [graphical redisplay checks](../scripts/tests/README-redisplay.md).

The long-path and timer contracts and tests are documented in
[`README-w32-long-path.md`](../scripts/tests/README-w32-long-path.md) and
[`README-ime.md`](../scripts/tests/README-ime.md). Their earlier results are not acceptance results
for a new binary. Validate the actual newly packaged and relocated executable and matching dump.

## Removed incompatible fork patches

Eleven unselected patch files were byte-identical to the public `kiennq/emacs-build` fork's
committed payloads ([`6c61c95`](https://github.com/kiennq/emacs-build/commit/6c61c95) and
[`b85158f`](https://github.com/kiennq/emacs-build/commit/b85158f)). None contained local edits.
They failed sequential application checks on the pinned `a2d49cab` base and were not part of the
effective previous build on `769bd892`. They were removed from the active patch directory;
all 28 selected payloads remain unchanged. The filenames are recoverable from Git history.

| Patches | Why removed from this recipe |
| --- | --- |
| 0002, 0003, 0006, 0020, 0031 | Require fork-specific IGC/MPS sources absent from this target. |
| 0005, 0018 | Experimental text-index and Windows caching bundles conflict with the pinned source. |
| 0021, 0022 | The fork's Windows emacsclient signal implementation and follow-up do not apply. |
| 0024 | Hook deletion conflicts; selected 0023 still disables hook installation. |
| 0028 | Info-generation change conflicts; clean top-level Info generation was verified separately. |

This does not declare the patches obsolete for their original fork target. A new failure in a
selected payload stops preparation and requires investigation; it is not a reason to skip it.
