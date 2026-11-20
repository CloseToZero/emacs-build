GNU Emacs 31.1.90 — CloseToZero downstream macOS build

Requires Apple Silicon and macOS 14 or newer. This is a development Emacs
snapshot, not an official stable GNU release.

Copy Emacs.app to a location of your choice. Do not merge its contents with
another Emacs installation. Keep an existing editor until this build has been
tested with your configuration. Emacs Client.app is optional; keep it beside
Emacs.app. It uses the sibling app and handles files and org-protocol URLs.

Command-line programs are in Emacs.app/Contents/MacOS/bin. Invoke the explicit
Emacs.app/Contents/MacOS/Emacs path when testing; an existing Homebrew emacs
wrapper may still select /Applications/Emacs.app first.

Homebrew is not required. Runtime libraries and built-in native Lisp (AOT) are
bundled. Compiling additional native Lisp requires Apple's Xcode Command Line
Tools for its SDK, assembler and linker. Install CLT with xcode-select --install
if desired. This package supplies GCC's runtime/JIT components, not Apple's SDK.
Site initialization configures native-comp driver paths at runtime. As usual,
-Q skips site-start.el; use ordinary startup or -q for native-compilation tests.

This package is ad-hoc signed and NOT notarized. Gatekeeper may block a download.
After verifying the published SHA-256, use macOS's normal per-app Open Anyway
approval in Privacy & Security. Do not disable Gatekeeper globally.

Your user configuration, packages, tree-sitter grammars, fonts, Reader modules
and external tools are not included or changed. Do not share compiled native
Lisp caches between incompatible Emacs builds. Additional tools may need PATH
configuration; no developer's personal PATH or configuration is embedded.

Build/patch identity: Emacs.app/Contents/Resources/build-info.json
Licenses and exact dependency recipes: Emacs.app/Contents/Resources/licenses
Corresponding source and checksums are published alongside the binary package.

https://github.com/CloseToZero/emacs-build
