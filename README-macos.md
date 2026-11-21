<!-- SPDX-FileCopyrightText: 2026 Chen Zhexuan -->
<!-- SPDX-License-Identifier: MIT -->
# Emacs for macOS — Apple Silicon

A separate, pinned Cocoa/NS build for **macOS 14+ / arm64**, based on upstream
Emacs **31.1.90** at `a2d49cab4db0c498cca73026e1e178503bc8eef1`.
This is a development snapshot, not an official stable GNU release. The macOS
recipe has its own patch selection and release workflow separate from Windows.

## Features and selection

- Native compilation with built-in AOT and support for compiling additional Lisp.
- Tree-sitter, SQLite, modules, GnuTLS, libxml2, SVG, WebP, PNG/JPEG/GIF/TIFF, LCMS2,
  threads, native file notifications, Cocoa rendering and native fullscreen.
- The three Emacs Plus Cocoa patches: system appearance notifications, refreshed
  NS color names, and optional rounded undecorated frames.
- Ten shared downstream correctness/performance fixes, including redisplay progress (0038),
  overlay-tail backward motion (0040), and SQLite parameter ownership (0041).
- No MPS/IGC, Xwidgets, DBus, ImageMagick, Windows-specific patches, suppressed
  compilation errors or LEIM omission. See [patch provenance](patches/macos/README.md).

The app does not impersonate Emacs Plus. `ctz-emacs-build-version` identifies its
site initialization. Existing configuration using upstream NS parameters works;
configuration explicitly checking `ns-emacs-plus-version` may need adjustment.

## Build prerequisites

Use an Apple Silicon macOS host and Python **3.11+**, Git, Apple's Xcode Command
Line Tools (or Xcode), and these Homebrew build dependencies:

```sh
brew install make autoconf automake texinfo pkg-config gcc libgccjit \
  gnutls librsvg little-cms2 tree-sitter webp sqlite jpeg giflib libpng \
  libtiff gmp zlib
```

The builder does not run `brew install`, update/uninstall anything, stop an
existing Emacs, install into `/Applications`, or use a Developer ID identity.
Current dependency versions are recorded from actual installed files and SBOMs,
not from today's `brew info` version. A new dependency with a Homebrew file patch
requires an explicitly audited URL/hash in `scripts/macos/config.json`.

The minimum OS is checked for every bundled loadable Mach-O image. Building on a
newer host with newer-only bottles must **fail**, not silently raise the package's
advertised macOS requirement. This recipe initially targets a macOS 14 host.

## Commands

```sh
# Source/patch preparation also runs on Linux for CI checks.
./emacs-build-macos.sh prepare

# Compile and install into an owned build tree, not your installed editor.
./emacs-build-macos.sh build --jobs 8

# Copy the self-contained app, bundle dependencies, collect exact dependency
# sources and license notices, relocate, audit, and ad-hoc sign.
./emacs-build-macos.sh bundle

# Test a ZIP extraction at a different path containing spaces.
./emacs-build-macos.sh verify

# Commit the recipe before producing release assets. The bundled build-info
# must refer to that same commit; rebundle/reverify after committing if needed.
./emacs-build-macos.sh archive
```

`all` runs build, bundle, verify and archive. To satisfy the committed-recipe gate,
commit recipe changes **before** using `all`. `sources` can independently retry
checksummed dependency source collection after an interrupted download.

Paths:

- `git/macos-emacs-31/`: exact upstream checkout plus selected patches.
- `build/macos/compile/`: out-of-tree build and upstream self-contained app.
- `build/macos/product/`: staged `Emacs.app`, optional sibling `Emacs Client.app`,
  and package README. This is not an installation.
- `build/macos/verification/`: owned isolated HOME, sandbox profile, extraction,
  test results and stdout/stderr. Watchdogs only kill processes they created.
- `zips/`: release ZIP, Emacs/build-recipe source archive, corresponding dependency
  source archive, public build/verification metadata and SHA-256 checksums.

Patch/selection changes require a fresh source/build tree. The builder refuses
to reset an unrecorded dirty source tree or silently skip a conflicting patch.
Keep failed logs before moving aside your owned source/build directories.

## What is self-contained?

Runtime libraries, Lisp, docs, helpers, matching dump, AOT and GCC JIT runtime/link
inputs are inside `Emacs.app`. Loader references are rewritten relative to each
image. Absolute external rpaths and unresolved/ambiguous libraries are rejected;
there is no arbitrary first-match Cellar search. All loadable images are signed
individually, followed by the app. No personal PATH is copied into Info.plist.

**Normal use and packaged AOT do not require Homebrew. Compiling new native Lisp
requires Apple's Command Line Tools for the SDK, assembler and linker.** Apple's
SDK/tools are not redistributed. The bundled site-start sets relocatable driver
options without globally setting `CC`, `LIBRARY_PATH`, or `GCC_EXEC_PREFIX`.
As usual, `-Q` skips site-start; use ordinary startup or `-q` when testing JIT.
The fonts.conf used by SVG/Pango points at macOS fonts, not a Homebrew directory.

Your config, packages, tree-sitter grammars, native Reader modules, external
programs and fonts are not bundled or modified. Finder-started Emacs gets generic
Homebrew tool directories only if present; configure other external tool paths
in your init. No shell startup files are executed just to import a PATH.

The optional `Emacs Client.app` must remain beside `Emacs.app`; its paths are
resolved on launch. It handles file-open and org-protocol AppleEvents. The CLI
programs are in `Emacs.app/Contents/MacOS/bin/`.

## Acceptance and boundaries

Portable preparation/unit tests:

```sh
python3 -m unittest discover -s scripts/macos -p 'test_*.py' -v
```

The `Test macOS recipe` GitHub workflow checks these and replays patches on the
pinned upstream source. It is **not** a macOS compilation or GUI validation job.

Full acceptance verifies a relocated ZIP extraction with:

- The original product, build, source and Homebrew paths denied by a macOS sandbox;
  an explicit negative read probe proves that the sandbox is active.
- File content, executable modes, symlinks, code signatures, architecture and
  minimum-OS checks; every non-system dynamic load stays in the extracted app.
- AOT loading with `-Q` and JIT disabled, real JIT compilation/execution, SQLite,
  libxml, module loading, process completion, and required feature availability. The SQLite
  binding checks verify that deferred statements keep the original text and BLOB values after
  the original strings are overwritten and garbage collection runs.
- Nine graphical redisplay/motion ERTs, Cocoa appearance/round-frame and image
  checks, plus a separate post-redisplay timer. No graphical skips are accepted.
- The native client launcher creates a frame in an owned, uniquely named GUI
  server, without connecting to an existing editor.
- A real HTTPS request using system CA trust, not a Cellar certificate bundle.

A separate minimal-environment GUI startup probe checks generic external-tool
PATH/exec-path setup before/after frame initialization. It runs outside the
no-Homebrew sandbox because it must observe the build host's installed tool
directories; it is not used as evidence of standalone runtime operation.

The final ZIP is copied from the **exact archive that was extracted and tested**,
not generated again after testing. Stale product identities or recipe commits
prevent archiving. Source archives omit the repository's Windows test signing key
and all ignored build/cache directories. Dependency sources include the actual
GCC/glib patches and all registry crates from librsvg's exact Cargo.lock; merely
linking to current upstream sources is not used as a substitute.

Tests do not establish compatibility with every third-party package or Reader
module, real input-method interactions, all displays/OS releases, or the Finder
client's AppleEvent behavior. Those require separate user-facing checks. This
first recipe is not a dependency/security refresh and does not promise Intel or
universal binaries.

## Signing and safe replacement

Packages are **ad-hoc signed, not notarized**. No certificate/private key is used
or distributed. After verifying SHA-256, approve the specific downloaded app via
macOS's normal Open Anyway flow if Gatekeeper blocks it; do not disable Gatekeeper
globally. A future notarized release requires an explicitly authorized personal
Developer ID identity and a separately tested signing/notarization flow.

Test the explicit new `Emacs.app/Contents/MacOS/Emacs` path first. Your Homebrew
`emacs` wrapper may prefer `/Applications/Emacs.app`, so invoking `emacs` alone
can accidentally test the old editor. Keep old/new app contents and native caches
separate. Only replace `/Applications/Emacs.app` after your own configuration and
native modules pass. Nothing in this script performs that replacement.

Release creation is deliberately separate. Publish a new macOS prerelease tag
with **all** binary, source, dependency-source, metadata and checksum assets;
do not overwrite an existing Windows release or silently mark a development,
unnotarized build as the stable latest release.
