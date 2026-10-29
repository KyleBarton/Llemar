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

(ert-deftest llemar-test-folding-leaves-structure-visible ()
  "Headlines, prose, and the block delimiters themselves stay visible."
  (llemar-test-with-conversation "basic" "go"
    (dolist (regexp '("^\\* User$" "^\\* Assistant$" "^\\*\\* bash$"
                      "^:THINKING:$" "^#\\+begin_src json$"
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
    (llemar-test--goto "^\\* User$")
    (goto-char (point-max))
    (should-not (llemar-test--folded-p (max (point-min) (1- (point)))))))

(ert-deftest llemar-test-folding-can-be-disabled ()
  "With the fold options off, drawers and blocks stay open."
  (let ((llemar-fold-thinking nil)
        (llemar-fold-blocks nil))
    (llemar-test-with-conversation "basic" "go"
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
                   '("User" "Assistant" "bash" "Assistant" "User")))))

(ert-deftest llemar-test-hostile-prose-makes-no-headlines ()
  "Markdown bold and bullets at column 0 cannot become headlines."
  (llemar-test-with-conversation "basic" "go"
    (should (equal (llemar-test--headings)
                   '("User" "Assistant" "bash" "Assistant" "User")))
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
                   '("User" "Assistant" "bash" "Assistant" "User")))
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
                   '("User" "Assistant" "bash" "read_file" "User")))
    (dolist (probe '(("bash" . "line 1") ("read_file" . "An LL(m)")))
      (llemar-test--goto (format "^\\*\\* %s$" (car probe)))
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
                         '("User" "Assistant" "bash" "Assistant" "User")))
          (should (string-match-p "Summarise the repo" (buffer-string)))
          (should (string-match-p "README.md" (buffer-string)))
          (should (string-match-p "^:THINKING:$" (buffer-string)))
          ;; A would-be headline in replayed prose cannot restructure the doc.
          (should (string-match-p "^ \\* not a heading$" (buffer-string)))
          (should-not (member "not a heading" (llemar-test--headings)))
          (should-not llemar--busy)
          (should (string-match-p "\\* User\n\\'" (buffer-string))))
      (kill-buffer buffer))))

(provide 'llemar-tests)

;;; llemar-tests.el ends here
