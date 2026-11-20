<!-- SPDX-FileCopyrightText: 2026 Chen Zhexuan -->
<!-- SPDX-License-Identifier: MIT -->
# macOS Emacs 31 patch selection

Base: upstream `a2d49cab4db0c498cca73026e1e178503bc8eef1`, Emacs 31.1.90.
`upstream-31.series` uses repository-root-relative paths and is independent of
`patches/emacs/upstream-31.series` (the Windows selection).

## Shared fixes

Unchanged payloads: 0004, 0010, 0012, 0016, 0019, 0030, 0032, 0038, 0040.
These cover tab-bar highlighting, quickstart startup, minor-mode documentation,
GC roots, collapsed minor-mode keymap allocation, dead minibuffer error loops,
use-package custom-face handling, redisplay progress and overlay-tail motion.

No Windows process, timer, IME, long-path or title-bar patches are selected.
The Windows compile-error suppression (0001), LEIM/dictionary omission (0008),
and native-comp retry policy (0025) are intentionally not selected. The macOS
build retains LEIM/dictionary generation and fails on compilation errors.

## Emacs Plus provenance

The three Cocoa patches come from
[d12frosted/homebrew-emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus/tree/4522d6c0e8fe52b76a0ea37b676ae54b2accc7b9/patches/emacs-31),
revision `4522d6c0e8fe52b76a0ea37b676ae54b2accc7b9`, matching the formula used
by the inspected Emacs Plus 31.0.91 installation. Original authorship is retained.
The repository's MIT notice is in `emacs-plus-LICENSE`. The modifications to GNU
Emacs remain subject to Emacs's GPL; the builder's MIT license does not relicense
the patched editor.

| Patch | Original SHA-256 | Changes here |
| --- | --- | --- |
| fix-ns-x-colors | `9e5d3e26a8d388d3a000b697d582769645ca93ad597b4113744deba4b89a8b9e` | None |
| system-appearance | `53283503db5ed2887e9d733baaaf80f2c810e668e782e988bda5855a0b1ebeb4` | Rebase two hunk contexts around upstream sleep/wake notification code; no payload logic change |
| round-undecorated-frame | `c9430a1ead81e313b3d2877ff6f8044fb29441eecc7cc42000515d7c8ec6380f` | None |

The rebased appearance patch SHA-256 is
`d5df0e0c09461219973913b147654e2c37ec3ed82b8039caa5b0002925a13b57`.
It provides `ns-system-appearance` and its change hook. The round-frame patch
provides `undecorated-round`; it is available but not enabled by default.

Ordinary `ns-transparent-titlebar`, `ns-appearance`, Command/Option modifier
mapping, native fullscreen and Cocoa input are already upstream capabilities.
This build is the upstream Cocoa/NS port, not the separate Emacs Mac port; it
does not add the Mac port's `mac-input-source` primitives.

The exact patch order and hashes are embedded in each package. Preparation
errors are fatal. Before bundling, affected source files are reconstructed from
the pinned Git base and all selected payloads and compared byte-for-byte with
the compiled checkout. No patch is silently skipped as supposedly upstreamed.
