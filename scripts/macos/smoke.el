;;; smoke.el --- Relocated macOS package checks -*- lexical-binding: t; -*-
;; SPDX-FileCopyrightText: 2026 Chen Zhexuan
;; SPDX-License-Identifier: MIT
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(setq native-comp-jit-compilation nil)

(defconst macos-smoke-root (file-name-as-directory (getenv "TEST_APP_ROOT")))
(defconst macos-smoke-state (file-name-as-directory (getenv "TEST_STATE")))

(ert-deftest macos-smoke-features ()
  (dolist (feature '(NS NATIVE_COMP TREE_SITTER SQLITE3 MODULES GNUTLS LIBXML2
                       RSVG WEBP LCMS2 PNG JPEG GIF TIFF THREADS KQUEUE))
    (should (memq feature (mapcar #'intern (split-string system-configuration-features)))))
  (should (equal emacs-version "31.1.90"))
  (should (native-comp-available-p))
  (should (treesit-available-p))
  (should (sqlite-available-p))
  (should (libxml-available-p))
  (with-temp-file (expand-file-name "runtime.json" macos-smoke-state)
    (insert (json-serialize (list :version emacs-version
                                  :features (vconcat (split-string system-configuration-features)))))))

(ert-deftest macos-smoke-runtime-paths ()
  (dolist (path (list data-directory doc-directory exec-directory))
    (should (file-in-directory-p path macos-smoke-root)))
  (should (file-readable-p (expand-file-name "DOC" doc-directory)))
  (should (file-executable-p (expand-file-name "emacsclient" (expand-file-name "Contents/MacOS/bin/" macos-smoke-root))))
  (should (cl-some (lambda (path) (file-in-directory-p path macos-smoke-root)) load-path))
  (should (cl-some (lambda (path) (file-in-directory-p path macos-smoke-root)) native-comp-eln-load-path))
  (dolist (path (append load-path native-comp-eln-load-path))
    (should-not (string-match-p "/opt/homebrew/\\|/compile/\\|/git/macos-emacs-31/" path))))

(ert-deftest macos-smoke-aot ()
  (require 'cl-seq)
  ;; JIT is disabled above; this must be the packaged AOT, not a cold-cache
  ;; compilation or a byte-code fallback from the developer's installation.
  (should (native-comp-function-p (symbol-function 'cl-remove-if-not))))

(ert-deftest macos-smoke-sqlite-and-xml ()
  (let ((db (sqlite-open)))
    (unwind-protect
        (should (equal (sqlite-select db "SELECT 6 * 7") '((42))))
      (sqlite-close db)))
  (with-temp-buffer
    (insert "<html><body>relocated</body></html>")
    (should (eq (car (libxml-parse-html-region (point-min) (point-max))) 'html))))

(ert-deftest macos-smoke-module ()
  (module-load (expand-file-name "module-probe.dylib" macos-smoke-state))
  (should (= (ctz-macos-module-probe) 42)))

(ert-deftest macos-smoke-process ()
  (let ((buffer (generate-new-buffer " *macos process probe*"))
        (status nil))
    (unwind-protect
        (let ((process
               (make-process :name "owned-macos-smoke" :buffer buffer :noquery t
                             :command '("/bin/sh" "-c" "printf 'final-output'; exit 7")
                             :sentinel (lambda (process _event)
                                         (when (memq (process-status process) '(exit signal))
                                           (setq status (process-exit-status process)))))))
          (let ((end (+ (float-time) 10)))
            (while (and (not status) (< (float-time) end))
              (accept-process-output process 0.05)))
          (should (equal status 7))
          (should (equal (with-current-buffer buffer (buffer-string)) "final-output")))
      (kill-buffer buffer))))

(ert-deftest macos-smoke-jit ()
  (should (featurep 'ctz-emacs-build))
  (let ((source (expand-file-name "native-probe.el" macos-smoke-state)))
    (with-temp-file source
      (insert ";;; -*- lexical-binding: t; -*-\n"
              "(defun ctz-macos-native-probe (x) (+ x 2))\n"))
    (let ((eln (native-compile source)))
      (should (file-exists-p eln))
      (load eln nil t)
      (should (native-comp-function-p (symbol-function 'ctz-macos-native-probe)))
      (should (= (ctz-macos-native-probe 40) 42)))))

(ert-deftest macos-smoke-gui-appearance-and-colors ()
  (skip-unless (display-graphic-p))
  (should (memq ns-system-appearance '(light dark)))
  (should (boundp 'ns-system-appearance-change-functions))
  (should (> (length x-colors) 500))
  (let ((old (frame-parameter nil 'ns-appearance)))
    (unwind-protect
        (dolist (appearance '(dark light))
          (set-frame-parameter nil 'ns-appearance appearance)
          (redisplay t)
          (should (eq (frame-parameter nil 'ns-appearance) appearance)))
      (set-frame-parameter nil 'ns-appearance old)))
  (let ((old (frame-parameter nil 'undecorated-round)))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'undecorated-round t)
          (redisplay t)
          (should (frame-parameter nil 'undecorated-round)))
      (set-frame-parameter nil 'undecorated-round old))))

(ert-deftest macos-smoke-gui-images ()
  (skip-unless (display-graphic-p))
  (dolist (pair '(("black.webp" . webp) ("blank-100x200.png" . png)))
    (let ((image (create-image (expand-file-name (car pair) macos-smoke-state) (cdr pair))))
      (should (> (car (image-size image t)) 0))))
  (let ((image (create-image "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8' fill='red'/></svg>" 'svg t)))
    (should (equal (image-size image t) '(8 . 8)))))

(provide 'ctz-macos-smoke)
;;; smoke.el ends here
