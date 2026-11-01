;;; llemar.el --- Talk to a pi agent in an org buffer  -*- lexical-binding: t; -*-

;; Author: Kyle Barton
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

;;; Commentary:

;; Llemar is an Emacs front end for pi (https://pi.dev), a minimal agent
;; harness.  It runs `pi --mode rpc' as a subprocess per conversation buffer
;; and renders the session into an org-mode document: user prompts, assistant
;; text, thinking drawers, and tool calls with their results, all as a
;; foldable org tree.
;;
;; Usage:
;;
;;   M-x llemar               start a conversation in the current window
;;   M-x llemar-other-window  start one in another window
;;   M-x llemar-resume        reopen a session Llemar has driven before
;;   C-u M-x llemar           prompt for the agent's working directory
;;
;; In a Llemar buffer, type under the trailing "* User" heading and press
;; C-c C-c to send.  The reply streams in below it.
;;
;;   C-c C-c  send the trailing user prompt
;;   C-c C-k  abort the current run
;;   C-c C-s  steer a running agent
;;   C-c C-n  start a fresh session
;;   C-c C-r  restart the pi process
;;   C-c C-i  report session state
;;   C-c C-l  show the pi stderr log
;;
;; The buffer is an ordinary org buffer, so folding, links, export, and C-x C-w
;; all work as usual.

;;; Code:

(require 'org)
(require 'json)
(require 'seq)
(require 'cl-lib)
(require 'subr-x)

;;;; Customization

(defgroup llemar nil
  "Emacs front end for the pi agent harness."
  :group 'tools
  :prefix "llemar-")

(defcustom llemar-executable "pi"
  "Name of or path to the pi executable."
  :type 'string)

(defcustom llemar-extra-args nil
  "Extra command line arguments passed to pi.

Llemar always supplies `--mode rpc'.  Use this for things like
\\=(\"--provider\" \"anthropic\" \"--model\" \"claude-opus-5\")."
  :type '(repeat string))

(defcustom llemar-buffer-name-function #'llemar-default-buffer-name
  "Function returning the buffer name for a conversation.
Called with one argument, the agent's working directory."
  :type 'function)

(defcustom llemar-session-directory
  (expand-file-name "llemar/sessions/" user-emacs-directory)
  "Directory for automatically saved Org conversation transcripts.
These are preview copies; pi's session files remain the source of truth
when resuming.  Transcripts may contain sensitive prompts and tool output."
  :type 'directory)

(defcustom llemar-max-tool-result-lines 100
  "Maximum number of lines of tool output to insert into the buffer.
Longer results are truncated with a note.  Set to nil to insert everything."
  :type '(choice (const :tag "No limit" nil) integer))

(defcustom llemar-show-thinking t
  "Whether to render assistant thinking blocks into a THINKING drawer."
  :type 'boolean)

(defcustom llemar-fold-thinking t
  "Whether to collapse a thinking drawer once the agent finishes it.
The drawer streams in visibly and folds when complete."
  :type 'boolean)

(defcustom llemar-fold-blocks t
  "Whether to collapse tool argument and result blocks as they are written."
  :type 'boolean)

(defcustom llemar-follow-output t
  "Whether windows showing the conversation scroll to follow streaming output.
When non-nil, any window whose point sits at the end of the buffer tracks
the response as it streams in, so the window stays on the latest output.
A window scrolled up to read earlier output is left undisturbed."
  :type 'boolean)

(defcustom llemar-user-heading "User"
  "Headline text marking a user prompt."
  :type 'string)

(defcustom llemar-assistant-heading "Assistant"
  "Headline text marking an assistant response."
  :type 'string)

;;;; Buffer-local state

(defconst llemar--extension-file
  (expand-file-name "pi-extensions/llemar.ts"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Absolute path to Llemar's companion pi extension.")

(defvar-local llemar--display-root nil
  "Canonical launch root allowed for editor display requests.")

(defvar-local llemar--display-seen nil
  "Tool call IDs already consumed in this process generation.")

(defvar-local llemar--display-queue nil
  "Pending editor actions in completion order.")

(defvar-local llemar--display-timer nil
  "Timer draining pending editor actions outside the process filter.")

(defvar-local llemar--process nil
  "The pi RPC process serving this buffer.")

(defvar-local llemar--insert-marker nil
  "Marker where streamed assistant output is appended.")

(defvar-local llemar--tool-markers nil
  "Hash table mapping a tool call id to a marker in this buffer.")

(defvar-local llemar--callbacks nil
  "Hash table mapping a request id to a response callback.")

(defvar-local llemar--request-counter 0
  "Counter used to mint unique RPC request ids.")

(defvar-local llemar--message-markers nil
  "Message identities mapped to their rendered heading markers.")

(defvar-local llemar--pending-user-marker nil
  "Heading of a submitted prompt not yet consumed by pi.")

(defvar-local llemar--compacting nil
  "Non-nil while a compaction command or event is in progress.")

(defvar-local llemar--busy nil
  "Non-nil while the agent is running.")

(defvar-local llemar--status nil
  "Short string describing what the agent is doing, or nil.")

(defvar-local llemar--streamed-blocks nil
  "Hash table of content indices that received streaming deltas.")

(defvar-local llemar--session-id nil
  "The pi session id this buffer is currently driving, if known.")

(defvar-local llemar--model-name nil
  "Display name of the model reported by pi.")

(defvar-local llemar--session-stats nil
  "Latest native pi session cost and context statistics.")

(defvar-local llemar--active-tools nil
  "Alist of currently executing tool call IDs and names.")

(defvar-local llemar--run-error nil
  "Non-nil when the latest assistant response failed.")

;;;; Session registry

(defvar llemar-session-registry nil
  "Sessions Llemar has driven, available for `llemar-resume'.

An alist keyed by pi session id; each value is a plist with :cwd, :file,
:name, :label, :org-file, and :time.  Only sessions Llemar itself started are
tracked here; sessions created in pi's own interface are not.

Add it to `savehist-additional-variables' to keep it across Emacs
sessions; Llemar does this automatically once `savehist' is loaded.")

(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'llemar-session-registry))

(defun llemar--one-line (text max)
  "Collapse TEXT to a single line and truncate it to MAX characters."
  (let ((flat (replace-regexp-in-string "[ \t\r\n]+" " " (string-trim text))))
    (if (> (length flat) max)
        (concat (substring flat 0 max) "\u2026")
      flat)))

(defun llemar--rename-session-buffer (name)
  "Rename the current conversation and its log using a slug of NAME.
Limit the slug to 36 characters, trimming trailing hyphens.
Leave the buffer names unchanged when NAME has no letters or digits."
  (when name
    (let* ((slug (string-trim
                  (replace-regexp-in-string
                   "[^[:alnum:]]+" "-" (downcase name))
                  "-+" "-+"))
           (slug (string-trim-right
                  (substring slug 0 (min 36 (length slug))) "-+"))
           (target (format "*llemar: %s*" slug)))
      (unless (or (string-empty-p slug) (equal (buffer-name) target))
        (let ((log (get-buffer (llemar--log-buffer-name (current-buffer)))))
          (rename-buffer target t)
          (when log
            (let ((log-name (llemar--log-buffer-name (current-buffer))))
              (with-current-buffer log
                (rename-buffer log-name t)))))))))

(defun llemar--registry-put (id &rest props)
  "Record session ID in `llemar-session-registry', updating it with PROPS.
PROPS is a plist; a nil value is ignored so a missing field never
clobbers one already known.  The entry's :time is always refreshed.
For the current session, rename the buffer using its name or label."
  (when id
    (let ((entry (assoc id llemar-session-registry)))
      (unless entry
        (setq entry (list id))
        (push entry llemar-session-registry))
      (let ((plist (cdr entry)))
        (while props
          (let ((key (pop props)) (value (pop props)))
            (when value
              (setq plist (plist-put plist key value)))))
        (setcdr entry (plist-put plist :time (current-time)))
        (when (equal id llemar--session-id)
          (llemar--rename-session-buffer
           (or (plist-get plist :name) (plist-get plist :label)))))))
  id)

(defun llemar--record-session ()
  "Ask pi for this buffer's session identity and record it.

The session id is not announced in the event stream, so it is read with
`get_state' whenever the identity is established: at process start and
after `new_session' or a resume."
  (when (llemar--process-live-p)
    (let ((cwd (file-name-as-directory (expand-file-name default-directory))))
      ;; A send can still race the process dying during startup.
      (ignore-errors
        (llemar--send
         '((type . "get_state"))
         (lambda (response)
           (when (alist-get 'success response)
             (let* ((data (alist-get 'data response))
                    (id (alist-get 'sessionId data))
                    (model (alist-get 'model data)))
               (setq llemar--model-name
                     (or (alist-get 'name model) (alist-get 'id model)))
               (force-mode-line-update)
               (when id
                 (setq llemar--session-id id)
                 (llemar--registry-put id
                                       :cwd cwd
                                       :file (alist-get 'sessionFile data)
                                       :name (alist-get 'sessionName data)))))))))))

(defun llemar--registry-sessions (&optional directory)
  "Return registry entries, most recently active first.
With DIRECTORY, keep only sessions recorded for it."
  (let ((dir (and directory
                  (file-name-as-directory (expand-file-name directory)))))
    (sort (seq-filter
           (lambda (entry)
             (or (null dir)
                 (equal (plist-get (cdr entry) :cwd) dir)))
           (copy-sequence llemar-session-registry))
          (lambda (a b)
            (time-less-p (or (plist-get (cdr b) :time) 0)
                         (or (plist-get (cdr a) :time) 0))))))

(defun llemar--session-display (entry)
  "Return a picker label for registry ENTRY."
  (let ((plist (cdr entry)))
    (format "%s  %s"
            (format-time-string "%Y-%m-%d %H:%M" (or (plist-get plist :time) 0))
            (or (plist-get plist :name)
                (plist-get plist :label)
                (car entry)))))

(declare-function consult--read "consult")
(declare-function consult--file-preview "consult")

(defun llemar--save-transcript ()
  "Save an Org preview copy of this conversation, when its id is known.
Failures are logged rather than interrupting the RPC event stream."
  (when llemar--session-id
    (condition-case err
        (let* ((directory (file-name-as-directory
                           (expand-file-name llemar-session-directory)))
               (file (expand-file-name
                      (concat (secure-hash 'sha256 llemar--session-id) ".org")
                      directory))
               (coding-system-for-write 'utf-8-unix))
          (make-directory directory t)
          (let ((temporary (make-temp-file
                            (expand-file-name ".transcript-" directory))))
            (unwind-protect
                (progn
                  (save-restriction
                    (widen)
                    (write-region (point-min) (point-max) temporary nil 'silent))
                  (rename-file temporary file t))
              (when (file-exists-p temporary) (delete-file temporary))))
          (llemar--registry-put llemar--session-id :org-file file))
      (error (llemar--log (current-buffer)
                          (format "transcript save failed: %s"
                                  (error-message-string err)))))))

(defun llemar--session-preview (choices)
  "Create a Consult preview state for session CHOICES."
  (let ((preview (consult--file-preview)))
    (lambda (action candidate)
      (let ((file (plist-get (cdr (cdr (assoc candidate choices))) :org-file)))
        (funcall preview action (and file (file-readable-p file) file))))))

(defun llemar--read-session (&optional directory)
  "Read a recorded session to resume, limited to DIRECTORY when non-nil.
Return the chosen registry entry, or signal a `user-error' if none exist."
  (let* ((sessions (llemar--registry-sessions directory))
         (choices (mapcar (lambda (entry)
                            (cons (llemar--session-display entry) entry))
                          sessions)))
    (unless choices
      (user-error "No Llemar sessions recorded%s"
                  (if directory (format " for %s" directory) "")))
    (let* ((completion-extra-properties
            '(:display-sort-function identity :cycle-sort-function identity))
           (candidates (mapcar #'car choices))
           (choice (if (require 'consult nil t)
                       (consult--read candidates
                                      :prompt "Resume session: "
                                      :sort nil :require-match t
                                      :category 'llemar-session
                                      :state (llemar--session-preview choices))
                     (completing-read "Resume session: " candidates nil t))))
      (cdr (assoc choice choices)))))

;;;; Process management

(defun llemar-default-buffer-name (directory)
  "Return a conversation buffer name for DIRECTORY."
  (format "*llemar: %s*"
          (file-name-nondirectory (directory-file-name directory))))

(defun llemar--log-buffer-name (buffer)
  "Return the name of the stderr log buffer for BUFFER."
  (format "*llemar-log: %s*" (buffer-name buffer)))

(defun llemar--process-live-p (&optional buffer)
  "Return non-nil if BUFFER has a live pi process."
  (with-current-buffer (or buffer (current-buffer))
    (and llemar--process (process-live-p llemar--process))))

(defun llemar--start-process (&optional session)
  "Start a pi RPC process for the current buffer.
When SESSION is non-nil, pass it to pi as the `--session' argument to
resume that session file or id."
  (when (llemar--process-live-p)
    (user-error "This buffer already has a running pi process"))
  (unless (executable-find llemar-executable)
    (user-error "Cannot find `%s'.  Install pi from https://pi.dev"
                llemar-executable))
  (llemar--cancel-displays)
  (setq llemar--model-name nil llemar--session-stats nil
        llemar--active-tools nil llemar--run-error nil)
  (setq llemar--display-root (file-name-as-directory (file-truename default-directory)))
  (let* ((conversation (current-buffer))
         (process-environment (copy-sequence process-environment))
         (_ (setenv "LLEMAR_ROOT" llemar--display-root))
         (log (get-buffer-create (llemar--log-buffer-name conversation)))
         (args (append (list "--mode" "rpc" "--extension" llemar--extension-file)
                       (when session (list "--session" session))
                       llemar-extra-args))
         (process
          (make-process
           :name (format "llemar-pi: %s" (buffer-name conversation))
           :buffer nil
           :command (cons llemar-executable args)
           :connection-type 'pipe
           :coding '(utf-8-unix . utf-8-unix)
           :noquery t
           :stderr log
           :filter #'llemar--process-filter
           :sentinel #'llemar--process-sentinel)))
    (process-put process 'llemar-conversation conversation)
    (process-put process 'llemar-pending "")
    (setq llemar--process process)
    (llemar--set-status nil)
    (llemar--record-session)
    (llemar--refresh-stats)
    process))

(defun llemar--process-sentinel (process event)
  "Report EVENT for PROCESS in its conversation buffer."
  (let ((conversation (process-get process 'llemar-conversation)))
    (when (buffer-live-p conversation)
      (with-current-buffer conversation
        (when (and (eq process llemar--process) (not (process-live-p process)))
          (llemar--cancel-displays)
          (setq llemar--busy nil llemar--compacting nil
                llemar--pending-user-marker nil)
          (llemar--set-status "dead")
          (llemar--note (format "pi process %s" (string-trim event))))))))

(defun llemar--process-filter (process chunk)
  "Accumulate CHUNK from PROCESS and dispatch whole JSONL records.

Records are split on LF only, as the pi RPC protocol requires: Unicode
line and paragraph separators are legal inside JSON strings and must not
be treated as record boundaries."
  (let* ((pending (concat (process-get process 'llemar-pending) chunk))
         (lines (split-string pending "\n"))
         ;; The final element is either an incomplete record or "".
         (leftover (car (last lines)))
         (complete (butlast lines))
         (conversation (process-get process 'llemar-conversation)))
    (process-put process 'llemar-pending leftover)
    (when (and (buffer-live-p conversation)
               (eq process (buffer-local-value 'llemar--process conversation)))
      (dolist (line complete)
        (let ((line (string-remove-suffix "\r" line)))
          (unless (string-empty-p (string-trim line))
            (let ((record (llemar--parse-json line)))
              (if record
                  (with-current-buffer conversation
                    (condition-case err
                        (llemar--handle-record record line)
                      ;; Keep consuming the stream: a rendering failure
                      ;; must not strand the session.
                      (error
                       (llemar--log conversation
                                    (format "error rendering %s: %s\n  %s"
                                            (alist-get 'type record)
                                            (error-message-string err)
                                            line)))))
                (llemar--log conversation
                             (format "unparseable record: %s" line))))))))))

(defun llemar--parse-json (string)
  "Parse STRING as a protocol record, or return nil on failure."
  (condition-case nil
      (json-parse-string string
                         :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (error nil)))

(defun llemar--log (conversation text)
  "Append TEXT to the stderr log buffer belonging to CONVERSATION."
  (with-current-buffer (get-buffer-create (llemar--log-buffer-name conversation))
    (goto-char (point-max))
    (insert text "\n")))

;;;; Sending commands

(defun llemar--send (command &optional callback)
  "Send COMMAND, an alist, to this buffer's pi process.
CALLBACK, if given, is called in this buffer with the response record."
  (unless (llemar--process-live-p)
    (user-error "No live pi process in this buffer (C-c C-r to restart)"))
  (let* ((id (format "r%d" (cl-incf llemar--request-counter)))
         (record (cons (cons 'id id) command)))
    (when callback
      (puthash id callback llemar--callbacks))
    (process-send-string llemar--process (concat (json-serialize record) "\n"))
    id))

;;;; Buffer rendering helpers

(defun llemar--marker ()
  "Return the live insertion marker for this buffer."
  (unless (and (markerp llemar--insert-marker)
               (marker-position llemar--insert-marker))
    (setq llemar--insert-marker (copy-marker (point-max) t)))
  llemar--insert-marker)

(defun llemar--insert (marker text)
  "Insert TEXT at MARKER, keeping org structure intact.

Any line of TEXT that would begin a new headline at column 0 is
prefixed with a space, so assistant prose such as a markdown \"**bold**\"
run cannot silently restructure the document."
  (when (and text (not (string-empty-p text)))
    (save-excursion
      (goto-char marker)
      (let ((scan (copy-marker (line-beginning-position) nil)))
        (insert text)
        (save-excursion
          (goto-char scan)
          (while (< (point) marker)
            (when (and (bolp) (eq (char-after) ?*))
              (insert " "))
            (forward-line 1)))
        (set-marker scan nil)))))

(defun llemar--insert-newline (marker)
  "Ensure MARKER sits at the beginning of a line."
  (save-excursion
    (goto-char marker)
    (unless (bolp)
      (insert "\n"))))

(defun llemar--insert-heading (marker level title)
  "Insert an org heading of LEVEL with TITLE at MARKER."
  (llemar--insert-newline marker)
  (save-excursion
    (goto-char marker)
    (unless (or (bobp)
                (save-excursion (forward-line -1) (looking-at-p "^[ \t]*$")))
      (insert "\n"))
    (insert (make-string level ?*) " " title "\n")))

(defun llemar--note (text)
  "Insert TEXT as an org comment line at the insertion marker."
  (let ((marker (llemar--marker)))
    (llemar--insert-newline marker)
    (save-excursion
      (goto-char marker)
      (insert "# " text "\n"))))

(defun llemar--escape-block-body (text)
  "Escape TEXT so it cannot escape the org block containing it.

Inside a block, org still scans for headlines and for block terminators,
so lines beginning with asterisks or `#+\=' are escaped with a leading
comma.  Org strips that comma again on display and export."
  (replace-regexp-in-string "^\\(,*\\(?:\\*+\\|#\\+\\)\\)" ",\\1" text))

(defun llemar--truncate (text max-lines)
  "Truncate TEXT to MAX-LINES lines, noting how much was dropped."
  (if (null max-lines)
      text
    (let ((lines (split-string text "\n")))
      (if (<= (length lines) max-lines)
          text
        (concat (string-join (seq-take lines max-lines) "\n")
                (format "\n... (%d more lines)"
                        (- (length lines) max-lines)))))))

(defun llemar--insert-block (marker begin body &optional end preserve-whitespace)
  "Insert an org block at MARKER delimited by BEGIN and END around BODY.
The block is collapsed unless `llemar-fold-blocks\=' is nil.
With PRESERVE-WHITESPACE, retain BODY's trailing spaces and blank lines."
  (let ((end (or end "#+end_example")))
    (llemar--insert-newline marker)
    (save-excursion
      (goto-char marker)
      (let ((start (point)))
        (insert begin "\n"
                (llemar--escape-block-body
                 (if preserve-whitespace
                     (string-remove-suffix "\n" body)
                   (string-trim-right body)))
                (if (and preserve-whitespace (string-empty-p body)) "" "\n")
                end "\n")
        (when llemar-fold-blocks
          (llemar--fold start 'block))))))

(defun llemar--display-arguments (call raw)
  "Return the arguments of tool CALL for display.

Protocol records are parsed with JSON null and false both mapped onto
nil so that elisp truth tests work, but that conflates null, false, and
the empty object.  Re-parsing RAW with the default sentinels keeps a
tool\='s arguments faithful to what the agent actually sent."
  (or (and raw
           (let ((faithful
                  (condition-case nil
                      ;; Arrays stay vectors: as lists they would be
                      ;; indistinguishable from alists on the way back out,
                      ;; and `json-serialize' would read an array element
                      ;; as an object key and signal.
                      (json-parse-string raw :object-type 'alist
                                         :array-type 'array)
                    (error nil))))
             (thread-last
               faithful
               (alist-get 'assistantMessageEvent)
               (alist-get 'toolCall)
               (alist-get 'arguments))))
      (alist-get 'arguments call)))

(defun llemar--fold (position kind)
  "Collapse the drawer or block beginning at POSITION.
KIND is `drawer\=' or `block\='.

Org applies the `#+startup:\=' visibility settings when a buffer is first
visited, which is long before a reply streams in, so anything written
here has to be folded explicitly."
  (save-excursion
    (goto-char position)
    (ignore-errors
      (pcase kind
        ('drawer (org-fold-hide-drawer-toggle t t))
        ('block (org-fold-hide-block-toggle t t))))))

(defun llemar--json-pretty (object)
  "Return OBJECT serialized as indented JSON, or nil if it cannot be.
OBJECT comes off the wire, so an unexpected shape degrades to no
preview rather than breaking the transcript."
  (condition-case nil
      (with-temp-buffer
        (insert (json-serialize object))
        (ignore-errors (json-pretty-print-buffer))
        (buffer-string))
    (error nil)))

;;;; Conversation mode line

(defun llemar--refresh-stats ()
  "Refresh cached usage from pi, never from mode-line redisplay."
  (when (llemar--process-live-p)
    (ignore-errors
      (llemar--send
       '((type . "get_session_stats"))
       (lambda (response)
         (when (alist-get 'success response)
           (setq llemar--session-stats (alist-get 'data response))
           (force-mode-line-update)))))))

(defun llemar--mode-line-turn ()
  "Return the conversation turn label with its theme-aware face."
  (let* ((status llemar--status)
         (label
          (cond ((equal status "dead") "Disconnected")
                ((equal status "compacting") "Compacting")
                ((equal status "retrying") "Retrying")
                ((equal status "sending") "Sending")
                ((equal status "aborting") "Aborting")
                (llemar--active-tools
                 (concat "Tool: " (cdar llemar--active-tools)))
                ((or llemar--run-error (equal status "error")) "Error")
                (llemar--busy "Assistant")
                (t "User")))
         (face (cond ((member label '("Disconnected" "Error")) 'error)
                     ((member label '("Compacting" "Retrying" "Aborting"))
                      'warning)
                     ((equal label "User") 'success)
                     (t 'font-lock-keyword-face))))
    (propertize label 'face (list :inherit face :weight 'bold))))

(defun llemar--mode-line-left (width)
  "Render identity and activity within WIDTH columns.
Shorten the quoted title first, then identity; keep the turn visible."
  (let* ((project (file-name-nondirectory
                   (directory-file-name default-directory)))
         (entry (cdr (assoc llemar--session-id llemar-session-registry)))
         (title (llemar--one-line (or (plist-get entry :name) "Untitled") 200))
         (model (or llemar--model-name "—"))
         (turn (llemar--mode-line-turn))
         (fixed (+ (string-width project) (string-width model)
                   (string-width turn) 11))
         (title (truncate-string-to-width title (max 0 (- width fixed))
                                          nil nil "…"))
         (identity (concat (propertize project 'face 'bold)
                           "  \"" title "\" "
                           (propertize (concat "│ " model " │") 'face 'shadow)))
         (budget (max 0 (- width (string-width turn) 1))))
    (concat (truncate-string-to-width identity budget nil nil "…") " " turn)))

(defun llemar--token-count (count)
  "Format token COUNT compactly, or indicate unavailable data."
  (cond ((not (numberp count)) "—")
        ((>= count 1000) (format "%sk" (/ (round count) 1000)))
        (t (format "%d" count))))

(defun llemar--mode-line-right ()
  "Render estimated session spend and native context usage."
  (let* ((stats llemar--session-stats)
         (cost (alist-get 'cost stats))
         (usage (alist-get 'contextUsage stats))
         (percent (alist-get 'percent usage)))
    (propertize
     (format "~$%s  %s/%s (%s%%)"
             (if (numberp cost) (format "%.2f" cost) "—")
             (llemar--token-count (alist-get 'tokens usage))
             (llemar--token-count (alist-get 'contextWindow usage))
             (if (numberp percent) (format "%.0f" percent) "—"))
     'help-echo
     "Estimated session USD cost; context tokens / model window (percent). Not a bill."
     'mouse-face 'mode-line-highlight)))

(defun llemar--mode-line ()
  "Render the conversation mode line with right-aligned usage metrics."
  (let* ((right (llemar--mode-line-right))
         (size (string-width right))
         (width (window-total-width))
         (left (llemar--mode-line-left (max 0 (- width size 4)))))
    (list " " (replace-regexp-in-string "%" "%%" left t t)
          (propertize " " 'display
                      `(space :align-to (- right ,(1+ size))))
          (replace-regexp-in-string "%" "%%" right t t) " ")))

(defun llemar--set-status (status)
  "Set this buffer's activity STATUS and refresh the mode line."
  (setq llemar--status status)
  (force-mode-line-update))

;;;; Tool call rendering

(defun llemar--tool-marker (tool-call-id &optional tool-name)
  "Return the marker where output for TOOL-CALL-ID belongs.
Create a heading named TOOL-NAME if this tool call has not been seen.

A tool\='s arguments and its result arrive separately, and several tools
can be in flight at once, so each call keeps its own marker.  Markers
that share a position and advance on insertion would all move together,
which would file one tool\='s result under another tool\='s heading.  A
blank line after the heading keeps this call\='s marker strictly before
the shared insertion marker so the two cannot be confused."
  (or (gethash tool-call-id llemar--tool-markers)
      (let ((marker (llemar--marker)))
        (llemar--insert-heading marker 3 (or tool-name "tool"))
        (let ((section (marker-position marker)))
          (save-excursion (goto-char marker) (insert "\n"))
          (let ((own (copy-marker section t)))
            (puthash tool-call-id own llemar--tool-markers)
            own)))))

(defun llemar--render-tool-arguments (id name args)
  "Render ARGS for tool call ID named NAME.
Write calls show their proposed entire file as additions, not a change diff.
Other calls, including malformed write arguments, retain their JSON preview."
  (let* ((marker (llemar--tool-marker id name))
         (content (and (equal name "write") (listp args)
                       (alist-get 'content args)))
         (path (and (equal name "write") (listp args)
                    (alist-get 'path args))))
    (if (and (stringp content) (stringp path))
        (let* ((llemar-fold-blocks nil)
               (terminated (string-suffix-p "\n" content))
               (lines (unless (string-empty-p content)
                        (split-string (if terminated
                                          (string-remove-suffix "\n" content)
                                        content)
                                      "\n")))
               (additions (mapconcat (lambda (line) (concat "+" line))
                                     lines "\n")))
          (llemar--insert-block
           marker "#+begin_example"
           (concat "Path: " path "\nProposed file contents (entire file):"))
          (llemar--insert-block
           marker "#+begin_src diff"
           (if (string-empty-p content) ""
             (concat additions "\n"
                     (unless terminated "\\ No newline at end of file\n")))
           "#+end_src" t))
      (when-let* ((pretty (and args
                              (not (eq args :null))
                              (not (eq args :false))
                              (llemar--json-pretty args))))
        (llemar--insert-block marker "#+begin_src json" pretty "#+end_src")))))

(defun llemar--release-tool-markers ()
  "Forget the tool markers recorded for this buffer."
  (maphash (lambda (_id marker) (set-marker marker nil)) llemar--tool-markers)
  (clrhash llemar--tool-markers))

;;;; Editor display requests

(defun llemar--cancel-displays ()
  "Discard pending display actions and consumed tool IDs."
  (when (timerp llemar--display-timer)
    (cancel-timer llemar--display-timer))
  (dolist (item llemar--display-queue) (set-marker (nth 1 item) nil))
  (setq llemar--display-timer nil
        llemar--display-queue nil
        llemar--display-seen (make-hash-table :test #'equal)))

(defun llemar--editor-error (marker text)
  "Record editor failure TEXT in a drawer at tool MARKER and in the log."
  (let* ((inhibit-read-only t)
         (safe (replace-regexp-in-string "[\n\r]+" " " (truncate-string-to-width text 1000)))
         (start (marker-position marker)))
    (save-excursion
      (goto-char marker)
      (insert ":LLEMAR_ERROR:\n")
      ;; A leading space prevents even hostile error text becoming Org syntax.
      (insert " " safe "\n:END:\n"))
    (llemar--fold start 'drawer)
    (llemar--log (current-buffer) (concat "editor error: " safe))
    (message "llemar: %s" safe)))

(defun llemar--queue-display (record)
  "Queue a live successful display RECORD exactly once."
  (let ((id (alist-get 'toolCallId record)))
    (when (and (stringp id) (llemar--process-live-p)
               (not (gethash id llemar--display-seen)))
      (puthash id t llemar--display-seen)
      (setq llemar--display-queue
            (nconc llemar--display-queue
                   (list (list (alist-get 'details (alist-get 'result record))
                               (copy-marker (llemar--tool-marker id) t)))))
      (unless llemar--display-timer
        (setq llemar--display-timer
              (run-at-time 0 nil #'llemar--drain-displays
                           (current-buffer) llemar--process))))))

(defun llemar--drain-displays (conversation process)
  "Run queued actions for CONVERSATION if PROCESS is still current."
  (when (buffer-live-p conversation)
    (with-current-buffer conversation
      (when (and (eq process llemar--process) (process-live-p process))
        (setq llemar--display-timer nil)
        (while llemar--display-queue
          (let* ((item (pop llemar--display-queue)) (marker (nth 1 item)))
            (unwind-protect
                (condition-case err
                    (llemar--display-file (car item))
                  (error (llemar--editor-error marker (error-message-string err))))
              (set-marker marker nil))))))))

(defun llemar--display-file (details)
  "Validate display DETAILS and show the file without selecting its window."
  (let* ((path (alist-get 'path details))
         (line (alist-get 'line details))
         (column (alist-get 'column details))
         (conversation (current-buffer))
         (origin (or (and (eq (window-buffer (selected-window)) conversation)
                          (selected-window))
                     (get-buffer-window conversation t))))
    (unless (and (equal (alist-get 'version details) 1)
                 (equal (alist-get 'action details) "open_file")
                 (stringp path) (not (string-empty-p path))
                 (not (file-remote-p path)) (file-name-absolute-p path)
                 (or (null line) (and (integerp line) (> line 0)))
                 (or (null column) (and line (integerp column) (> column 0))))
      (error "Invalid open_buffer display details"))
    (setq path (file-truename path))
    (unless (and llemar--display-root
                 (file-in-directory-p path llemar--display-root)
                 (file-regular-p path))
      (error "Display target must be an existing file within the launch root"))
    (unless (window-live-p origin) (error "Conversation is not visible"))
    (let* ((target (find-file-noselect path))
           (position
            (with-current-buffer target
              (save-restriction
                (widen)
                (save-excursion
                  (when line
                    (goto-char (point-min))
                    (unless (zerop (forward-line (1- line)))
                      (error "Requested line is out of range"))
                    (when column
                      (unless (<= (1- column) (- (line-end-position) (point)))
                        (error "Requested column is out of range"))
                      (forward-char (1- column))))
                  (point))))))
      (when (eq target conversation) (error "Cannot display the conversation itself"))
      (save-selected-window
        (with-selected-window origin
          (let ((window
                 (or (seq-find
                      (lambda (w)
                        (and (not (window-dedicated-p w))
                             (not (with-current-buffer (window-buffer w)
                                    (derived-mode-p 'llemar-mode)))
                             (not (minibufferp (window-buffer w)))))
                      (window-list (window-frame origin) 'no-minibuffer))
                     (split-window origin))))
            (unless (window-live-p window) (error "No suitable display window"))
            (set-window-buffer window target)
            (when line
              (with-current-buffer target (widen))
              (set-window-point window position)
              (with-selected-window window (goto-char position) (recenter)))))))))

;;;; Record dispatch

(defun llemar--windows-at-end ()
  "Return windows showing this buffer whose point sits at its end.
These are the windows that follow streamed output; a window scrolled up
has its point before `point-max' and is excluded."
  (when llemar-follow-output
    (let ((end (point-max))
          (windows nil))
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (when (>= (window-point window) end)
          (push window windows)))
      windows)))

(defun llemar--follow-output (windows)
  "Advance WINDOWS to the end of this buffer so they track new output."
  (let ((end (point-max)))
    (dolist (window windows)
      (when (window-live-p window)
        (set-window-point window end)))))

(defun llemar--handle-record (record &optional raw)
  "Dispatch a protocol RECORD arriving on stdout.
RAW is the undecoded JSON line the record was parsed from."
  (let ((followers (llemar--windows-at-end)))
    (prog1
        (if (equal (alist-get 'type record) "response")
            (llemar--handle-response record)
          (llemar--handle-event record raw))
      (llemar--follow-output followers))))

(defun llemar--handle-response (record)
  "Handle a command response RECORD."
  (let* ((id (alist-get 'id record))
         (callback (and id (gethash id llemar--callbacks))))
    (when id (remhash id llemar--callbacks))
    (unless (alist-get 'success record)
      (let ((error-text (or (alist-get 'error record) "unknown error")))
        (message "llemar: %s failed: %s"
                 (or (alist-get 'command record) "command") error-text)
        (llemar--note (format "error: %s" error-text))))
    (when callback
      (funcall callback record))))

(defun llemar--handle-event (record &optional raw)
  "Render a session event RECORD into this buffer.
RAW is the JSON line RECORD was parsed from."
  (pcase (alist-get 'type record)
    ("agent_start"
     (setq llemar--busy t llemar--active-tools nil llemar--run-error nil)
     (clrhash llemar--streamed-blocks)
     (llemar--set-status "thinking"))
    ("message_start"
     (let* ((message (alist-get 'message record))
            (role (alist-get 'role message)))
       (when (equal role "assistant")
         (setq llemar--run-error nil)
         ;; Content indices restart with each message.
         (clrhash llemar--streamed-blocks)
         (llemar--open-assistant))
       (llemar--remember-message message)
       (when (equal role "user")
         (when llemar--pending-user-marker
           (set-marker llemar--pending-user-marker nil))
         (setq llemar--pending-user-marker nil))))
    ("message_update"
     (llemar--handle-message-update (alist-get 'assistantMessageEvent record) raw))
    ("message_end"
     (let ((message (alist-get 'message record)))
       (when (equal (alist-get 'role message) "assistant")
         (setq llemar--run-error
               (equal (alist-get 'stopReason message) "error"))
         (llemar--refresh-stats)
         (force-mode-line-update))))
    ("tool_execution_start"
     (push (cons (alist-get 'toolCallId record) (alist-get 'toolName record))
           llemar--active-tools)
     (llemar--tool-marker (alist-get 'toolCallId record)
                          (alist-get 'toolName record))
     (llemar--set-status (format "%s" (alist-get 'toolName record))))
    ("tool_execution_end"
     (setq llemar--active-tools
           (assoc-delete-all (alist-get 'toolCallId record) llemar--active-tools))
     (llemar--render-tool-result record)
     (when (and (equal (alist-get 'toolName record) "open_buffer")
                (not (alist-get 'isError record)))
       (llemar--queue-display record))
     (llemar--set-status "thinking"))
    ("agent_settled"
     (when llemar--pending-user-marker
       (set-marker llemar--pending-user-marker nil))
     (setq llemar--busy nil llemar--pending-user-marker nil
           llemar--active-tools nil)
     (llemar--set-status nil)
     (llemar--record-session)
     (llemar--refresh-stats)
     (when (alist-get 'aborted record)
       (llemar--note "aborted"))
     (llemar--open-user-prompt)
     (llemar--save-transcript))
    ("auto_retry_start"
     (llemar--set-status "retrying")
     (llemar--note (format "retry %s/%s: %s"
                           (alist-get 'attempt record)
                           (alist-get 'maxAttempts record)
                           (or (alist-get 'errorMessage record) ""))))
    ("auto_retry_end"
     (llemar--set-status (if (alist-get 'success record) "thinking" nil))
     (unless (alist-get 'success record)
       (llemar--note (format "retries exhausted: %s"
                             (or (alist-get 'finalError record) "")))))
    ("compaction_start"
     (setq llemar--compacting t)
     (llemar--set-status "compacting"))
    ("compaction_end"
     (llemar--refresh-stats)
     (setq llemar--compacting nil)
     (when (equal (alist-get 'reason record) "manual")
       (setq llemar--busy nil))
     (llemar--set-status (when llemar--busy "thinking"))
     (if-let* ((result (alist-get 'result record)))
         (llemar--fetch-compaction result)
       (llemar--note
        (format "compaction did not complete: %s"
                (if (alist-get 'aborted record) "aborted"
                  (or (alist-get 'errorMessage record) "unknown error"))))
       (llemar--save-transcript)))
    ("extension_error"
     (llemar--log (current-buffer)
                  (format "extension error in %s (%s): %s"
                          (alist-get 'extensionPath record)
                          (alist-get 'event record)
                          (alist-get 'error record))))
    ("session_info_changed"
     (when llemar--session-id
       (llemar--registry-put llemar--session-id :name (alist-get 'name record)))
     (llemar--set-status llemar--status))
    (_ nil)))

(defun llemar--open-assistant ()
  "Open a heading for one assistant turn.

Every assistant message gets its own heading.  That keeps tool calls
nested under the turn that made them, and means prose the agent emits
after a tool result starts a new turn instead of landing inside the
tool\='s subtree."
  (llemar--insert-heading (llemar--marker) 2 llemar-assistant-heading))

(defun llemar--handle-message-update (event &optional raw)
  "Render a streaming assistant message EVENT.
RAW is the JSON line EVENT arrived on, used to render tool arguments
exactly as the agent sent them."
  (let ((marker (llemar--marker)))
    (pcase (alist-get 'type event)
      ("text_delta"
       (puthash (alist-get 'contentIndex event) t llemar--streamed-blocks)
       (llemar--insert marker (alist-get 'delta event)))
      ("text_end"
       ;; Providers that do not stream send no deltas; use the final content.
       (unless (gethash (alist-get 'contentIndex event) llemar--streamed-blocks)
         (llemar--insert marker (alist-get 'content event))))
      ("thinking_start"
       (when llemar-show-thinking
         (llemar--insert-newline marker)
         (save-excursion (goto-char marker) (insert ":THINKING:\n"))))
      ("thinking_delta"
       (when llemar-show-thinking
         (puthash (alist-get 'contentIndex event) t llemar--streamed-blocks)
         (llemar--insert marker (alist-get 'delta event))))
      ("thinking_end"
       (when llemar-show-thinking
         (unless (gethash (alist-get 'contentIndex event) llemar--streamed-blocks)
           (llemar--insert marker (alist-get 'content event)))
         (llemar--insert-newline marker)
         (save-excursion (goto-char marker) (insert ":END:\n"))
         (when llemar-fold-thinking
           (save-excursion
             (goto-char marker)
             (when (re-search-backward "^[ \t]*:THINKING:[ \t]*$" nil t)
               (llemar--fold (point) 'drawer))))))
      ("toolcall_start"
       (llemar--tool-marker (alist-get 'id event) (alist-get 'toolName event)))
      ("toolcall_end"
       (let* ((call (alist-get 'toolCall event))
              (id (alist-get 'id call))
              (args (llemar--display-arguments call raw)))
         (llemar--render-tool-arguments id (alist-get 'name call) args)))
      ("error"
       (llemar--note (format "stream error: %s"
                             (or (alist-get 'error event)
                                 (alist-get 'reason event)))))
      (_ nil))))

(defun llemar--render-tool-result (record)
  "Insert the tool result carried by RECORD under its tool heading."
  (let* ((id (alist-get 'toolCallId record))
         (marker (llemar--tool-marker id (alist-get 'toolName record)))
         (text (llemar--result-text (alist-get 'result record)))
         (duration (alist-get 'durationMs record)))
    (llemar--insert-block
     marker
     (if (alist-get 'isError record)
         "#+begin_example error"
       "#+begin_example")
     (llemar--truncate (if (string-empty-p (string-trim (or text "")))
                           "(no output)"
                         text)
                       llemar-max-tool-result-lines))
    (when-let* ((patch (and (equal (alist-get 'toolName record) "edit")
                           (not (alist-get 'isError record))
                           (alist-get 'patch
                                      (alist-get 'details
                                                 (alist-get 'result record)))))
                ((and (stringp patch) (not (string-blank-p patch)))))
      (let ((llemar-fold-blocks nil))
        (llemar--insert-block marker "#+begin_src diff" patch "#+end_src")))
    (when duration
      (save-excursion
        (goto-char marker)
        (insert (format "# %sms\n" duration))))))

(defun llemar--result-text (result)
  "Extract the text content of a tool RESULT."
  (string-join
   (delq nil
         (mapcar (lambda (block)
                   (when (equal (alist-get 'type block) "text")
                     (alist-get 'text block)))
                 (alist-get 'content result)))
   "\n"))

;;;; Session replay

(defun llemar--message-text (content)
  "Return the concatenated text of message CONTENT.
CONTENT is either a string or a list of content blocks."
  (cond
   ((stringp content) content)
   ((listp content)
    (string-join
     (delq nil (mapcar (lambda (block)
                         (when (equal (alist-get 'type block) "text")
                           (alist-get 'text block)))
                       content))
     ""))
   (t "")))

(defun llemar--replay-thinking (marker text)
  "Render a saved thinking block holding TEXT at MARKER."
  (when (and llemar-show-thinking text (not (string-empty-p text)))
    (llemar--insert-newline marker)
    (save-excursion (goto-char marker) (insert ":THINKING:\n"))
    (llemar--insert marker text)
    (llemar--insert-newline marker)
    (save-excursion (goto-char marker) (insert ":END:\n"))
    (when llemar-fold-thinking
      (save-excursion
        (goto-char marker)
        (when (re-search-backward "^[ \t]*:THINKING:[ \t]*$" nil t)
          (llemar--fold (point) 'drawer))))))

(defun llemar--replay-message (message)
  "Render one saved MESSAGE, an AgentMessage, into this buffer.

Only the roles that carry a transcript turn are rendered; system
messages and other context-only roles are skipped so they do not become
headings."
  (pcase (alist-get 'role message)
    ("user"
     (let ((marker (llemar--marker)))
       (llemar--insert-heading marker 2 llemar-user-heading)
       (llemar--insert marker
                       (string-trim-right
                        (llemar--message-text (alist-get 'content message))))))
    ("assistant"
     (llemar--open-assistant)
     (let ((marker (llemar--marker)))
       (dolist (block (alist-get 'content message))
         (pcase (alist-get 'type block)
           ("text" (llemar--insert marker (alist-get 'text block)))
           ("thinking"
            (llemar--replay-thinking marker (alist-get 'thinking block)))
           ("toolCall"
            (let ((id (alist-get 'id block))
                  (name (alist-get 'name block))
                  (args (alist-get 'arguments block)))
              (llemar--render-tool-arguments id name args)))))))
    ("toolResult"
     ;; Reuse the live result renderer by shaping a matching record; a
     ;; saved message carries no duration, so none is shown.
     (llemar--render-tool-result
      `((toolCallId . ,(alist-get 'toolCallId message))
        (toolName . ,(alist-get 'toolName message))
        (isError . ,(alist-get 'isError message))
        (result . ((content . ,(alist-get 'content message))
                   (details . ,(alist-get 'details message)))))))
    (_ nil))
  (llemar--remember-message message))

;;;; Compaction archives

(defun llemar--message-key (message)
  "Return a stable rendering identity for MESSAGE, or nil."
  (when (alist-get 'timestamp message)
    (list (alist-get 'role message) (alist-get 'timestamp message))))

(defun llemar--remember-message (message)
  "Associate MESSAGE with its rendered user or assistant heading."
  (let ((role (alist-get 'role message))
        (key (llemar--message-key message)))
    (when (and key (member role '("user" "assistant")))
      (save-excursion
        (goto-char (llemar--marker))
        (when (re-search-backward
               (format "^\\*\\* %s[ \t]*$"
                       (regexp-quote (if (equal role "user")
                                         llemar-user-heading
                                       llemar-assistant-heading))) nil t)
          (puthash key (copy-marker (line-beginning-position) t)
                   llemar--message-markers))))))

(defun llemar--branch-entries (data)
  "Return DATA's entries on the active branch, oldest first."
  (let ((table (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (id (alist-get 'leafId data))
        branch)
    (dolist (entry (alist-get 'entries data))
      (puthash (alist-get 'id entry) entry table))
    (while (and id (not (gethash id seen)) (gethash id table))
      (puthash id t seen)
      (let ((entry (gethash id table)))
        (push entry branch)
        (setq id (alist-get 'parentId entry))))
    branch))

(defun llemar--fetch-compaction (result)
  "Fetch pi's authoritative boundary and timestamp for compaction RESULT."
  (let ((source-end (copy-marker (or llemar--pending-user-marker
                                     (llemar--marker)))))
    (llemar--send
     '((type . "get_entries"))
     (lambda (response)
       (let* ((entries (llemar--branch-entries (alist-get 'data response)))
              (entry (seq-find
                      (lambda (item)
                        (and (equal (alist-get 'type item) "compaction")
                             (equal (alist-get 'summary item) (alist-get 'summary result))
                             (equal (alist-get 'firstKeptEntryId item)
                                    (alist-get 'firstKeptEntryId result))))
                      (reverse entries))))
         (unwind-protect
             (progn
               (llemar--archive-compaction (or entry result) entries source-end)
               (llemar--save-transcript))
           (set-marker source-end nil)))))))

(defun llemar--archive-compaction (entry entries &optional source-end)
  "Archive the source prefix described by compaction ENTRY in ENTRIES.
SOURCE-END bounds a live retain-none compaction before continued generation.
Use only a known message boundary; if it is unavailable, keep the transcript
untouched and show the actual summary with an explicit limitation."
  (let* ((kept-id (alist-get 'firstKeptEntryId entry))
         (kept (seq-find (lambda (item) (equal (alist-get 'id item) kept-id)) entries))
         (boundary (gethash (llemar--message-key (alist-get 'message kept))
                            llemar--message-markers))
         (summary (alist-get 'summary entry))
         (current (save-excursion
                    (goto-char (point-max))
                    (when (re-search-backward "^\\* Current$" nil t)
                      (copy-marker (line-beginning-position))))))
    ;; A retain-none compaction points to itself.  An unsent prompt is local
    ;; input, not part of the compacted source, and must stay under Current.
    (when (equal kept-id (alist-get 'id entry))
      (setq boundary
            (or source-end
                (copy-marker (llemar--marker)))))
    (if (not (and current boundary (stringp summary)
                  (> boundary current)))
        (progn
          (llemar--note "compaction succeeded; exact source boundary unavailable; transcript not reorganized")
          (when (stringp summary)
            (llemar--insert-block (llemar--marker) "#+begin_example" summary)))
      (let ((inhibit-read-only t)
            (end (copy-marker boundary t))
            (timestamp (alist-get 'timestamp entry)))
        (save-excursion
          ;; Demote only actual headlines.  Escaped output stays byte-for-byte
          ;; intact, and live markers continue to track retained tool output.
          (goto-char current)
          (forward-line 1)
          (while (re-search-forward "^\\*+ " end t)
            (goto-char (match-beginning 0))
            (insert "*")
            (forward-line 1))
          (goto-char current)
          (delete-region (point) (line-end-position))
          (insert "* Compacted "
                  (if timestamp
                      (format-time-string "%Y-%m-%d %H:%M:%S %z"
                                          (date-to-time timestamp) t)
                    (format-time-string "%Y-%m-%d %H:%M:%S %z" nil t)))
          (forward-line 1)
          (when (alist-get 'id entry)
            (insert ":PROPERTIES:\n:LLEMAR_COMPACTION_ID: "
                    (alist-get 'id entry) "\n:END:\n"))
          (insert "** Source\n")
          (goto-char end)
          ;; Boundary markers must follow these insertions to the retained
          ;; heading, but this temporary insertion marker advances independently.
          (let ((marker (copy-marker (point) t)))
            (llemar--insert-heading marker 2 "Summary")
            (llemar--insert-block marker "#+begin_example" summary)
            (llemar--insert-heading marker 1 "Current")
            (set-marker marker nil)))
        (set-marker end nil)))
    (when current (set-marker current nil))))

(defun llemar--replay-messages (messages)
  "Render saved MESSAGES into this buffer in order."
  (dolist (message messages)
    (llemar--replay-message message)))

(defun llemar--load-session ()
  "Reconstruct the active branch, including pre-compaction source, from pi."
  (llemar--send
   '((type . "get_entries"))
   (lambda (response)
     (let* ((data (alist-get 'data response))
            (entries (llemar--branch-entries data)))
       (if entries
           (progn
             (dolist (entry entries)
               (pcase (alist-get 'type entry)
                 ("message" (llemar--replay-message (alist-get 'message entry)))
                 ("compaction" (llemar--archive-compaction entry entries))))
             (llemar--finish-history))
         ;; Older backends may not expose raw entries.  Do not pretend their
         ;; context-only history contains the original pre-compaction source.
         (llemar--send
          '((type . "get_messages"))
          (lambda (messages-response)
            (when (alist-get 'success messages-response)
              (llemar--replay-messages
               (alist-get 'messages (alist-get 'data messages-response)))
              (llemar--note "raw session history unavailable; compacted source may be missing")
              (llemar--finish-history)))))))))

(defun llemar--finish-history ()
  "Finish loading history and prepare for another prompt."
  (llemar--open-user-prompt)
  (llemar--restore-local-archives)
  (llemar--save-transcript)
  (llemar--set-status nil))

(defun llemar--archive-regions ()
  "Return (ID START END) for this buffer's compaction subtrees, last first."
  (let (regions)
    (org-map-entries
     (lambda ()
       (when-let* ((id (org-entry-get nil "LLEMAR_COMPACTION_ID")))
         (when (= (org-outline-level) 1)
           (push (list id (point) (save-excursion (org-end-of-subtree t t)))
                 regions)))))
    regions))

(defun llemar--restore-local-archives ()
  "Reconcile saved local archives with compaction IDs on pi's active branch.
Only confirmed compaction subtrees are reused, never backend context.  This
preserves local annotations and richer historical rendering without importing
an abandoned branch.  A trailing unsent draft is restored with those archives."
  (when llemar--session-id
    (let ((file (expand-file-name
                 (concat (secure-hash 'sha256 llemar--session-id) ".org")
                 llemar-session-directory))
          (archives (make-hash-table :test #'equal))
          draft restored)
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (org-mode)
          (dolist (region (llemar--archive-regions))
            (puthash (car region)
                     (buffer-substring-no-properties (nth 1 region) (nth 2 region))
                     archives))
          (when-let* ((bounds (llemar--last-prompt-bounds)))
            (when (= (cdr bounds) (point-max))
              (setq draft (buffer-substring-no-properties (car bounds) (cdr bounds))))))
        (dolist (region (llemar--archive-regions))
          (when-let* ((text (gethash (car region) archives)))
            (save-excursion
              (goto-char (nth 1 region))
              (delete-region (nth 1 region) (nth 2 region))
              (insert text))
            (setq restored t)))
        (when (and restored draft)
          (save-excursion (goto-char (point-max)) (insert draft)))))))

;;;; Prompt handling

(defun llemar--user-heading-regexp ()
  "Return a regexp matching a current user heading."
  (format "^\\*\\* %s[ \t]*$" (regexp-quote llemar-user-heading)))

(defun llemar--last-prompt-bounds ()
  "Return (START . END) of the body under the last user heading, or nil."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward (llemar--user-heading-regexp) nil t)
      (forward-line 1)
      (let ((start (point))
            (end (if (re-search-forward "^\\*+ " nil t)
                     (match-beginning 0)
                   (point-max))))
        (cons start end)))))

(defun llemar--open-user-prompt ()
  "Append a fresh user heading and leave point ready for typing."
  (let ((marker (llemar--marker)))
    (llemar--insert-newline marker)
    (save-excursion
      (goto-char marker)
      (insert "\n** " llemar-user-heading "\n"))
    (when (eq (current-buffer) (window-buffer (selected-window)))
      (goto-char (point-max)))))

;;;; Interactive commands

(defun llemar--new-conversation (directory)
  "Create a conversation buffer for DIRECTORY and start pi inside it.
DIRECTORY defaults to `default-directory\='.  The buffer is returned
without being displayed."
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (buffer (generate-new-buffer
                  (funcall llemar-buffer-name-function directory))))
    (condition-case err
        (with-current-buffer buffer
          (setq default-directory directory)
          (llemar-mode)
          (llemar--insert-preamble)
          (llemar--start-process)
          (goto-char (point-max)))
      (error (kill-buffer buffer)
             (signal (car err) (cdr err))))
    buffer))

(defun llemar--read-directory ()
  "Return the agent's working directory, prompting given a prefix argument."
  (when current-prefix-arg
    (read-directory-name "Agent working directory: ")))

;;;###autoload
(defun llemar (&optional directory)
  "Start a conversation with a pi agent in the current window.
With a prefix argument, prompt for DIRECTORY as the agent's working
folder.  When called from a Llemar buffer, save its transcript and kill
that buffer after the new conversation starts successfully.  See
`llemar-other-window\=' to keep it and display a new conversation elsewhere."
  (interactive (list (llemar--read-directory)))
  (let ((previous (when (derived-mode-p 'llemar-mode) (current-buffer)))
        (buffer (llemar--new-conversation directory)))
    (when previous
      (kill-buffer previous))
    (pop-to-buffer-same-window buffer)
    buffer))

;;;###autoload
(defun llemar-other-window (&optional directory)
  "Start a conversation with a pi agent in another window.
With a prefix argument, prompt for DIRECTORY as the agent's working
folder.  See `llemar\=' to take over the current window instead."
  (interactive (list (llemar--read-directory)))
  (let ((buffer (llemar--new-conversation directory)))
    (pop-to-buffer buffer)
    buffer))

(defun llemar--resume-conversation (directory ref)
  "Create a buffer for DIRECTORY and start pi resuming session REF.
REF is a session file path or id passed to pi via `--session'.  The
buffer is returned without being displayed."
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (buffer (generate-new-buffer
                  (funcall llemar-buffer-name-function directory))))
    (condition-case err
        (with-current-buffer buffer
          (setq default-directory directory)
          (llemar-mode)
          (llemar--insert-preamble t)
          (llemar--start-process ref)
          (llemar--load-session)
          (goto-char (point-max)))
      (error (kill-buffer buffer)
             (signal (car err) (cdr err))))
    buffer))

;;;###autoload
(defun llemar-resume (session)
  "Resume a recorded pi SESSION in a new conversation buffer.

Interactively, choose from the sessions Llemar has driven for the
current directory; with a prefix argument, choose from every recorded
session.  The new buffer opens in the session's working directory and
its saved history is loaded and rendered, with a fresh prompt ready to
continue.  When called from a Llemar buffer, save its transcript and
kill that buffer after the resumed conversation starts successfully.

Only sessions Llemar itself started are offered; sessions created in
pi's own interface are not tracked."
  (interactive
   (list (llemar--read-session
          (unless current-prefix-arg
            (file-name-as-directory (expand-file-name default-directory))))))
  (let* ((previous (when (derived-mode-p 'llemar-mode) (current-buffer)))
         (plist (cdr session))
         (directory (or (plist-get plist :cwd) default-directory))
         (ref (or (plist-get plist :file) (car session)))
         (buffer (llemar--resume-conversation directory ref)))
    (when previous
      (kill-buffer previous))
    (pop-to-buffer-same-window buffer)
    buffer))

(defun llemar--insert-preamble (&optional no-prompt)
  "Insert the org preamble into this buffer.
Unless NO-PROMPT is non-nil, also add an empty trailing user heading.
Resuming suppresses it, then adds one after the history is rendered."
  (insert (format "#+title: llemar %s\n#+startup: hideblocks\n\n"
                  (format-time-string "%Y-%m-%d %H:%M")))
  (insert "* Current\n")
  (unless no-prompt
    (insert "** " llemar-user-heading "\n")))

(defun llemar-send ()
  "Send the prompt under the last user heading to the agent."
  (interactive)
  (when (or llemar--busy llemar--compacting)
    (user-error "Agent is running; use `llemar-steer' or `llemar-abort'"))
  (let* ((bounds (or (llemar--last-prompt-bounds)
                     (user-error "No `** %s' heading to send"
                                 llemar-user-heading)))
         (text (string-trim (buffer-substring-no-properties
                             (car bounds) (cdr bounds)))))
    (when (string-empty-p text)
      (user-error "The prompt is empty"))
    ;; The first prompt of a session becomes its picker label.
    (when (and llemar--session-id
               (not (plist-get (cdr (assoc llemar--session-id
                                           llemar-session-registry))
                               :label)))
      (llemar--registry-put llemar--session-id
                            :label (llemar--one-line text 72)))
    (llemar--save-transcript)
    (setq llemar--pending-user-marker
          (copy-marker (save-excursion
                         (goto-char (car bounds)) (forward-line -1) (point)) t))
    (set-marker (llemar--marker) (point-max))
    (llemar--release-tool-markers)
    (clrhash llemar--streamed-blocks)
    (setq llemar--busy t)
    (llemar--set-status "sending")
    (llemar--send `((type . "prompt") (message . ,text))
                  (lambda (response)
                    (unless (alist-get 'success response)
                      (when llemar--pending-user-marker
                        (set-marker llemar--pending-user-marker nil))
                      (setq llemar--busy nil llemar--pending-user-marker nil)
                      (llemar--set-status nil))))))

(defun llemar-compact (&optional custom-instructions)
  "Compact context on demand, optionally using CUSTOM-INSTRUCTIONS.
With a prefix argument, prompt for instructions.  The original transcript
is preserved; pi alone decides the summary and retained context boundary.
Wait for the current run to settle before requesting manual compaction."
  (interactive (list (when current-prefix-arg
                       (read-string "Compaction instructions: "))))
  (unless (derived-mode-p 'llemar-mode)
    (user-error "Not a Llemar conversation"))
  (when (or llemar--busy llemar--compacting)
    (user-error "Agent is busy; wait or abort before compacting"))
  (unless (llemar--process-live-p)
    (user-error "No live pi process"))
  ;; Status/error notes belong before the local draft, not in its body.
  (when-let* ((bounds (llemar--last-prompt-bounds)))
    (set-marker (llemar--marker)
                (save-excursion
                  (goto-char (car bounds)) (forward-line -1) (point))))
  (setq llemar--busy t llemar--compacting t)
  (llemar--set-status "compacting")
  (llemar--send
   (append '((type . "compact"))
           (when (and custom-instructions
                      (not (string-empty-p custom-instructions)))
             `((customInstructions . ,custom-instructions))))
   (lambda (_response)
     ;; Manual compact has no agent_settled event.  Its terminal response
     ;; also covers errors that happen before compaction_start.
     (setq llemar--busy nil llemar--compacting nil)
     (llemar--set-status nil)
     (llemar--save-transcript))))

(defun llemar-abort ()
  "Abort the agent's current run."
  (interactive)
  (llemar--send '((type . "abort")))
  (llemar--set-status "aborting"))

(defun llemar-steer (message)
  "Queue MESSAGE as a steering instruction for the running agent."
  (interactive "sSteer: ")
  (when (string-empty-p (string-trim message))
    (user-error "Nothing to steer with"))
  (llemar--send `((type . "steer") (message . ,message)))
  (let ((marker (llemar--marker)))
    (llemar--insert-newline marker)
    (save-excursion (goto-char marker) (insert ":STEERING:\n"))
    (llemar--insert marker (concat message "\n"))
    (save-excursion (goto-char marker) (insert ":END:\n"))))

(defun llemar-new-session ()
  "Start a fresh pi session, clearing the conversation buffer."
  (interactive)
  (when (or (not llemar--busy)
            (yes-or-no-p "Agent is running.  Start a new session anyway? "))
    (llemar--save-transcript)
    (llemar--send
     '((type . "new_session"))
     (lambda (response)
       (if (alist-get 'cancelled (alist-get 'data response))
           (message "llemar: new session cancelled by an extension")
         (let ((inhibit-read-only t))
           (llemar--cancel-displays)
           (erase-buffer)
           (setq llemar--busy nil llemar--compacting nil
                 llemar--pending-user-marker nil)
           (clrhash llemar--message-markers)
           (llemar--release-tool-markers)
           (clrhash llemar--streamed-blocks)
           (set-marker (llemar--marker) (point-max))
           (llemar--insert-preamble)
           (goto-char (point-max))
           (setq llemar--session-id nil llemar--session-stats nil
                 llemar--active-tools nil llemar--run-error nil)
           (llemar--set-status nil)
           (llemar--record-session)
           (llemar--refresh-stats)))))))

(defun llemar-restart ()
  "Restart the pi process for this buffer."
  (interactive)
  (when (llemar--process-live-p)
    ;; Closing stdin asks pi to shut down in an orderly way.
    (process-send-eof llemar--process)
    (delete-process llemar--process))
  (setq llemar--busy nil llemar--compacting nil
        llemar--pending-user-marker nil)
  (clrhash llemar--message-markers)
  (llemar--start-process)
  (message "llemar: pi restarted"))

(defun llemar-state ()
  "Report the agent's current session state."
  (interactive)
  (llemar--send
   '((type . "get_state"))
   (lambda (response)
     (let* ((data (alist-get 'data response))
            (model (alist-get 'model data)))
       (message "llemar: model %s, thinking %s, %s messages, session %s"
                (or (alist-get 'id model) (alist-get 'name model) "?")
                (or (alist-get 'thinkingLevel data) "?")
                (or (alist-get 'messageCount data) 0)
                (or (alist-get 'sessionId data) "?"))))))

(defun llemar-show-log ()
  "Show the pi stderr log for this conversation."
  (interactive)
  (pop-to-buffer (get-buffer-create (llemar--log-buffer-name (current-buffer)))))

;;;; Mode

(defvar-keymap llemar-mode-map
  :doc "Keymap for `llemar-mode'."
  "C-c C-c" #'llemar-send
  "C-c C-k" #'llemar-abort
  "C-c C-m" #'llemar-compact
  "C-c C-s" #'llemar-steer
  "C-c C-n" #'llemar-new-session
  "C-c C-r" #'llemar-restart
  "C-c C-i" #'llemar-state
  "C-c C-l" #'llemar-show-log)

;;;###autoload
(define-derived-mode llemar-mode org-mode "Llemar"
  "Major mode for conversing with a pi agent in an org buffer.

\\{llemar-mode-map}"
  (setq llemar--message-markers (make-hash-table :test #'equal))
  (setq llemar--tool-markers (make-hash-table :test #'equal))
  (setq llemar--callbacks (make-hash-table :test #'equal))
  (setq llemar--streamed-blocks (make-hash-table :test #'equal))
  (setq llemar--insert-marker (copy-marker (point-max) t))
  (setq-local org-hide-drawer-startup t)
  (setq-local mode-line-format '((:eval (llemar--mode-line))))
  (add-hook 'kill-buffer-hook #'llemar--save-transcript nil t)
  (add-hook 'kill-buffer-hook #'llemar--cleanup nil t))

(defun llemar--cleanup ()
  "Shut down this buffer's pi process and discard its log buffer.
Otherwise a log buffer outlives every conversation that ever ran."
  (llemar--cancel-displays)
  (when (llemar--process-live-p)
    (process-send-eof llemar--process)
    (delete-process llemar--process))
  (when-let* ((log (get-buffer (llemar--log-buffer-name (current-buffer)))))
    (kill-buffer log)))

(provide 'llemar)

;;; llemar.el ends here
