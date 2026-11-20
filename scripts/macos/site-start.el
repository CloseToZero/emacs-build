;;; site-start.el --- Relocatable macOS distribution setup -*- lexical-binding: t; -*-
;; SPDX-FileCopyrightText: 2026 Chen Zhexuan
;; SPDX-License-Identifier: MIT

(require 'subr-x)

(defconst ctz-emacs-build-version "31.1.90"
  "Upstream version of this downstream distribution.")

;; `load-file-name' is inside Contents/Resources/site-lisp. Do not bake a
;; developer's PATH, Cellar, source directory, or SDK location into the app.
(let* ((contents (expand-file-name "../../" (file-name-directory load-file-name)))
       (toolchain (expand-file-name "Toolchain/" contents))
       (bin (expand-file-name "bin/" toolchain))
       (libraries (expand-file-name "lib/" toolchain))
       (frameworks (expand-file-name "Frameworks/" contents)))
  (unless (getenv "FONTCONFIG_FILE")
    (setenv "FONTCONFIG_FILE" (expand-file-name "Resources/fonts.conf" contents)))
  (defvar native-comp-driver-options nil)
  (dolist (flag (list (concat "-B" bin)
                     (concat "-L" libraries)
                     (concat "-L" frameworks)))
    (add-to-list 'native-comp-driver-options flag t))
  ;; An Apple SDK and Apple's assembler/linker are supplied by Xcode Command
  ;; Line Tools, not redistributed. Packaged AOT needs neither CLT nor Homebrew.
  (when (file-executable-p "/usr/bin/xcrun")
    (with-temp-buffer
      (when (zerop (call-process "/usr/bin/xcrun" nil t nil "--show-sdk-path"))
        (let ((sdk (string-trim (buffer-string))))
          (when (file-directory-p sdk)
            (dolist (flag (list "-isysroot" sdk))
              (add-to-list 'native-comp-driver-options flag t))))))))

;; Finder does not inherit a login shell's PATH. These are generic tool
;; locations, never a snapshot of the builder's personal environment.
(when (display-graphic-p)
  (dolist (directory '("/opt/homebrew/bin" "/usr/local/bin"))
    (when (and (file-directory-p directory) (not (member directory exec-path)))
      (setq exec-path (append exec-path (list directory)))
      (setenv "PATH" (concat (or (getenv "PATH") "") ":" directory)))))

(provide 'ctz-emacs-build)
;;; site-start.el ends here
