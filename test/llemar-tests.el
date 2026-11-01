;;; llemar-tests.el --- Tests for llemar  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with test/run-tests.sh, or:
;;
;;   emacs -Q --batch -l test/llemar-tests.el -f ert-run-tests-batch-and-exit
;;
;; The tests drive test/mock-pi, a stand-in that speaks pi's RPC protocol and
;; replays named event scripts.  Nothing here calls a model or the network, so
;; the whole suite is free and deterministic.

;;; Code:

(require 'ert)
(require 'org)
(require 'cl-lib)

(defconst llemar-test-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this test file.")

(add-to-list 'load-path (directory-file-name
                         (file-name-directory
                          (directory-file-name llemar-test-directory))))
(require 'llemar)

(defconst llemar-test-mock (expand-file-name "mock-pi" llemar-test-directory))

;;;; Harness

(defun llemar-test--settle (&optional timeout)
  "Pump this buffer's process until the agent settles or TIMEOUT elapses."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and llemar--busy (< (float-time) deadline))
      (accept-process-output llemar--process 0.05))
    (when llemar--busy
      (error "Agent did not settle within %s seconds" (or timeout 10)))))

(defmacro llemar-test-with-conversation (scenario prompt &rest body)
  "Send PROMPT to mock SCENARIO, wait for it to settle, then run BODY.
BODY runs inside the conversation buffer, which is killed afterwards."
  (declare (indent 2) (debug (form form body)))
  `(let* ((llemar-executable llemar-test-mock)
          (llemar-extra-args (list ,scenario))
          (buffer (llemar llemar-test-directory)))
     (unwind-protect
         (with-current-buffer buffer
           (goto-char (point-max))
           (insert ,prompt "\n")
           (llemar-send)
           (llemar-test--settle)
           ,@body)
       (kill-buffer buffer))))

(defun llemar-test--headings ()
  "Return this buffer's headline texts, without text properties."
  (mapcar #'substring-no-properties
          (org-map-entries (lambda () (org-get-heading t t t t)))))

(defun llemar-test--folded-p (position)
  "Return non-nil when POSITION is inside folded (invisible) text."
  (or (org-fold-folded-p position)
      (get-char-property position 'invisible)))

(defun llemar-test--goto (regexp)
  "Move to the start of the first match for REGEXP, or fail."
  (goto-char (point-min))
  (unless (re-search-forward regexp nil t)
    (ert-fail (format "no match for %S in:\n%s" regexp (buffer-string))))
  (goto-char (match-beginning 0)))

(defun llemar-test--wait (predicate &optional process timeout)
  "Pump PROCESS until PREDICATE returns non-nil or TIMEOUT elapses.
Return PREDICATE's final value."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output process 0.05))
    (funcall predicate)))

;;;; Entry points

(defmacro llemar-test-with-window-setup (&rest body)
  "Run BODY with one window showing a scratch buffer, then restore the layout."
  (declare (indent 0) (debug t))
  `(let* ((llemar-executable llemar-test-mock)
          (llemar-extra-args '("basic"))
          (scratch (get-buffer-create "*llemar-test-scratch*"))
          (conversation nil))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (set-window-buffer (selected-window) scratch)
           ,@body)
       (when (buffer-live-p conversation) (kill-buffer conversation))
       (when (buffer-live-p scratch) (kill-buffer scratch)))))

(ert-deftest llemar-test-entry-points-are-commands ()
  "Both entry points are interactive."
  (should (commandp 'llemar))
  (should (commandp 'llemar-other-window)))

(ert-deftest llemar-test-starts-in-the-selected-window ()
  "`llemar' takes over the current window instead of splitting."
  (llemar-test-with-window-setup
    (let ((start (selected-window)))
      (setq conversation (llemar llemar-test-directory))
      (should (eq (selected-window) start))
      (should (eq (window-buffer start) conversation))
      (should (= 1 (length (window-list))))
      (should (buffer-live-p scratch))
      (should (equal (expand-file-name
                      (with-current-buffer conversation default-directory))
                     (expand-file-name llemar-test-directory))))))

(ert-deftest llemar-test-other-window-leaves-the-current-one ()
  "`llemar-other-window' displays elsewhere and leaves this window alone."
  (llemar-test-with-window-setup
    (let ((start (selected-window)))
      (setq conversation (llemar-other-window llemar-test-directory))
      (should (eq (window-buffer start) scratch))
      (should-not (eq (selected-window) start))
      (should (eq (window-buffer (selected-window)) conversation)))))

(ert-deftest llemar-test-start-replaces-current-conversation ()
  "Starting from a conversation saves it and cleans up its buffer and pi."
  (llemar-test-with-window-setup
    (let ((llemar-session-registry nil))
      (setq conversation (llemar llemar-test-directory))
      (should (llemar-test--wait (lambda () llemar--session-id)
                                llemar--process))
      (insert "Unsent draft to preserve\n")
      (let ((old conversation)
            (process llemar--process)
            (log (get-buffer (llemar--log-buffer-name conversation)))
            (file (expand-file-name (concat (secure-hash 'sha256 llemar--session-id)
                                            ".org")
                                    llemar-session-directory))
            (start (selected-window)))
        (setq conversation (llemar))
        (should-not (eq conversation old))
        (should-not (buffer-live-p old))
        (should-not (process-live-p process))
        (should-not (buffer-live-p log))
        (should (eq (selected-window) start))
        (should (eq (window-buffer start) conversation))
        (should (equal default-directory
                       (file-name-as-directory llemar-test-directory)))
        (should (with-temp-buffer
                  (insert-file-contents file)
                  (search-forward "Unsent draft to preserve" nil t)))))))

(ert-deftest llemar-test-start-failure-preserves-current-conversation ()
  "A failed replacement leaves the old conversation and process alive."
  (llemar-test-with-window-setup
    (setq conversation (llemar llemar-test-directory))
    (let ((process llemar--process)
          (llemar-executable "llemar-definitely-not-installed"))
      (should-error (llemar) :type 'user-error)
      (should (buffer-live-p conversation))
      (should (process-live-p process))
      (should (eq (window-buffer) conversation)))))

(ert-deftest llemar-test-other-window-preserves-current-conversation ()
  "Starting in another window keeps the original conversation alive."
  (llemar-test-with-window-setup
    (setq conversation (llemar llemar-test-directory))
    (let ((old conversation)
          (start (selected-window)))
      (unwind-protect
          (progn
            (setq conversation (llemar-other-window))
            (should (buffer-live-p old))
            (should (llemar--process-live-p old))
            (should (eq (window-buffer start) old))
            (should-not (eq conversation old)))
        (when (buffer-live-p old) (kill-buffer old))))))

;;;; Following streaming output

(defmacro llemar-test-with-passive-conversation (window-var &rest body)
  "Start a conversation displayed in an unselected window.
WINDOW-VAR is bound to that window and the selected window keeps showing
a scratch buffer, so only an explicit follow can move WINDOW-VAR's point.
BUFFER is bound to the conversation buffer inside BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((llemar-executable llemar-test-mock)
          (llemar-extra-args '("basic"))
          (scratch (get-buffer-create "*llemar-test-scratch*"))
          (buffer nil))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (set-window-buffer (selected-window) scratch)
           (let ((scratch-window (selected-window)))
             (setq buffer (llemar-other-window llemar-test-directory))
             (let ((,window-var (get-buffer-window buffer)))
               (select-window scratch-window)
               ,@body)))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (when (buffer-live-p scratch) (kill-buffer scratch)))))

(defun llemar-test--type (buffer prompt)
  "Type PROMPT under BUFFER's last user heading without sending it."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-max))
      (insert prompt "\n"))))

(defun llemar-test--send-and-settle (buffer)
  "Send BUFFER's pending prompt and wait for the agent to settle."
  (with-current-buffer buffer
    (llemar-send)
    (llemar-test--settle)))

(ert-deftest llemar-test-follows-streaming-output ()
  "A window whose cursor is at the prompt's end tracks the streamed reply."
  (llemar-test-with-passive-conversation window
    (llemar-test--type buffer "go")
    ;; The user's cursor sits at the end of what they just typed.
    (set-window-point window (with-current-buffer buffer (point-max)))
    (llemar-test--send-and-settle buffer)
    (should (= (window-point window)
               (with-current-buffer buffer (point-max))))))

(ert-deftest llemar-test-leaves-a-scrolled-up-window-alone ()
  "A window scrolled up to read earlier output is not pulled to the end."
  (llemar-test-with-passive-conversation window
    (llemar-test--type buffer "go")
    (set-window-point window (with-current-buffer buffer (point-min)))
    (llemar-test--send-and-settle buffer)
    (should (= (window-point window)
               (with-current-buffer buffer (point-min))))))

(ert-deftest llemar-test-following-can-be-disabled ()
  "With `llemar-follow-output' nil, a window at the end is left in place."
  (let ((llemar-follow-output nil))
    (llemar-test-with-passive-conversation window
      (llemar-test--type buffer "go")
      (let ((start (with-current-buffer buffer (point-max))))
        (set-window-point window start)
        (llemar-test--send-and-settle buffer)
        (should (= (window-point window) start))
        (should (< start (with-current-buffer buffer (point-max))))))))

;;;; Folding

(ert-deftest llemar-test-thinking-drawer-is-folded ()
  "A completed thinking drawer collapses, hiding its body."
  (llemar-test-with-conversation "basic" "go"
    (llemar-test--goto "^:THINKING:$")
    (let ((body (save-excursion (forward-line 1) (point))))
      (should (llemar-test--folded-p body)))))

(ert-deftest llemar-test-tool-blocks-are-folded ()
  "Tool argument and result blocks collapse, hiding their bodies."
  (llemar-test-with-conversation "basic" "go"
    (llemar-test--goto "^#\\+begin_src json$")
    (should (llemar-test--folded-p (save-excursion (forward-line 1) (point))))
    (llemar-test--goto "^#\\+begin_example$")
    (should (llemar-test--folded-p (save-excursion (forward-line 1) (point))))))

(defun llemar-test--assert-tool-subtrees-folded ()
  "Assert ordinary tools collapse while edit/write previews stay visible."
  (goto-char (point-min))
  (while (re-search-forward "^\\*\\*\\* " nil t)
    (beginning-of-line)
    (should-not (llemar-test--folded-p (point)))
    (let ((preview (member (org-get-heading t t t t) '("edit" "write")))
          (end (save-excursion (org-end-of-subtree t t) (point))))
      (forward-line 1)
      (while (< (point) end)
        ;; The legacy replay diagnostic is appended outside the tool output.
        (unless (or (looking-at-p "^[ \t]*$")
                    (looking-at-p "^# raw session history unavailable;"))
          (if preview
              (when (looking-at-p "^#\\+begin_")
                (should-not (llemar-test--folded-p (point))))
            (should (llemar-test--folded-p (point)))))
        (forward-line 1)))))

(ert-deftest llemar-test-tool-subtrees-folded-live ()
  "Live parallel calls hide all contents, including delimiters and timing."
  (llemar-test-with-conversation "parallel" "go"
    (should (= (how-many "^\\*\\*\\* " (point-min) (point-max)) 2))
    (should (string-match-p "# 44ms" (buffer-string)))
    (llemar-test--assert-tool-subtrees-folded)))

(ert-deftest llemar-test-folding-leaves-structure-visible ()
  "Conversation headings and assistant prose stay visible."
  (llemar-test-with-conversation "basic" "go"
    (dolist (regexp '("^\\*\\* User$" "^\\*\\* Assistant$" "^\\*\\*\\* bash$"
                      "^:THINKING:$"
                      "Here is the plan\\." "Two files\\. Done\\."))
      (llemar-test--goto regexp)
      (should-not (llemar-test--folded-p (point))))))

(ert-deftest llemar-test-content-after-a-fold-is-visible ()
  "Text inserted after a folded block does not inherit its invisibility.
Appending at the boundary of a folded region is the way streamed output
could silently vanish."
  (llemar-test-with-conversation "basic" "go"
    (llemar-test--goto "Two files\\. Done\\.")
    (should-not (llemar-test--folded-p (point)))
    (llemar-test--goto "^\\*\\* User$")
    (goto-char (point-max))
    (should-not (llemar-test--folded-p (max (point-min) (1- (point)))))))

(ert-deftest llemar-test-folding-can-be-disabled ()
  "With the fold options off, drawers and blocks stay open."
  (let ((llemar-fold-thinking nil)
        (llemar-fold-blocks nil))
    (llemar-test-with-conversation "basic" "go"
      (llemar-test--goto "^\\*\\*\\* bash$")
      (org-show-subtree)
      (llemar-test--goto "^:THINKING:$")
      (should-not (llemar-test--folded-p
                   (save-excursion (forward-line 1) (point))))
      (llemar-test--goto "^#\\+begin_src json$")
      (should-not (llemar-test--folded-p
                   (save-excursion (forward-line 1) (point)))))))

;;;; Org structure

(ert-deftest llemar-test-conversation-tree ()
  "Each turn is its own headline, with tool calls nested under it."
  (llemar-test-with-conversation "basic" "go"
    (should (equal (llemar-test--headings)
                   '("Current" "User" "Assistant" "bash" "Assistant" "User")))))

(ert-deftest llemar-test-hostile-prose-makes-no-headlines ()
  "Markdown bold and bullets at column 0 cannot become headlines."
  (llemar-test-with-conversation "basic" "go"
    (should (equal (llemar-test--headings)
                   '("Current" "User" "Assistant" "bash" "Assistant" "User")))
    (should (string-match-p "^ \\*\\*Step one\\*\\*: look around\\.$"
                            (buffer-string)))))

(ert-deftest llemar-test-tool-output-cannot-escape-its-block ()
  "A would-be headline or block terminator in tool output is escaped."
  (llemar-test-with-conversation "basic" "go"
    (should-not (member "not a heading" (llemar-test--headings)))
    (should (string-match-p "^,\\* not a heading$" (buffer-string)))
    (should (string-match-p "^,#\\+end_example$" (buffer-string)))
    (should (org-element-parse-buffer))))

(ert-deftest llemar-test-non-streamed-text-is-not-lost ()
  "A turn whose text arrives only in text_end still renders.
Content indices restart per message, so a later turn must not be taken
for an already-streamed block."
  (llemar-test-with-conversation "basic" "go"
    (should (string-match-p "Two files\\. Done\\." (buffer-string)))))

(ert-deftest llemar-test-steering-is-not-a-heading ()
  "A steering message renders as a drawer, not a headline.
As a headline it would break the nesting of the `* Assistant' turn it
interrupts."
  (llemar-test-with-conversation "basic" "go"
    (llemar-steer "please focus")
    (should-not (member "Steering" (llemar-test--headings)))
    (should (equal (llemar-test--headings)
                   '("Current" "User" "Assistant" "bash" "Assistant" "User")))
    (llemar-test--goto "^:STEERING:$")
    (llemar-test--goto "please focus")
    (should (org-element-parse-buffer))))

(ert-deftest llemar-test-fresh-user-heading-on-settle ()
  "Settling leaves an empty user heading ready to type into."
  (llemar-test-with-conversation "basic" "go"
    (should (string-match-p "\\* User\n\\'" (buffer-string)))
    (should-not llemar--busy)))

;;;; Tool calls

(ert-deftest llemar-test-parallel-tool-results-are-routed ()
  "Each result lands under its own tool headline, whatever the order."
  (llemar-test-with-conversation "parallel" "go"
    (should (equal (llemar-test--headings)
                   '("Current" "User" "Assistant" "bash" "read_file" "User")))
    (dolist (probe '(("bash" . "line 1") ("read_file" . "An LL(m)")))
      (llemar-test--goto (format "^\\*\\*\\* %s$" (car probe)))
      (let ((limit (save-excursion
                     (forward-line 1)
                     (or (re-search-forward "^\\*+ " nil t) (point-max)))))
        (should (save-excursion (search-forward (cdr probe) limit t)))))))

(ert-deftest llemar-test-tool-output-is-truncated ()
  "Long tool output is capped and says how much was dropped."
  (let ((llemar-max-tool-result-lines 5))
    (llemar-test-with-conversation "parallel" "go"
      (should (string-match-p "line 5" (buffer-string)))
      (should-not (string-match-p "line 6\n" (buffer-string)))
      (should (string-match-p "(25 more lines)" (buffer-string))))))

(ert-deftest llemar-test-arguments-render-faithfully ()
  "JSON null, false, true, and arrays survive into the preview.
They are distinct values on the wire and must not collapse together."
  (llemar-test-with-conversation "nullargs" "go"
    (let ((text (buffer-string)))
      (should (string-match-p "\"offset\": null" text))
      (should (string-match-p "\"recurse\": false" text))
      (should (string-match-p "\"deep\": true" text))
      (should (string-match-p "\"list\": \\[" text))
      (should-not (string-match-p "{}" text)))))

(ert-deftest llemar-test-unicode-survives-framing ()
  "Records split only on LF: U+2028 and astral characters pass through."
  (llemar-test-with-conversation "parallel" "go"
    (should (string-match-p "café 日本語 😀" (buffer-string)))
    (should (string-match-p " " (buffer-string)))))

;;;; Compaction

(ert-deftest llemar-test-compaction-current-from-start ()
  "Conversations are nested beneath Current even before compaction."
  (llemar-test-with-conversation "basic" "go"
    (should (string-match-p "^\\* Current\n\\*\\* User" (buffer-string)))
    (should (string-match-p "^\\*\\*\\* bash$" (buffer-string)))))

(ert-deftest llemar-test-compaction-manual-preserves-draft ()
  "Manual compaction archives only the removed prefix, keeping a draft."
  (llemar-test-with-conversation "compact-manual" "go"
    (should (commandp 'llemar-compact))
    (goto-char (point-max))
    (insert "unsent draft\n")
    (llemar-compact "Keep implementation details")
    (should-error (llemar-compact) :type 'user-error)
    (llemar-test--settle)
    (should (llemar-test--wait
             (lambda () (string-match-p "^\\* Compacted " (buffer-string)))
             llemar--process))
    (should (equal (llemar-test--headings)
                   '("Compacted 2026-01-02 03:04:05 +0000" "Source" "User" "Assistant" "bash"
                     "Summary" "Current" "Assistant" "User")))
    (should (string-match-p "^\\*\\*\\*\\* bash$" (buffer-string)))
    (should (string-match-p "^,\\* not a heading$" (buffer-string)))
    (should (string-match-p "^,#\\+end_example$" (buffer-string)))
    (should (string-match-p "^\\*\\*\\* Assistant\nOriginal answer" (buffer-string)))
    (should (string-match-p "^\\*\\* Assistant\nRetained answer" (buffer-string)))
    (should (string-match-p "Remember the old exchange" (buffer-string)))
    (should (equal (string-trim (buffer-substring-no-properties
                                 (car (llemar--last-prompt-bounds)) (point-max)))
                   "unsent draft"))
    (should-not llemar--status)))

(ert-deftest llemar-test-compaction-missing-boundary-is-explicit ()
  "Unknown boundaries show the real summary without claiming to archive source."
  (llemar-test-with-conversation "compact-unknown" "go"
    (goto-char (point-max))
    (insert "draft\n")
    (llemar-compact)
    (llemar-test--settle)
    (should (llemar-test--wait
             (lambda () (string-match-p "exact source boundary unavailable" (buffer-string)))
             llemar--process))
    (should-not (member "Source" (llemar-test--headings)))
    (should (string-match-p "Remember the old exchange" (buffer-string)))
    (should (equal "draft" (string-trim (buffer-substring-no-properties
                                         (car (llemar--last-prompt-bounds)) (point-max)))))))

(ert-deftest llemar-test-compaction-repeated ()
  "Repeated compaction retains earlier archives without duplicating messages."
  (llemar-test-with-conversation "compact-manual" "go"
    (dotimes (index 2)
      (llemar-compact)
      (llemar-test--settle)
      (should (llemar-test--wait
               (lambda () (= (1+ index) (cl-count "Summary" (llemar-test--headings)
                                                  :test #'equal))) llemar--process)))
    (should (= 1 (how-many "Original answer" (point-min) (point-max))))
    (should (= 1 (how-many "Retained answer" (point-min) (point-max))))
    (should (string-match-p "^\\* Current\n\\*\\* User" (buffer-string)))))

(ert-deftest llemar-test-compaction-resume-keeps-local-archive ()
  "Resume reconciles local archived source with authoritative pi entries."
  (let ((llemar-session-directory (make-temp-file "llemar-archives" t)))
    (unwind-protect
        (progn
          (llemar-test-with-conversation "compact-manual" "go"
            (llemar-compact)
            (llemar-test--settle)
            (should (llemar-test--wait
                     (lambda () (member "Summary" (llemar-test--headings))) llemar--process))
            (goto-char (point-min))
            (search-forward "Original answer")
            (replace-match "Locally annotated original")
            (goto-char (point-max))
            (insert "Draft for later\n")
            (llemar--save-transcript))
          (let* ((llemar-executable llemar-test-mock)
                 (llemar-extra-args '("compact-resume"))
                 (buffer (llemar--resume-conversation llemar-test-directory "saved")))
            (unwind-protect
                (with-current-buffer buffer
                  (should (llemar-test--wait
                           (lambda () (string-match-p "Locally annotated original" (buffer-string)))
                           llemar--process))
                  (should (string-match-p "Draft for later" (buffer-string))))
              (kill-buffer buffer))))
      (delete-directory llemar-session-directory t))))

(ert-deftest llemar-test-compaction-auto-continues ()
  "Automatic compaction preserves in-flight output and opens just one prompt."
  (llemar-test-with-conversation "compact-auto" "go"
    (should (llemar-test--wait
             (lambda () (member "Summary" (llemar-test--headings))) llemar--process))
    (should (string-match-p "Continued after compaction" (buffer-string)))
    (should (= 2 (cl-count "User" (llemar-test--headings) :test #'equal)))
    (should-not llemar--busy)
    (should-not llemar--status)))

(ert-deftest llemar-test-compaction-before-prompt ()
  "Pre-prompt compaction must not archive a prompt pi has not consumed yet."
  (llemar-test-with-conversation "compact-before" "go"
    (goto-char (point-max))
    (insert "next prompt\n")
    (llemar-send)
    (llemar-test--settle)
    (should (llemar-test--wait
             (lambda () (member "Summary" (llemar-test--headings))) llemar--process))
    (llemar-test--goto "^\\* Current$")
    (should (search-forward "next prompt" nil t))
    (should (search-forward "Answered next prompt" nil t))))

(ert-deftest llemar-test-compaction-retain-none-continues ()
  "A retain-none boundary stops before output generated after compaction."
  (llemar-test-with-conversation "compact-auto-none" "go"
    (should (llemar-test--wait
             (lambda () (member "Summary" (llemar-test--headings))) llemar--process))
    (llemar-test--goto "^\\* Current$")
    (should (search-forward "Continued after compaction" nil t))))

(ert-deftest llemar-test-compaction-failure-keeps-source ()
  "Failure and cancellation do not archive any source."
  (dolist (scenario '("compact-fail" "compact-cancel"))
    (llemar-test-with-conversation scenario "go"
      (goto-char (point-max))
      (insert "unsent draft\n")
      (llemar-compact)
      (llemar-test--settle)
      (should (equal (string-trim (buffer-substring-no-properties
                                   (car (llemar--last-prompt-bounds)) (point-max)))
                     "unsent draft"))
      (should-not (member "Source" (llemar-test--headings)))
      (should (string-match-p "Original answer" (buffer-string)))
      (should-not llemar--status))))

(ert-deftest llemar-test-compaction-resume-from-entries ()
  "Raw session entries recover source, summary, and retained history."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("compact-resume"))
         (buffer (llemar--resume-conversation llemar-test-directory "saved")))
    (unwind-protect
        (with-current-buffer buffer
          (should (llemar-test--wait
                   (lambda () (member "Summary" (llemar-test--headings))) llemar--process))
          (should (string-match-p "Original answer" (buffer-string)))
          (should (string-match-p "^\\*\\* Assistant\nRetained answer" (buffer-string))))
      (kill-buffer buffer))))

;;;; Session events

(ert-deftest llemar-test-retry-is-reported ()
  "A provider retry is noted in the transcript."
  (llemar-test-with-conversation "retry" "go"
    (should (string-match-p "# retry 1/3: 529 overloaded" (buffer-string)))
    (should (string-match-p "Recovered\\." (buffer-string)))))

(ert-deftest llemar-test-abort-settles-the-run ()
  "Aborting a running agent settles it and notes the abort."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("hang"))
         (buffer (llemar llemar-test-directory)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "run forever\n")
          (llemar-send)
          (accept-process-output llemar--process 1)
          (should llemar--busy)
          (should-error (llemar-send) :type 'user-error)
          (llemar-abort)
          (llemar-test--settle)
          (should-not llemar--busy)
          (should (string-match-p "# aborted" (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest llemar-test-failed-command-is-reported ()
  "A command rejected by pi is noted rather than swallowed."
  (llemar-test-with-conversation "basic" "go"
    (llemar--send '((type . "set_model") (model . "bogus")))
    (accept-process-output llemar--process 1)
    (should (string-match-p "# error: Model not found: bogus" (buffer-string)))))

;;;; Process lifecycle

(ert-deftest llemar-test-missing-executable-is-a-clean-error ()
  "A missing pi fails with guidance and leaves no stray buffer."
  (let ((llemar-executable "llemar-definitely-not-installed"))
    (should-error (llemar llemar-test-directory) :type 'user-error)
    (should-not (seq-filter (lambda (b)
                              (string-prefix-p "*llemar:" (buffer-name b)))
                            (buffer-list)))))

(ert-deftest llemar-test-process-death-is-survivable ()
  "When pi exits, the buffer says so and sending gives advice."
  (let* ((dying (make-temp-file "llemar-dying-pi" nil ".sh"
                                "#!/bin/sh\nexit 3\n"))
         (llemar-executable dying))
    (set-file-modes dying #o755)
    (let ((buffer (llemar llemar-test-directory)))
      (unwind-protect
          (with-current-buffer buffer
            ;; Pump until the death note lands rather than until the process
            ;; stops being live: pi can exit before the first loop check, and
            ;; then the sentinel only runs once Emacs is given a turn here.
            (llemar-test--wait
             (lambda () (string-match-p "# pi process" (buffer-string)))
             nil 5)
            (should-not (llemar--process-live-p))
            (should-not llemar--busy)
            (should (string-match-p "# pi process" (buffer-string)))
            (should-error (llemar-send) :type 'user-error))
        (kill-buffer buffer)
        (delete-file dying)))))

(ert-deftest llemar-test-empty-prompt-is-refused ()
  "Sending with nothing typed is refused."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("basic"))
         (buffer (llemar llemar-test-directory)))
    (unwind-protect
        (with-current-buffer buffer
          (should-error (llemar-send) :type 'user-error))
      (kill-buffer buffer))))

(ert-deftest llemar-test-killing-a-conversation-cleans-up ()
  "Killing a conversation stops pi and takes its log buffer with it."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("basic"))
         (buffer (llemar llemar-test-directory))
         (process (buffer-local-value 'llemar--process buffer))
         (log (llemar--log-buffer-name buffer)))
    (should (get-buffer log))
    (kill-buffer buffer)
    (should-not (process-live-p process))
    (should-not (get-buffer log))))

;;;; Renderer robustness

(ert-deftest llemar-test-bad-record-does-not-stop-the-stream ()
  "An unrenderable record is logged, not fatal."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("basic"))
         (buffer (llemar llemar-test-directory)))
    (unwind-protect
        (with-current-buffer buffer
          ;; tool_execution_end with no result at all.
          (llemar--handle-record '((type . "tool_execution_end")
                                   (toolCallId . "x") (toolName . "bash")))
          (should (string-match-p "no output" (buffer-string))))
      (kill-buffer buffer))))

;;;; Session registry and resume

(defvar llemar-session-directory)
;; Keep all transcript writes offline and outside the user's configuration.
(setq llemar-session-directory (make-temp-file "llemar-test-sessions-" t))
(add-hook 'kill-emacs-hook
          (lambda () (delete-directory llemar-session-directory t)))

(ert-deftest llemar-test-session-transcript-saved ()
  "Settled output is saved as Org and recorded for preview."
  (let ((llemar-session-registry nil))
    (llemar-test-with-conversation "basic" "Inspect repository"
      (let ((file (plist-get (cdr (assoc llemar--session-id
                                        llemar-session-registry)) :org-file)))
        (should (stringp file))
        (should (file-exists-p file))
        (should (equal (file-name-directory file)
                       (file-name-as-directory llemar-session-directory)))
        (should (= (logand (file-modes file) #o777) #o600))
        (should (equal (with-temp-buffer
                         (insert-file-contents file) (buffer-string))
                       (buffer-string)))))))

(ert-deftest llemar-test-consult-session-preview ()
  "Consult preserves order and previews readable Org transcripts."
  (let* ((original-require (symbol-function 'require))
         (file (make-temp-file "llemar-preview-" nil ".org"))
         (llemar-session-registry
          (list (list "a" :time 1) (list "b" :time 2 :org-file file)))
         previewed)
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &rest args)
                     (if (eq feature 'consult) t
                       (apply original-require feature args))))
                  ((symbol-function 'consult--file-preview)
                   (lambda () (lambda (action file)
                                (setq previewed (list action file)))))
                  ((symbol-function 'consult--read)
                   (lambda (candidates &rest options)
                     (should-not (plist-get options :sort))
                     (let ((state (plist-get options :state)))
                       (funcall state 'preview (car candidates))
                       (should (equal previewed (list 'preview file)))
                       (funcall state 'preview (cadr candidates))
                       (should (equal previewed '(preview nil)))
                       (funcall state 'exit nil)
                       (should (equal previewed '(exit nil))))
                     (car candidates))))
          (should (equal (car (llemar--read-session)) "b")))
      (delete-file file))))

(ert-deftest llemar-test-model-session-name ()
  "A title from pi supersedes the initial prompt and is saved."
  (let ((llemar-session-registry nil))
    (llemar-test-with-conversation "named" "Look around"
      (should (equal (buffer-name) "*llemar: repository-navigation*"))
      (should (equal (plist-get (cdr (assoc llemar--session-id
                                          llemar-session-registry)) :name)
                     "Repository navigation")))))

(ert-deftest llemar-test-session-title-review-is-hidden ()
  "A backend title reminder stays out of the visible conversation."
  (let ((llemar-session-registry nil))
    (llemar-test-with-conversation "title-review" "Look around"
      (should (equal (buffer-name) "*llemar: repository-navigation*"))
      (should (string-match-p "Done\\." (buffer-string)))
      (should-not (string-match-p "hidden reminder sentinel" (buffer-string)))
      (should-not (string-match-p "Session-title check" (buffer-string))))))

(ert-deftest llemar-test-picker-disables-completion-sorting ()
  "Completion UIs must preserve the registry's newest-first order."
  (let ((llemar-session-registry '(("a" :time 1) ("b" :time 2))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (should (eq (plist-get completion-extra-properties
                                        :display-sort-function) #'identity))
                 (car collection))))
      (should (equal (car (llemar--read-session)) "b")))))

(ert-deftest llemar-test-records-session-on-start ()
  "Starting a conversation records its session id and directory."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("basic"))
         (llemar-session-registry nil)
         (buffer (llemar llemar-test-directory)))
    (unwind-protect
        (with-current-buffer buffer
          (should (llemar-test--wait (lambda () llemar--session-id)
                                     llemar--process))
          (should (equal llemar--session-id "mock-123"))
          (let ((entry (assoc "mock-123" llemar-session-registry)))
            (should entry)
            (should (equal (plist-get (cdr entry) :cwd)
                           (file-name-as-directory
                            (expand-file-name llemar-test-directory))))
            (should (equal (plist-get (cdr entry) :file)
                           "/tmp/mock-session.jsonl"))))
      (kill-buffer buffer))))

(ert-deftest llemar-test-records-first-prompt-label ()
  "The first prompt sent becomes the session's picker label."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("basic"))
         (llemar-session-registry nil)
         (buffer (llemar llemar-test-directory)))
    (unwind-protect
        (with-current-buffer buffer
          ;; The id must be known before the label can be attached to it.
          (should (llemar-test--wait (lambda () llemar--session-id)
                                     llemar--process))
          (goto-char (point-max))
          (insert "Look around please\n")
          (llemar-send)
          (llemar-test--settle)
          (let ((entry (assoc "mock-123" llemar-session-registry)))
            (should (equal (plist-get (cdr entry) :label)
                           "Look around please")))
          (should (equal (buffer-name) "*llemar: look-around-please*")))
      (kill-buffer buffer))))

(ert-deftest llemar-test-session-label-renames-buffer-and-log ()
  "Session labels are slugified, with unique names and log continuity."
  (let* ((llemar-session-registry nil)
         (occupied (generate-new-buffer "*llemar: fix-the-bug*"))
         (buffer (generate-new-buffer " *llemar-rename-test*"))
         (log (get-buffer-create (llemar--log-buffer-name buffer))))
    (unwind-protect
        (with-current-buffer buffer
          (llemar-mode)
          (setq llemar--session-id "rename-test")
          (llemar--registry-put "rename-test" :label "  Fix THE / bug!!!  ")
          (should (equal (buffer-name) "*llemar: fix-the-bug*<2>"))
          (should (eq log (get-buffer (llemar--log-buffer-name buffer))))
          ;; An explicit session name takes precedence over the prompt label.
          (llemar--registry-put "rename-test" :name "Better Name")
          (should (equal (buffer-name) "*llemar: better-name*"))
          ;; Unrelated updates must not rename this conversation.
          (llemar--registry-put "other" :label "Other session")
          (should (equal (buffer-name) "*llemar: better-name*")))
      (kill-buffer buffer)
      (when (buffer-live-p log) (kill-buffer log))
      (kill-buffer occupied))))

(ert-deftest llemar-test-session-slug-is-shorter-than-label ()
  "Buffer slugs are capped at 36 characters without a trailing hyphen."
  (let ((llemar-session-registry nil))
    (with-temp-buffer
      (llemar-mode)
      (setq llemar--session-id "long-slug")
      (let ((label (concat (make-string 35 ?a) " more words for the label")))
        (llemar--registry-put "long-slug" :label label)
        (should (equal (buffer-name)
                       (format "*llemar: %s*" (make-string 35 ?a))))
        (should (equal (plist-get (cdr (assoc "long-slug"
                                            llemar-session-registry))
                                 :label)
                       label)))
      (llemar--registry-put "long-slug" :name (make-string 60 ?b))
      (should (equal (buffer-name)
                     (format "*llemar: %s*" (make-string 36 ?b)))))))

(ert-deftest llemar-test-empty-session-slug-keeps-buffer-name ()
  "A label containing only punctuation does not produce an empty name."
  (let ((llemar-session-registry nil))
    (with-temp-buffer
      (llemar-mode)
      (setq llemar--session-id "empty-slug")
      (let ((name (buffer-name)))
        (llemar--registry-put "empty-slug" :label "?!")
        (should (equal (buffer-name) name))))))

(ert-deftest llemar-test-registry-filters-by-directory ()
  "Listing sessions keeps only the chosen directory, newest first."
  (let ((llemar-session-registry
         (list (list "a" :cwd "/dir/one/" :time '(100 0))
               (list "b" :cwd "/dir/two/" :time '(200 0))
               (list "c" :cwd "/dir/one/" :time '(300 0)))))
    (should (equal (mapcar #'car (llemar--registry-sessions "/dir/one/"))
                   '("c" "a")))
    (should (equal (mapcar #'car (llemar--registry-sessions "/dir/two/"))
                   '("b")))
    (should (equal (mapcar #'car (llemar--registry-sessions))
                   '("c" "b" "a")))))

(ert-deftest llemar-test-read-session-returns-the-chosen-entry ()
  "Picking a display label returns its registry entry; empty list errors."
  (let ((llemar-session-registry
         (list (list "a" :cwd "/d/" :label "first" :time '(100 0))
               (list "b" :cwd "/d/" :label "second" :time '(200 0)))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 ;; Newest first, so the first choice is "b".
                 (car collection))))
      (should (equal (car (llemar--read-session "/d/")) "b")))
    (should-error (llemar--read-session "/nowhere/") :type 'user-error)))

(ert-deftest llemar-test-resume-is-a-command ()
  "`llemar-resume' is interactive."
  (should (commandp 'llemar-resume)))

(ert-deftest llemar-test-resume-replaces-current-conversation ()
  "Resuming saves and cleans up the current conversation."
  (llemar-test-with-window-setup
    (let ((llemar-session-registry nil))
      (setq conversation (llemar llemar-test-directory))
      (should (llemar-test--wait (lambda () llemar--session-id)
                                llemar--process))
      (insert "Draft before resuming\n")
      (let ((old conversation)
            (process llemar--process)
            (log (get-buffer (llemar--log-buffer-name conversation)))
            (file (expand-file-name
                   (concat (secure-hash 'sha256 llemar--session-id) ".org")
                   llemar-session-directory))
            (start (selected-window))
            (llemar-extra-args '("resume")))
        (setq conversation
              (llemar-resume (list "s1" :cwd llemar-test-directory
                                   :file "/tmp/x.jsonl")))
        (should-not (buffer-live-p old))
        (should-not (process-live-p process))
        (should-not (buffer-live-p log))
        (should (eq (selected-window) start))
        (should (eq (window-buffer start) conversation))
        (should (with-temp-buffer
                  (insert-file-contents file)
                  (search-forward "Draft before resuming" nil t)))))))

(ert-deftest llemar-test-resume-failure-preserves-current-conversation ()
  "A failed resume leaves the current conversation and process alive."
  (llemar-test-with-window-setup
    (setq conversation (llemar llemar-test-directory))
    (let ((process llemar--process)
          (llemar-executable "llemar-definitely-not-installed"))
      (should-error (llemar-resume (list "s1" :cwd llemar-test-directory))
                    :type 'user-error)
      (should (buffer-live-p conversation))
      (should (process-live-p process))
      (should (eq (window-buffer) conversation)))))

(ert-deftest llemar-test-resume-renders-history ()
  "Resuming replays the saved transcript and leaves a prompt ready."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("resume"))
         (llemar-session-registry nil)
         (session (list "s1"
                        :cwd (file-name-as-directory
                              (expand-file-name llemar-test-directory))
                        :file "/tmp/x.jsonl" :label "hi"))
         (buffer (llemar-resume session)))
    (unwind-protect
        (with-current-buffer buffer
          (should (llemar-test--wait
                   (lambda () (save-excursion
                                (goto-char (point-min))
                                (re-search-forward "Two files\\." nil t)))
                   llemar--process))
          ;; The system message is skipped; each turn is its own heading.
          (should (equal (llemar-test--headings)
                         '("Current" "User" "Assistant" "bash" "Assistant" "User")))
          (should (string-match-p "Summarise the repo" (buffer-string)))
          (should (string-match-p "README.md" (buffer-string)))
          (should (string-match-p "^:THINKING:$" (buffer-string)))
          ;; A would-be headline in replayed prose cannot restructure the doc.
          (should (string-match-p "^ \\* not a heading$" (buffer-string)))
          (should-not (member "not a heading" (llemar-test--headings)))
          (should-not llemar--busy)
          (llemar-test--assert-tool-subtrees-folded)
          (should (string-match-p "\\* User\n\\'" (buffer-string))))
      (kill-buffer buffer))))

;;;; Edit diffs

(defun llemar-test--assert-edit-diff ()
  "Assert that only the successful edit has a complete diff block."
  (llemar-test--assert-tool-subtrees-folded)
  (let ((blocks (org-element-map (org-element-parse-buffer) 'src-block
                  (lambda (block)
                    (when (equal (org-element-property :language block) "diff")
                      block)))))
    (should (= (length blocks) 1))
    (should (equal (org-element-property :value (car blocks))
                   "--- a/example.el\n+++ b/example.el\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n"))
    (goto-char (org-element-property :begin (car blocks)))
    (forward-line 1)
    (should-not (llemar-test--folded-p (point)))
    (org-back-to-heading t)
    (should (equal (org-get-heading t t t t) "edit")))
  (should (string-match-p "edit-ok" (buffer-string)))
  (should (string-match-p "edit-error" (buffer-string)))
  (should (string-match-p "edit-legacy" (buffer-string))))

(ert-deftest llemar-test-edit-diff-live ()
  "Successful edit patches render as complete diff source blocks."
  (let ((llemar-max-tool-result-lines 2))
    (llemar-test-with-conversation "edit" "Edit a file"
      (llemar-test--assert-edit-diff))))

(ert-deftest llemar-test-edit-diff-replay ()
  "Saved edit results retain their patches when resumed."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("edit"))
         (llemar-session-registry nil)
         (buffer (llemar-resume
                  (list "edit-session" :cwd llemar-test-directory
                        :file "/tmp/edit.jsonl" :label "edit"))))
    (unwind-protect
        (with-current-buffer buffer
          (should (llemar-test--wait
                   (lambda () (string-match-p "edit-legacy" (buffer-string)))
                   llemar--process))
          (llemar-test--assert-edit-diff))
      (kill-buffer buffer))))

;;;; Write diffs

(defun llemar-test--assert-write-diffs ()
  "Assert complete, expanded proposed contents, without duplicate JSON."
  (llemar-test--assert-tool-subtrees-folded)
  (let ((blocks (org-element-map (org-element-parse-buffer) 'src-block
                  (lambda (block)
                    (when (equal (org-element-property :language block) "diff")
                      block)))))
    (should (= (length blocks) 4))
    (should (equal (mapcar (lambda (block)
                            (org-element-property :value block))
                          blocks)
                   '("+first\n+second\n+third\n+last  \n"
                     "+not written\n\\ No newline at end of file\n"
                     ""
                     "+#+end_src\n+* not a heading\n++already plus\n+\n")))
    (dolist (block blocks)
      (goto-char (org-element-property :begin block))
      (forward-line 1)
      (should-not (llemar-test--folded-p (point)))
      (org-back-to-heading t)
      (should (equal (org-get-heading t t t t) "write"))))
  (dolist (path '("example.el" "failed.el" "empty.el" "invalid.el"))
    (should (string-match-p (regexp-quote path) (buffer-string))))
  (should (= (how-many "Proposed file contents" (point-min) (point-max)) 4))
  ;; Valid writes no longer duplicate their contents as escaped JSON strings.
  (should (= (how-many "^#\\+begin_src json" (point-min) (point-max)) 1))
  (should-not (member "not a heading" (llemar-test--headings)))
  (should-not (string-match-p "truncated" (buffer-string))))

(ert-deftest llemar-test-write-diff-live ()
  "Write arguments render before any results, without the output cap."
  (let ((llemar-max-tool-result-lines 2))
    (llemar-test-with-conversation "write" "Write files"
      (llemar-test--assert-write-diffs))))

(ert-deftest llemar-test-write-diff-results ()
  "Success and failure results preserve proposed contents without duplication."
  (let ((llemar-max-tool-result-lines 2))
    (llemar-test-with-conversation "write-results" "Write files"
      (llemar-test--assert-write-diffs)
      (dolist (text '("write-ok" "write-error" "write-empty" "write-hostile"
                      "write-invalid"))
        (should (string-match-p text (buffer-string))))
      (llemar-test--goto "^#\\+begin_example error")
      (org-back-to-heading t)
      (should (equal (org-get-heading t t t t) "write")))))

(ert-deftest llemar-test-write-diff-replay ()
  "Saved write arguments render without patches or filesystem reads."
  (let* ((llemar-executable llemar-test-mock)
         (llemar-extra-args '("write"))
         (llemar-max-tool-result-lines 2)
         (llemar-session-registry nil)
         (buffer (llemar-resume
                  (list "write-session" :cwd llemar-test-directory
                        :file "/tmp/write.jsonl" :label "write"))))
    (unwind-protect
        (with-current-buffer buffer
          (should (llemar-test--wait
                   (lambda () (string-match-p "write-invalid" (buffer-string)))
                   llemar--process))
          (llemar-test--assert-write-diffs))
      (kill-buffer buffer))))

;;;; Editor display requests

(ert-deftest llemar-test-open-buffer-live-results ()
  "Display live results once and retain editor failures in a tool drawer."
  (save-window-excursion
    (delete-other-windows)
    (llemar-test-with-conversation "open-buffer" "Show me the file"
      (let ((origin (selected-window)))
        (should (llemar-test--wait
                 (lambda () (string-match-p ":LLEMAR_ERROR:" (buffer-string)))))
        (should (eq (selected-window) origin))
        (should (eq (window-buffer origin) (current-buffer)))
        (let ((target (get-buffer-window (find-buffer-visiting llemar-test-mock))))
          (should (window-live-p target))
          (should (= (with-current-buffer (window-buffer target)
                       (line-number-at-pos (window-point target))) 2))))
      (should (= (how-many "^:LLEMAR_ERROR:" (point-min) (point-max)) 1))
      (should (member "open_buffer" (llemar-test--headings)))
      (should (string-match-p "line.*out of range" (buffer-string)))
      (should (< (string-match-p ":LLEMAR_ERROR:" (buffer-string))
                 (car (llemar--last-prompt-bounds)))))))

(ert-deftest llemar-test-open-file-validation-and-focus ()
  "Validate paths and positions while preserving draft and unsaved edits."
  (llemar-test-with-window-setup
    (setq conversation (llemar llemar-test-directory))
    (with-current-buffer conversation
      (let* ((file (make-temp-file (expand-file-name "open-test-" default-directory)))
             (target (find-file-noselect file)))
        (unwind-protect
            (progn
              (with-current-buffer target (insert "first\nsecond\n"))
              (goto-char (point-max))
              (insert "unsent draft")
              (let ((draft (buffer-string)) (position (point)))
                (llemar--display-file `((version . 1) (action . "open_file")
                                        (path . ,file) (line . 2) (column . 3)))
                (should (equal draft (buffer-string)))
                (should (= position (point)))
                (should (eq (window-buffer (selected-window)) conversation)))
              (dolist (details `(((path . ,file) (version . 2) (action . "open_file"))
                                 ((path . ,file) (version . 1) (action . "open_file") (column . 1))
                                 ((path . ,file) (version . 1) (action . "open_file") (line . 99))
                                 ((path . "/ssh:host:/file") (version . 1) (action . "open_file"))
                                 ((path . "/etc/hosts") (version . 1) (action . "open_file"))))
                (should-error (llemar--display-file details))))
          (with-current-buffer target (set-buffer-modified-p nil))
          (kill-buffer target)
          (delete-file file))))))

(ert-deftest llemar-test-open-buffer-ignores-failed-and-unrelated ()
  "Failed tools and unrelated tools never enqueue an editor action."
  (llemar-test-with-conversation "basic" "hello"
    (cl-letf (((symbol-function 'llemar--queue-display)
               (lambda (&rest _) (ert-fail "Unexpected display request"))))
      (llemar--handle-event '((type . "tool_execution_end")
                             (toolCallId . "failed") (toolName . "open_buffer")
                             (isError . t)))
      (llemar--handle-event '((type . "tool_execution_end")
                             (toolCallId . "other") (toolName . "read"))))))

(ert-deftest llemar-test-editor-error-drawer-is-safe ()
  "Editor diagnostics stay under the tool, never become Org structure."
  (llemar-test-with-conversation "basic" "hello"
    (let* ((marker (llemar--tool-marker "error" "open_buffer"))
           (headings (llemar-test--headings)))
      (llemar--editor-error marker "bad\n* injected\n:END:\n#+end_example")
      (should (= (how-many "^:LLEMAR_ERROR:" (point-min) (point-max)) 1))
      (should-not (member "injected" (llemar-test--headings)))
      (should (equal headings (llemar-test--headings)))
      (save-excursion
        (goto-char marker)
        (search-backward ":LLEMAR_ERROR:")
        (forward-line 1)
        (should (llemar-test--folded-p (point)))))))

(ert-deftest llemar-test-open-buffer-queue-order-and-invalidation ()
  "Consume once in completion order and discard queued work on restart."
  (llemar-test-with-conversation "basic" "hello"
    (let ((calls nil))
      (cl-letf (((symbol-function 'llemar--display-file)
                 (lambda (details) (push (alist-get 'path details) calls))))
        (dolist (id '("second" "first" "second"))
          (llemar--queue-display
           `((toolCallId . ,id) (result . ((details . ((path . ,id))))))))
        (llemar--drain-displays (current-buffer) llemar--process)
        (should (equal (reverse calls) '("second" "first")))
        (llemar--queue-display '((toolCallId . "stale")))
        (llemar--cancel-displays)
        (should-not llemar--display-queue)
        (should-not llemar--display-timer)
        (should (= (hash-table-count llemar--display-seen) 0))))))

(ert-deftest llemar-test-open-buffer-hidden-and-symlink-escape ()
  "Hidden conversations and paths escaping through symlinks are rejected."
  (llemar-test-with-window-setup
    (setq conversation (llemar llemar-test-directory))
    (with-current-buffer conversation
      (let ((link (make-temp-name (expand-file-name "escape-" default-directory))))
        (unwind-protect
            (progn
              (make-symbolic-link "/etc/hosts" link)
              (should-error (llemar--display-file
                             `((version . 1) (action . "open_file") (path . ,link))))
              (set-window-buffer (selected-window) scratch)
              (should-error (llemar--display-file
                             `((version . 1) (action . "open_file")
                               (path . ,llemar-test-mock)))))
          (delete-file link))))))

(ert-deftest llemar-test-open-buffer-history-is-passive ()
  "Saved display requests render without enqueuing editor actions."
  (llemar-test-with-conversation "basic" "hello"
    (cl-letf (((symbol-function 'llemar--queue-display)
               (lambda (&rest _) (ert-fail "Historical result dispatched"))))
      (llemar--replay-message
       `((role . "toolResult") (toolCallId . "historical")
         (toolName . "open_buffer")
         (content . (((type . "text") (text . "Display requested."))))
         (details . ((version . 1) (action . "open_file")
                     (path . ,llemar-test-mock))))))))

(ert-deftest llemar-test-open-buffer-bad-details-stay-in-transcript ()
  "Malformed results produce local drawers without breaking later events."
  (llemar-test-with-conversation "basic" "hello"
    (llemar--handle-event
     '((type . "tool_execution_end") (toolName . "open_buffer")
       (toolCallId . "malformed") (result . ((details . "not an object")))))
    (llemar--drain-displays (current-buffer) llemar--process)
    (should (string-match-p ":LLEMAR_ERROR:" (buffer-string)))
    (llemar--handle-event '((type . "agent_settled")))
    (should-not llemar--busy)))

(ert-deftest llemar-test-open-buffer-preserves-other-conversations ()
  "Never reuse another conversation window as the file display target."
  (llemar-test-with-window-setup
    (setq conversation (llemar llemar-test-directory))
    (let* ((other (generate-new-buffer " *other-llemar*"))
           (other-window (split-window)))
      (unwind-protect
          (progn
            (with-current-buffer other (llemar-mode))
            (set-window-buffer other-window other)
            (with-current-buffer conversation
              (llemar--display-file
               `((version . 1) (action . "open_file") (path . ,llemar-test-mock))))
            (should (eq (window-buffer other-window) other)))
        (kill-buffer other)))))

;;;; Conversation mode line

(ert-deftest llemar-test-mode-line-native-data ()
  "Show identity and native pi usage, with the approved faces."
  (llemar-test-with-conversation "status" "Work"
    (should (llemar-test--wait (lambda () llemar--session-stats)
                              llemar--process))
    (let ((left (llemar--mode-line-left 120))
          (right (llemar--mode-line-right)))
      (should (string-match-p "test  \"A quoted session\" │ Mock Model │ User" left))
      (should (eq (get-text-property 0 'face left) 'bold))
      (should (equal right "~$0.45  60k/200k (30%)"))
      (should (string-match-p "Estimated" (get-text-property 0 'help-echo right)))
      ;; :eval strings still interpret mode-line %-constructs.
      (should (string-match-p "30%%" (format "%s" (llemar--mode-line))))
      (llemar--registry-put llemar--session-id :name "100% complete")
      (should (string-match-p "100%% complete"
                              (format "%s" (llemar--mode-line))))
      (llemar--registry-put llemar--session-id :name "A quoted session")
      (should (local-variable-p 'mode-line-format))
      (should (string-match-p "A quoted session" (format "%s" (llemar--mode-line)))))
    (delete-process llemar--process)
    (should (llemar-test--wait (lambda () (equal llemar--status "dead"))))
    (should (string-match-p "Disconnected" (llemar--mode-line-left 120)))))

(ert-deftest llemar-test-mode-line-transitions ()
  "Native events distinguish participants, parallel tools and recovery."
  (let ((original (symbol-function 'llemar--handle-event))
        observations)
    (cl-letf (((symbol-function 'llemar--handle-event)
               (lambda (record &optional raw)
                 (funcall original record raw)
                 (push (cons (alist-get 'type record)
                             (llemar--mode-line-left 120)) observations))))
      (llemar-test-with-conversation "status" "Work"
        (dolist (pair '(("agent_start" . "Assistant")
                        ("tool_execution_start" . "Tool: read")
                        ("auto_retry_start" . "Retrying")
                        ("compaction_start" . "Compacting")
                        ("agent_settled" . "User")))
          (should (string-match-p (cdr pair) (cdr (assoc (car pair) observations)))))
        (let ((ends (reverse (seq-filter
                              (lambda (item) (equal (car item) "tool_execution_end"))
                              observations))))
          (should (string-match-p "Tool: read" (cdar ends)))
          (should (string-match-p "Assistant" (cdr (cadr ends)))))))))

(ert-deftest llemar-test-mode-line-unknown-and-narrow ()
  "Never fabricate unknown usage, and shorten identity before metrics."
  (llemar-test-with-conversation "status-unknown" "Work"
    (should (llemar-test--wait (lambda () llemar--session-stats)
                              llemar--process))
    (should (equal (llemar--mode-line-right) "~$—  —/200k (—%)"))
    (llemar--registry-put llemar--session-id
                          :name "A very long session title that must truncate")
    (let ((left (llemar--mode-line-left 42)))
      (should (<= (string-width left) 42))
      (should (string-match-p "User" left))
      (should (string-match-p "…" left)))
    (llemar-restart)
    (should-not llemar--session-stats)
    (should (llemar-test--wait (lambda () llemar--session-stats)
                              llemar--process))
    (should (string-match-p "User" (llemar--mode-line-left 120)))))

(provide 'llemar-tests)

;;; llemar-tests.el ends here
