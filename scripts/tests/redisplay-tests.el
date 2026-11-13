;;; redisplay-tests.el --- Downstream graphical redisplay regressions -*- lexical-binding: t; -*-
;; SPDX-FileCopyrightText: 2026 Chen Zhexuan
;; SPDX-License-Identifier: MIT

(setq native-comp-jit-compilation nil)
(require 'cl-lib)
(require 'ert)
(require 'image)
(defvar redisplay-tests-root (getenv "REDISPLAY_TEST_STATE"))

(defun redisplay-tests--mark (text)
  "Record completed native display boundaries without triggering echo redisplay."
  (write-region (concat text "\n") nil
                (expand-file-name "progress.log" redisplay-tests-root) t 'silent))

(defmacro redisplay-tests--with-window (&rest body)
  (declare (indent 0))
  `(save-window-excursion
     (let ((buffer (generate-new-buffer " *private redisplay*"))
           (upper (generate-new-buffer " *private redisplay upper*")))
       (unwind-protect
           (progn
             (delete-other-windows)
             (switch-to-buffer upper)
             (let ((window (split-window-below -20)))
               (set-window-buffer window buffer)
               (select-window window))
             (text-mode)
             (setq-local scroll-conservatively 101
                         header-line-format "Private redisplay regression")
             (visual-line-mode 1)
             ,@body)
         (kill-buffer buffer)
         (kill-buffer upper)))))

(defun redisplay-tests--picture ()
  "Return a synthetic tall image, independent of user files and codecs."
  (create-image "P1\n2 2\n0 0\n0 0\n" 'pbm t :scale 95 :ascent 'center))

(defun redisplay-tests--sweep (label)
  "Resize the selected window through partial-row boundaries for LABEL."
  (let ((window-resize-pixelwise t))
    (cl-loop for height from 150 to 400 do
             (window-resize nil (- height (window-pixel-height)) nil nil t)
             (redisplay-tests--mark (format "%s before %d body=%d" label height
                                            (window-body-height nil t)))
             (redisplay t)
             (redisplay-tests--mark (format "%s after %d" label height)))))

(ert-deftest redisplay-tests-empty-prefix ()
  (skip-unless (display-graphic-p))
  (redisplay-tests--with-window
    (let ((overlay (make-overlay (point-min) (point-min))))
      (overlay-put overlay 'priority 1)
      (overlay-put overlay 'before-string
                   (concat "Images\n" (propertize " " 'display (redisplay-tests--picture))
                           " [Image] [Remove]\n\n"))
      (redisplay-tests--sweep "empty")
      (should (= (point) (point-min)))
      (should (zerop (buffer-size)))
      (should (= scroll-conservatively 101)))))

(ert-deftest redisplay-tests-nonempty-prefix-anchor ()
  (skip-unless (display-graphic-p))
  (redisplay-tests--with-window
    (insert "Draft text\nSecond line")
    (goto-char (point-min))
    (let ((overlay (make-overlay (point-min) (point-min))))
      (overlay-put overlay 'before-string
                   (concat "Images\n" (propertize " " 'display (redisplay-tests--picture))
                           " [Image]\n\n"))
      (redisplay-tests--sweep "anchor")
      (should (= (point) (point-min)))
      (goto-char (point-max))
      (redisplay-tests--sweep "after-prefix")
      (should (= (point) (point-max))))))

(ert-deftest redisplay-tests-inline-tall-row ()
  (skip-unless (display-graphic-p))
  (redisplay-tests--with-window
    (insert (propertize " " 'display (redisplay-tests--picture)) "\nAfter")
    (goto-char (point-min))
    (let ((overlay (make-overlay (point-min) (point-min))))
      (overlay-put overlay 'before-string "Prefix\n")
      (redisplay-tests--sweep "inline-tall")
      (should (= (window-start) (point-min)))
      (delete-overlay overlay))))

(ert-deftest redisplay-tests-top-vscroll ()
  (skip-unless (display-graphic-p))
  (redisplay-tests--with-window
    (insert (propertize " " 'display (redisplay-tests--picture)) "\nAfter")
    (goto-char (point-min))
    (let ((window-resize-pixelwise t))
      (window-resize nil (- 150 (window-pixel-height)) nil nil t))
    (set-window-start nil (point-min))
    (redisplay t)
    (set-window-vscroll nil 10 t)
    (redisplay t)
    (should (= (window-start) (point-min)))
    (should (> (window-vscroll nil t) 0))))

(ert-deftest redisplay-tests-ordinary-scrolling-and-hook ()
  (skip-unless (display-graphic-p))
  (redisplay-tests--with-window
    (dotimes (n 100)
      (let ((start (point)))
        (insert (format "Line %d " n)
                (make-string (* 2 (window-body-width)) ?x) "\n")
        (when (zerop (% n 3))
          (put-text-property start (point) 'face '(:height 1.5)))))
    (dolist (policy '(1 100 101))
      (dolist (margin '(0 2))
        (setq-local scroll-conservatively policy scroll-margin margin)
        (goto-char (point-min))
        (set-window-start nil (point-min))
        (dotimes (_ 70)
          (forward-line 1)
          (redisplay t)
          (should (pos-visible-in-window-p (point))))))
    (setq-local scroll-conservatively 101 scroll-margin 0)
    (goto-char (point-min))
    (set-window-start nil (point-min))
    (forward-line 30)
    (let ((calls 0) adjusted)
      (add-hook 'window-scroll-functions
                (lambda (window _start)
                  (cl-incf calls)
                  (unless adjusted
                    (setq adjusted t)
                    (set-window-start window (point) t))) nil t)
      (redisplay t)
      (should (> calls 0))
      (should (pos-visible-in-window-p (point))))))

(setq frame-title-format "ISOLATED native redisplay tests"
      inhibit-startup-screen t)
(set-face-attribute 'default nil :family "IBM Plex Mono" :height 120)
(set-frame-parameter nil 'fullscreen 'maximized)
(run-at-time
 1 nil
 (lambda ()
   (let ((stats (ert-run-tests-batch (or (getenv "REDISPLAY_TEST_SELECTOR")
                                       "^redisplay-tests-"))))
     (with-temp-file (expand-file-name "ert.log" redisplay-tests-root)
       (insert (with-current-buffer "*Messages*" (buffer-string))))
     (if (or (zerop (ert-stats-total stats))
             (> (ert-stats-skipped stats) 0)
             (> (ert-stats-completed-unexpected stats) 0))
         (kill-emacs 1)
       (run-at-time 0.05 nil
                    (lambda ()
                      (redisplay-tests--mark "post-redisplay timer serviced")
                      (kill-emacs 0)))))))
