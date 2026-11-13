;;; w32-pipe-tests.el --- Windows pipe retirement and completion -*- lexical-binding: t; -*-
;; SPDX-FileCopyrightText: 2026 Chen Zhexuan
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(module-load (getenv "EMACSBUILD_PIPE_MODULE"))

(defun emacsbuild-pipe--await (predicate)
  "Wait for an observable fixture PREDICATE, with a diagnostic deadline."
  (let ((deadline (+ (float-time) 5)))
    (while (not (funcall predicate))
      (when (> (float-time) deadline) (ert-fail "Pipe event did not arrive"))
      (accept-process-output nil 0.01))))

(ert-deftest emacsbuild-pipe-retired-reader-cannot-publish-to-replacement ()
  (let (old old-writer replacement writer warm received)
    (unwind-protect
        (progn
          (setq old (make-pipe-process
                     :name "retiring-reader" :noquery t :coding 'utf-8-unix
                     :filter (lambda (_pipe text) (setq warm (concat warm text)))))
          (setq old-writer (emacsbuild-pipe-hold old))
          (emacsbuild-pipe-write old-writer "warm\n")
          (emacsbuild-pipe--await (lambda () (equal warm "warm\n")))
          ;; Queue the next read with its writer deliberately retained. The external
          ;; runner, not a Lisp timer, bounds any native synchronous-I/O regression.
          (accept-process-output old 0.05)
          (delete-process old)
          (setq replacement
                (make-pipe-process
                 :name "replacement-reader" :noquery t :coding 'utf-8-unix
                 :filter (lambda (_pipe text) (setq received (concat received text)))))
          (setq writer (emacsbuild-pipe-hold replacement))
          (accept-process-output replacement 0.05)
          ;; A late completion belongs to the retired context, never its replacement.
          (emacsbuild-pipe-write old-writer "late\n")
          (emacsbuild-pipe-close old-writer)
          (accept-process-output replacement 0.1)
          (should (process-live-p replacement))
          (should-not received)
          (emacsbuild-pipe-write writer "fresh\n")
          (emacsbuild-pipe--await (lambda () (equal received "fresh\n"))))
      (when old-writer (emacsbuild-pipe-close old-writer))
      (when writer (emacsbuild-pipe-close writer))
      (dolist (pipe (list old replacement))
        (when (process-live-p pipe) (delete-process pipe))))))

(ert-deftest emacsbuild-pipe-status-callback-invalidates-ready-data ()
  (let (pipe writer child received sentinel
        (program (getenv "EMACSBUILD_PIPE_CHILD")))
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "callback-readable" :noquery t :coding 'utf-8-unix
                      :filter (lambda (_pipe text) (setq received (concat received text)))))
          (setq writer (emacsbuild-pipe-hold pipe))
          (accept-process-output pipe 0.05)
          (setq child
                (make-process
                 :name "callback-exit" :command (list program "silent")
                 :connection-type 'pipe :noquery t
                 :sentinel
                 (lambda (process _event)
                   (when (eq (process-status process) 'exit)
                     (emacsbuild-pipe--await (lambda () (equal received "ready\n")))
                     (delete-process pipe)
                     (emacsbuild-pipe-close writer)
                     (setq pipe (make-pipe-process
                                 :name "callback-replacement" :noquery t :coding 'utf-8-unix
                                 :filter (lambda (_pipe text)
                                           (setq received (concat received text)))))
                     (setq writer (emacsbuild-pipe-hold pipe))
                     (setq sentinel t)))))
          (emacsbuild-pipe-write writer "ready\n")
          ;; Observe OS exit without dispatching Lisp; exit and pipe data are then
          ;; available together when Emacs next selects its descriptors.
          (emacsbuild-pipe-wait-child (process-id child))
          (emacsbuild-pipe--await (lambda () sentinel))
          (should (process-live-p pipe))
          (emacsbuild-pipe-write writer "after\n")
          (emacsbuild-pipe--await (lambda () (equal received "ready\nafter\n"))))
      (when writer (emacsbuild-pipe-close writer))
      (dolist (process (list child pipe))
        (when (process-live-p process) (delete-process process))))))

(ert-deftest emacsbuild-pipe-separate-stderr-completes-without-user-input ()
  (dotimes (_ 64)
    (let (child stderr output errors done)
      (unwind-protect
          (progn
            (setq stderr (make-pipe-process
                          :name "completion-stderr" :noquery t :coding 'utf-8-unix
                          :filter (lambda (_pipe text) (setq errors (concat errors text)))))
            (setq child
                  (make-process
                   :name "completion-child"
                   :command (list (getenv "EMACSBUILD_PIPE_CHILD") "output")
                   :connection-type 'pipe :noquery t :stderr stderr :coding 'utf-8-unix
                   :filter (lambda (_child text) (setq output (concat output text)))
                   :sentinel (lambda (process _event)
                               (when (eq (process-status process) 'exit) (setq done t)))))
            (emacsbuild-pipe--await (lambda () (and done (equal errors "stderr-complete\n"))))
            (should (equal output "stdout-complete\n"))
            (should (zerop (process-exit-status child))))
        (dolist (process (list child stderr))
          (when (process-live-p process) (delete-process process)))))))

(defun emacsbuild-pipe--churn (count)
  "Create and retire COUNT reader generations, releasing every writer."
  (dotimes (_ count)
    (let ((pipe (make-pipe-process :name "reader-reuse" :noquery t :filter #'ignore))
          writer)
      (unwind-protect
          (progn
            (setq writer (emacsbuild-pipe-hold pipe))
            (delete-process pipe)
            (emacsbuild-pipe-close writer)
            (accept-process-output nil 0.001))
        (when writer (emacsbuild-pipe-close writer))
        (when (process-live-p pipe) (delete-process pipe))))))

(ert-deftest emacsbuild-pipe-reclaims-retired-readers-beyond-slot-capacity ()
  (emacsbuild-pipe--churn 64)
  (let ((small (emacsbuild-pipe-handle-count)))
    ;; Exceed the existing Windows child table's capacity through sequential reuse.
    (emacsbuild-pipe--churn 1100)
    (let ((large (emacsbuild-pipe-handle-count)))
      (princ (format "Pipe handles after 64/1164 generations: %d/%d\n" small large))
      ;; Allow two just-retired pipe owners, not growth proportional to generations.
      (should (<= large (+ small 16))))))

(ert-deftest emacsbuild-pipe-startup-failure-preserves-next-reader ()
  (dotimes (_ 16)
    (should-error (make-process :name "missing-child" :noquery t
                                :command (list (expand-file-name "missing-pipe-fixture.exe"
                                                                 (getenv "HOME"))))
                  :type 'file-error))
  (let (pipe writer received)
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "after-startup-failure" :noquery t
                      :filter (lambda (_pipe text) (setq received text))))
          (setq writer (emacsbuild-pipe-hold pipe))
          (emacsbuild-pipe-write writer "next")
          (emacsbuild-pipe--await (lambda () (equal received "next"))))
      (when writer (emacsbuild-pipe-close writer))
      (when (process-live-p pipe) (delete-process pipe)))))

(ert-deftest emacsbuild-pipe-socket-retirement-preserves-replacements ()
  (dotimes (_ 32)
    (let (server client accepted received)
      (unwind-protect
          (progn
            (setq server
                  (make-network-process
                   :name "retirement-server" :host "127.0.0.1" :family 'ipv4
                   :service t :server t :noquery t
                   :log (lambda (_server peer _event) (push peer accepted))
                   :filter (lambda (peer text) (process-send-string peer text))))
            (setq client
                  (make-network-process
                   :name "retirement-client" :host "127.0.0.1" :family 'ipv4
                   :service (process-contact server :service) :nowait t :noquery t
                   :filter (lambda (_client text) (setq received (concat received text)))))
            (emacsbuild-pipe--await (lambda () (eq (process-status client) 'open)))
            (process-send-string client "socket-data\n")
            (emacsbuild-pipe--await (lambda () (equal received "socket-data\n"))))
        (dolist (process (append accepted (list client server)))
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest emacsbuild-pipe-bulk-output-and-final-stderr-are-complete ()
  (let (child stderr (bytes 0) errors done)
    (unwind-protect
        (progn
          (setq stderr (make-pipe-process
                        :name "bulk-stderr" :noquery t
                        :filter (lambda (_pipe text) (setq errors (concat errors text)))))
          (setq child
                (make-process
                 :name "bulk-child" :command (list (getenv "EMACSBUILD_PIPE_CHILD") "bulk")
                 :connection-type 'pipe :noquery t :stderr stderr
                 :filter (lambda (_child text) (cl-incf bytes (length text)))
                 :sentinel (lambda (process _event)
                             (when (eq (process-status process) 'exit) (setq done t)))))
          (emacsbuild-pipe--await (lambda () (and done (equal errors "stderr-complete\n"))))
          (should (= bytes (* 1024 1024)))
          (should (zerop (process-exit-status child))))
      (dolist (process (list child stderr))
        (when (process-live-p process) (delete-process process))))))

(ert-run-tests-batch-and-exit (or (getenv "EMACSBUILD_PIPE_SELECTOR") "^emacsbuild-pipe-"))
