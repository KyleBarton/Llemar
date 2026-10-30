#!/bin/sh
# Byte-compile, lint, and run llemar's test suite.
set -e

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== byte-compile (warnings are errors) =="
emacs -Q --batch \
  --eval "(setq byte-compile-error-on-warn t
                byte-compile-dest-file-function (lambda (_) \"$tmp/llemar.elc\"))" \
  --eval "(unless (byte-compile-file \"$root/llemar.el\") (kill-emacs 1))"

echo "== checkdoc =="
# checkdoc reports through `warn', so count those rather than trusting a
# diagnostic buffer to exist.
emacs -Q --batch --eval "(progn
  (require 'checkdoc)
  (defvar llemar-checkdoc-issues 0)
  (advice-add 'display-warning :before
              (lambda (&rest _) (setq llemar-checkdoc-issues
                                      (1+ llemar-checkdoc-issues))))
  (checkdoc-file \"$root/llemar.el\")
  (when (get-buffer \"*Style Warnings*\")
    (princ (with-current-buffer \"*Style Warnings*\" (buffer-string))))
  (if (> llemar-checkdoc-issues 0)
      (progn (princ (format \"checkdoc: %d issue(s)\n\" llemar-checkdoc-issues))
             (kill-emacs 1))
    (princ \"checkdoc: clean\n\")))"

echo "== companion tool (offline Node tests) =="
node --test "$here/"*.test.mjs

echo "== ert =="
emacs -Q --batch -l "$here/llemar-tests.el" -f ert-run-tests-batch-and-exit
