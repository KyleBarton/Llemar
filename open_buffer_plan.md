# Plan: let pi open a file beside a Llemar conversation

Status: implemented in `pi-extensions/` and `llemar.el`, with offline tests.
This document records the agreed design and its acknowledgement limitation.

## Goal and decision

From a Llemar conversation, the user can ask “show me the function that handles
this,” and pi can request that the relevant file appear in another Emacs
window. Pi determines relevance using its normal search/read tools. Llemar
supplies the editor operation, not a second agent or relevance engine.

Use the **existing tool-result event stream**, with no socket bridge and no
acknowledgement back to pi. The pi tool validates the file and returns a
structured display request. Llemar acts on that request when it receives the
successful tool completion.

A successful tool result means **“file validated; display requested,” not
“Emacs opened the file.”** Display failures are reported locally in the Llemar conversation, in a folded
`:LLEMAR_ERROR:` drawer under the affected tool call, as well as the log and
minibuffer. They are not sent back to pi.
This is sufficient for a convenience UI action and avoids a separate transport.

The initial operation visits an existing local file, optionally at a line and
column. Despite the name `open_buffer`, arbitrary non-file buffers are out of
scope for v1.

## Architectural boundary

**Pi owns the tool.** A small TypeScript extension registers `open_buffer` with
`pi.registerTool()`: model-facing description, argument schema, path resolution,
file validation, cancellation, and the result returned to the model. It is not
a no-op: it verifies that the target exists and is a regular file before
producing the display request.

**Llemar owns the editor action.** Emacs consumes the structured result,
revalidates it, visits or reuses the file buffer, and displays it according to
Emacs window policy. It does not choose relevance, implement the agent tool,
or parse assistant prose for commands.

Suggested future layout:

- `pi-extensions/llemar.ts`: pi registration entry point.
- `pi-extensions/open-buffer.mjs`: tool/schema construction and file validation,
  factored for offline Node tests without loading the pi runtime.
- `llemar.el`: explicit extension loading, tool-result dispatch, editor action.
- `test/mock-pi`: deterministic tool-result scenarios.
- `test/llemar-tests.el`: ERT coverage for validation, routing, and display.

Leave `llm_backend/` unchanged. Do not auto-discover the extension project-wide:
Llemar should pass its absolute path through `--extension` for its subprocesses.
Ordinary pi use in this checkout should not acquire an Emacs-specific tool.
Avoid duplicate loading and do not modify global pi configuration.

## Model-facing contract

Tool name: `open_buffer`.

Arguments:

```json
{"path":"llemar.el","line":325,"column":1}
```

- `path`: required nonempty local file path. Resolve relative paths against
  pi's execution context working directory, never Emacs's currently selected
  buffer. Return an absolute canonical path so Emacs need not guess the base.
- `line`: optional positive integer, 1-based.
- `column`: optional positive integer, 1-based; requires `line`. Count Emacs
  buffer characters, not UTF-8 bytes or visual screen columns.
- No Lisp, shell commands, window IDs, buffer names, or arbitrary operations.

The description should say: use this to **show the user** an existing file when
requested or clearly helpful; use normal search/read tools to inspect files
for reasoning. Do not open every file pi reads. The tool does not implement
its own relevance search.

The executor resolves the path, checks that it exists and is a regular file,
and applies the agreed path restrictions. Invalid arguments or files produce
a failed tool execution using pi's supported error contract, without a display
request. Observe cancellation before returning the result.

Do not read the file merely to validate a requested line: Emacs may already
have unsaved edits. Emacs validates the position against the actual buffer.
Do not return file contents or claim to have read them into model context.

## Structured result and event handling

Successful tool result (illustrative):

```json
{
  "content": [
    {"type":"text","text":"File validated; requested display of /project/llemar.el at line 325. Display is handled by Llemar and is not confirmed."}
  ],
  "details": {
    "version": 1,
    "action": "open_file",
    "path": "/project/llemar.el",
    "line": 325,
    "column": 1
  }
}
```

The ordinary RPC event carries this result:

```json
{
  "type": "tool_execution_end",
  "toolCallId": "call-123",
  "toolName": "open_buffer",
  "isError": false,
  "result": {
    "content": [{"type":"text","text":"File validated; display requested."}],
    "details": {
      "version": 1,
      "action": "open_file",
      "path": "/project/llemar.el",
      "line": 325,
      "column": 1
    }
  }
}
```

Llemar dispatches only when all of these hold:

- It is a live `tool_execution_end` from the conversation's current pi process.
- The tool name is exactly `open_buffer` and execution did not fail.
- `result.details` has the supported version/action and valid typed fields.

Never dispatch from `tool_execution_start`, partial updates, model arguments,
text content, or other tools that happen to return similar details. Keep the
normal tool heading/code-block rendering; editor dispatch is an additional
consumer of the completion event, not a replacement renderer.

Render historical results normally, but **never replay their editor actions**
when loading/resuming a transcript or rerendering a conversation. Deduplicate
live completions by tool-call ID within a process generation. If several calls
complete, serialize actions in completion-event order, not invocation order.

There is no reply, synthetic user message, or follow-up prompt. Pi knows file
validation succeeded, but cannot know whether Emacs displayed it. If that
limitation becomes important later, reconsider an acknowledged transport then.

## Editor behavior

Default: **display without stealing focus**. The user stays in the Llemar input
window while the file appears beside it. Window selection is editor policy,
not a model argument.

1. Find a live window showing the originating conversation. Prefer the selected
   window if it shows that conversation; otherwise use a stable visible choice
   and its frame. Do not use the unrelated currently selected buffer as origin.
2. If the conversation is hidden, skip the action and report a local failure
   rather than commandeering another frame or opening a new one.
3. Reuse a suitable non-conversation window on that frame, or split the
   conversation window. Use Emacs display-buffer facilities with explicit
   constraints: never replace the conversation, use a minibuffer or dedicated
   window, or implicitly create a new frame. If no valid display is possible,
   report failure locally.
4. Reuse a visiting buffer, including unsaved edits; otherwise visit the
   existing file normally. Do not save, revert, create, or modify it.
5. Validate the requested position against that buffer. Report out-of-range
   locations locally rather than silently jumping elsewhere. Without a
   location, preserve the existing buffer/window position when possible.
6. Set the target window's point and make it visible. Preserve selected window,
   conversation point, draft, and scroll position, including normal streaming
   and follow-output behavior.
7. Reject a target that is the conversation buffer itself.

Separate the validated editor operation from event dispatch for direct ERT
coverage and possible reuse by an interactive command later.

## Errors, lifecycle, and cancellation

- Pi-side failures (invalid arguments, missing/non-regular file, denied path)
  are tool errors visible to the model. Llemar must not act on those results.
- Emacs-side failures (file disappeared, bad position, hidden conversation,
  window split failure, file hook error) are bounded local diagnostics in a
  folded `:LLEMAR_ERROR:` drawer under the affected tool call. Preserve that
  call's insertion marker while work is queued so errors do not land under a
  later tool or the user's draft. Flatten/escape diagnostic text so it cannot
  introduce Org headings, drawer terminators, or block delimiters. Also emit a
  minibuffer message and a log entry. Do not rewrite the pi tool result or
  pretend the model received the diagnostic.
- A malformed/unsupported display payload must not interrupt normal RPC
  consumption or transcript rendering. Log it and continue.
- Queue editor work outside the process filter before running file hooks or
  manipulating windows. Capture the originating buffer/process generation and
  recheck both before executing queued work.
- On restart or buffer death, invalidate queued work and clear per-generation
  deduplication state. Normal process exit also cancels pending UI work; a
  completed display is never undone.
- Aborted or failed tools do not trigger display. Once a successful completion
  has been consumed, display is best-effort; cancellation racing with the
  queued action does not promise rollback. No automatic retries or polling.

## Scope and trust

V1 supports local files within the conversation's captured launch root. Give
pi and Emacs the same root policy; a per-child environment value can convey
this to the explicitly loaded extension without changing global environment
or configuration. Root policy is separate from relative-path resolution.

Resolve symlinks before checking containment. Reject directories, missing
files, remote TRAMP paths, and paths outside that root. Enforce restrictions
in Emacs as well as the extension: a successful validation in pi does not
eliminate races or replace editor-side validation. External files can be a
later explicit user policy/confirmation.

Do not interpolate model input into shell commands or evaluate received Lisp.
File visiting can run modes, hooks, and local-variable handling; retain normal
Emacs safe-local-variable/eval protections and do not approve unsafe settings
on the agent's behalf. This is an integration with a trusted local pi process,
not a sandbox against an agent that already has shell access as the same user.

## Test-driven implementation sequence

1. **Editor primitive:** failing ERT cases for existing-buffer reuse, requested
   location, one-window split, two-window reuse, preserved focus and draft,
   and inability to display without replacing the conversation.
2. **Validation:** malformed arguments/details, unsupported versions/actions,
   range errors, missing files, directories, remote paths, traversal and symlink
   escape, unsaved buffers, dedicated windows, multiple frames, hidden or dead
   conversations, and the file disappearing after pi's validation.
3. **Mock event integration:** extend `test/mock-pi` with successful and failed
   `open_buffer` completions. Verify normal transcript blocks still render and
   only valid successful completions trigger display. Include chunked events,
   parallel calls completing out of order, duplicate events, unrelated tools,
   and two conversations routing to their own windows.
4. **Lifecycle:** test queued actions against restart/process exit/buffer death,
   no action from partial events, and no replay from historical results.
5. **Pi extension contract:** an offline TypeScript harness with a fake
   `ExtensionAPI` and temporary files verifies schema, relative-path resolution,
   canonicalization, root policy, regular-file checks, cancellation, error
   mapping, and exact structured result details. Assert that successful text
   requests display rather than claiming confirmed display. The Emacs mock
   alone cannot verify the actual TypeScript executor.
6. Run `./test/run-tests.sh` and the offline extension tests before completion.
   No real model, network service, or API spend. Dogfood only when requested
   or appropriate after the suite is green.

## Acceptance criteria

- Pi owns a real `open_buffer` tool that validates the file and returns a
  structured display request.
- Llemar opens the relevant project file beside the correct conversation,
  without disturbing the user's input.
- The model receives truthful validation/request status, not an unverified
  claim that Emacs opened the file. Display failures stay local to Emacs.
- Existing RPC events suffice: no socket, acknowledgements, fabricated pi RPC
  methods, prose parsing, global evaluation endpoint, or new agent backend.
- Tests remain free, offline, deterministic, and cover routing, duplicates,
  history, and teardown as carefully as the happy path.

## Reference notes

The original investigation used installed pi 1.4.0 documentation:
`docs/extensions.md`, `docs/rpc.md`, `docs/rpc-extension-ui.md`, and
`examples/extensions/hello.ts`. Recheck exported tool/result/event types and
CLI flags against the target pi version before implementation. This design
uses ordinary tool-result `details`, not a new extension UI method.
