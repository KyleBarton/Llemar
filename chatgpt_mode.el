(require 'json)
(require 'request)

(defvar chatgpt-api-key ""
  "Your OpenAI API key. Defaults to empty")

(defvar chatgpt-buffer-folder "~/.chatgpt/"
  "The folder where chatgpt logs will be saved. Defaults to .chatgpt on your home folder")

(defvar chatgpt-api-retry-count 3
  "The number of times to retry the API call upon a retryable error.")

(defvar chatgpt-api-backoff-intervals '(1 3 5)
  "List of back-off intervals in seconds for each retry attempt.")

(defvar chatgpt-conversation-id (format-time-string "%Y%m%d-%H%M%S")
  "A unique identifier for the current conversation.")

(defvar chatgpt-log-buffer-name (format "*chatgpt-log-%s*" chatgpt-conversation-id)
  "The name of the chatgpt-log buffer for the current conversation.")

(defvar chatgpt-metadata-buffer-name (format "*chatgpt-metadata-%s*" chatgpt-conversation-id)
  "The name of the chatgpt-metadata buffer for the current conversation.")

(defun chatgpt-call-api (prompt)
  "Make an API call to OpenAI's GPT-4 and handle retries if necessary."
  (let ((attempt 0)
        (success nil)
        (completed nil))  ;; Track when the callback completes
    (while (and (< attempt (+ chatgpt-api-retry-count 1)) (not success))
      (setq completed nil)  ;; Reset completion tracker for each attempt
      (condition-case err
          (progn
            (request
              "https://api.openai.com/v1/chat/completions"
              :type "POST"
              :headers `(("Authorization" . ,(concat "Bearer " chatgpt-api-key))
                         ("Content-Type" . "application/json"))
              :data (json-encode
                     `(("model" . "gpt-4")
                       ("messages" . [(( "role" . "user")
                                       ("content" . ,(concat "Please respond in **this exact format** (JSON), with no deviations or additional fields:\n"
                                                             "{\n"
                                                             "  \"conversational\": \"...\",\n"
                                                             "  \"executable\": \"...\"\n"
                                                             "}\n"
                                                             "\nHere is the prompt:\n" prompt)))])
                       ("max_tokens" . 300)))
              :parser 'json-read
              :timeout 30
              :success (cl-function
                        (lambda (&key data &allow-other-keys)
                          (let* ((choices (assoc-default 'choices data))
                                 (message (assoc-default 'message (aref choices 0)))
                                 (content (assoc-default 'content message))
                                 (parsed-response (ignore-errors (json-read-from-string content)))
                                 (conversational (assoc-default 'conversational parsed-response))
                                 (executable (assoc-default 'executable parsed-response)))
                            (with-current-buffer "*chatgpt-conversational*"
                              (insert (concat (or conversational "No conversational content found.") "\n")))
                            (with-current-buffer "*chatgpt-executable*"
                              (insert (concat (or executable "No executable content found.") "\n")))
                            (with-current-buffer chatgpt-log-buffer-name
                              (goto-char (point-max))
                              (insert (format "ChatGPT: %s\n" content)))
                            ;; Mark the request as successful and complete
                            (setq success t
                                  completed t))))
              :error (cl-function
                      (lambda (&key error-thrown &key _ &allow-other-keys)
                        (with-current-buffer chatgpt-metadata-buffer-name
                          (goto-char (point-max))
                          (insert (format "Error: %s\n" error-thrown)))
                        (setq completed t)))  ;; Mark the process as complete even on error
              :complete (cl-function
                         (lambda (&key response &allow-other-keys)
                           (message "Request complete with status %s" (request-response-status-code response)))))
            ;; Wait for the callback to complete before continuing
            (while (not completed)
              (accept-process-output nil 0.1))  ;; Wait a short interval for completion
            (unless success
              (when (< attempt chatgpt-api-retry-count)
                (chatgpt-log-retry-message attempt)
                (sleep-for (nth attempt chatgpt-api-backoff-intervals)))))
        (error
         (with-current-buffer chatgpt-metadata-buffer-name
           (goto-char (point-max))
           (insert (format "Error: %s\n" (error-message-string err))))))
      (setq attempt (1+ attempt)))))



(defun chatgpt-save-log-to-file ()
  "Save the contents of the chatgpt-log buffer to a file in the specified folder."
  (interactive)
  (let ((file-name (concat chatgpt-buffer-folder "/" chatgpt-conversation-id ".txt")))
    (with-current-buffer chatgpt-log-buffer-name
      (write-region (point-min) (point-max) file-name)
      (message "ChatGPT log saved to %s" file-name))))

(defun chatgpt-save-metadata-to-file ()
  "Save the contents of the chatgpt-metadata buffer to a file in the specified folder."
  (let ((file-name (concat chatgpt-buffer-folder "/" chatgpt-conversation-id "-metadata.txt")))
    (with-current-buffer chatgpt-metadata-buffer-name
      (write-region (point-min) (point-max) file-name)
      (message "ChatGPT metadata saved to %s" file-name))))

(defun chatgpt-clear-buffers ()
  "Clear the visual response buffers."
  (with-current-buffer "*chatgpt-conversational*"
    (erase-buffer))
  (with-current-buffer "*chatgpt-executable*"
    (erase-buffer)))

(defun chatgpt-send-prompt ()
  "Send the prompt from the input buffer, update the log, and then send the entire log to the API."
  (interactive)
  (let ((prompt (buffer-substring-no-properties (point-min) (point-max))))
    ;; Insert the current prompt into the log buffer
    (with-current-buffer chatgpt-log-buffer-name
      (goto-char (point-max))
      (insert (format "User: %s\n" prompt)))
    ;; Clear the visual buffers
    (chatgpt-clear-buffers)
    ;; Send the entire log as the prompt to the API
    (let ((full-log (with-current-buffer chatgpt-log-buffer-name
                      (buffer-substring-no-properties (point-min) (point-max)))))
      (chatgpt-call-api full-log))))


(defvar chatgpt-previous-major-mode nil
  "Stores the major mode that was active before entering chatgpt-mode.")

(defvar chatgpt-previous-window-configuration nil
  "Stores the window configuration before entering chatgpt-mode.")

(defun chatgpt-save-and-exit ()
  "Save the chatgpt log and metadata, then restore the previous major mode and window layout."
  (interactive)
  ;; Save the log and metadata files
  (chatgpt-save-log-to-file)
  (chatgpt-save-metadata-to-file)
  ;; Kill buffers used in chatgpt-mode
  (kill-buffer "*chatgpt-input*")
  (kill-buffer "*chatgpt-conversational*")
  (kill-buffer "*chatgpt-executable*")
  (kill-buffer chatgpt-log-buffer-name)
  (kill-buffer chatgpt-metadata-buffer-name)
  ;; Restore the previous window configuration
  (when chatgpt-previous-window-configuration
    (set-window-configuration chatgpt-previous-window-configuration))
  ;; Switch back to the previous major mode
  (when chatgpt-previous-major-mode
    (funcall chatgpt-previous-major-mode))
  (message "ChatGPT session ended, buffers cleaned up, and previous layout restored."))

(defun chatgpt-log-retry-message (attempt)
  "Log a retry message to *chatgpt-metadata* indicating the retry attempt."
  (with-current-buffer chatgpt-metadata-buffer-name
    (goto-char (point-max))
    (insert (format "Retrying API call: attempt %d\n" attempt))))

(defun chatgpt-enter-mode ()
  "Capture the previous major mode and window configuration, then enter chatgpt-mode."
  (interactive)
  ;; Capture the previous major mode and window configuration
  (setq chatgpt-previous-major-mode major-mode)
  (setq chatgpt-previous-window-configuration (current-window-configuration))
  ;; Set the conversation ID based on the current timestamp
  (setq chatgpt-conversation-id (format-time-string "%Y%m%d-%H%M%S"))
  ;; Dynamically set buffer names for this session
  (setq chatgpt-metadata-buffer-name (format "*chatgpt-metadata-%s*" chatgpt-conversation-id))
  (setq chatgpt-log-buffer-name (format "*chatgpt-log-%s*" chatgpt-conversation-id))
  ;; Enter chatgpt-mode
  (chatgpt-mode))


(define-derived-mode chatgpt-mode fundamental-mode "ChatGPT"
  "A major mode for interacting with ChatGPT."
  (read-only-mode -1)
  ;; Delete all other active windows when entering chatgpt-mode
  (delete-other-windows)
  ;; Set up the buffers and window layout
  (switch-to-buffer (get-buffer-create "*chatgpt-input*"))
  (split-window-right)
  (other-window 1)
  (switch-to-buffer (get-buffer-create "*chatgpt-conversational*"))
  (split-window-below)
  (other-window 1)
  (switch-to-buffer (get-buffer-create "*chatgpt-executable*"))
  ;; Create the dynamically named buffers in the background:
  (get-buffer-create chatgpt-log-buffer-name)
  (get-buffer-create chatgpt-metadata-buffer-name)
  ;; Return focus to the input buffer
  (other-window -2)
  ;; Set up key bindings
  (use-local-map (let ((map (make-sparse-keymap)))
                   (define-key map (kbd "C-c C-c") 'chatgpt-send-prompt)
                   (define-key map (kbd "C-c C-s") 'chatgpt-save-log-to-file)
                   (define-key map (kbd "C-c C-q") 'chatgpt-save-and-exit)
                   map)))



(provide 'chatgpt-mode)
