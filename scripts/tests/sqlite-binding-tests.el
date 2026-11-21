;;; sqlite-binding-tests.el --- Check SQLite parameter ownership -*- lexical-binding: t; -*-
;; SPDX-FileCopyrightText: 2026 Chen Zhexuan
;; SPDX-License-Identifier: MIT

(require 'ert)

(defun sqlite-binding-tests--check-copy (type expected)
  "Check that a prepared statement owns the bound EXPECTED value of TYPE."
  (let ((db (sqlite-open)) statement)
    (unwind-protect
        (progn
          (let ((argument (copy-sequence expected)))
            (when (equal type "blob")
              (put-text-property 0 1 'coding-system 'binary argument))
            (setq statement
                  (sqlite-select db "SELECT typeof(val), val FROM (SELECT ? AS val)"
                                 (list argument) 'set))
            ;; Overwriting the original also detects borrowing when a GC happens
            ;; not to move its bytes in this particular heap layout.
            (fillarray argument ?x))
          (garbage-collect)
          (should (equal (sqlite-next statement) (list type expected)))
          (should-not (sqlite-next statement)))
      (when statement (sqlite-finalize statement))
      (sqlite-close db))))

(ert-deftest sqlite-binding-tests-text-is-owned-by-statement ()
  (should (sqlite-available-p))
  (sqlite-binding-tests--check-copy
   "text" (encode-coding-string "original text parameter" 'utf-8-unix)))

(ert-deftest sqlite-binding-tests-blob-is-owned-by-statement ()
  (should (sqlite-available-p))
  (sqlite-binding-tests--check-copy "blob" (unibyte-string #x00 #x41 #x80 #xff)))
