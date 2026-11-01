# Llemar

An LL(m) ema(cs) r(epl).

Llemar is an Emacs front end for [pi](https://pi.dev), a minimal agent harness.
It runs `pi --mode rpc` as a subprocess and renders the session into an
org-mode buffer. Emacs owns the conversation UI; pi owns the agent, model
access, tools, and session history.

## Current features

- **Streaming Org conversations:** assistant turns, thinking drawers, and nested
  tool calls appear as they arrive, with a fresh user prompt when the run settles.
- **Foldable tool output:** pretty-printed JSON arguments, result blocks, errors,
  and execution durations stay attached to the right call, even when parallel
  tools finish out of order.
- **Inline file previews:** `edit` results show patches and `write` calls show
  their proposed entire contents as additions in a
  syntax-highlighted Org `diff` source block, including in resumed history.
- **Session resume:** choose a previously recorded Llemar session and continue
  with its saved transcript rendered in a new buffer.
- **Agent-driven file display:** the companion `open_buffer` tool opens local
  project files at an optional line and column, without stealing focus.
- **Conversation mode line:** project, quoted session title, model, and current
  turn/activity, with right-aligned estimated spend and context tokens/window
  plus percentage, using pi's native statistics.
- **Run controls:** send prompts, steer or abort an active run, start a fresh
  session, restart pi, inspect session state, and view diagnostic logs.
- **Output following:** windows at the end follow new output; scrolling back
  leaves your reading position alone.
- **Org-native transcripts:** use normal folding, links, export, and file saving.
  Agent output is escaped so it cannot accidentally restructure the outline.

## Architecture

The long-term shape of this project is a programmatic backend agent — system
prompts and `AGENTS.md`, skills, memory, context management — with Emacs as the
front end. Rather than build that backend here, Llemar adopts pi for it, so the
work can focus on getting the Emacs experience right first.

Llemar speaks pi's [RPC protocol](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs/rpc.md):
newline-delimited JSON commands on stdin, responses and session events on
stdout. One pi process per conversation buffer.

`llm_backend/` is the earlier hand-rolled backend. It is superseded by pi and
kept only for reference.

## Requirements

- Emacs 29.1 or newer
- pi on `PATH`: `curl -fsSL https://pi.dev/install.sh | sh`

## Install

```elisp
(add-to-list 'load-path "/path/to/Llemar")
(require 'llemar)
```

## Use

`M-x llemar` starts a conversation in `default-directory`, taking over the
current window. `M-x llemar-other-window` displays it in another window
instead. A `C-u` prefix on either prompts for the agent's working directory.

When called from an existing Llemar buffer, `M-x llemar` saves its transcript
and closes that buffer and its pi process after the new conversation starts
successfully. Use `M-x llemar-other-window` to keep the existing conversation
open. If starting the new conversation fails, the existing one is left intact.

Type your prompt under the trailing `** User` heading in `* Current` and
press `C-c C-c`. The reply streams in below it, and a fresh `** User` heading
appears when the agent settles.

| Key | Command |
| --- | --- |
| `C-c C-c` | Send the trailing user prompt |
| `C-c C-k` | Abort the current operation, including compaction |
| `C-c C-m` | Compact context (`llemar-compact`; prefix prompts for instructions) |
| `C-c C-s` | Steer a running agent |
| `C-c C-n` | Start a fresh session |
| `C-c C-r` | Restart the pi process |
| `C-c C-i` | Report model, thinking level, and session id |
| `C-c C-l` | Show pi's stderr log |

A transcript looks like this:

```org
* Current
** User
What files are here?

** Assistant
:THINKING:
Let me check the repo.
:END:
Here is the plan.

*** bash
#+begin_src json
{
  "command": "ls -la"
}
#+end_src
#+begin_example
README.md
llemar.el
#+end_example

** Assistant
Two files. Done.

** User
```

Each assistant turn is its own `** Assistant` heading, with tool calls nested
beneath the turn that made them. Thinking drawers and tool blocks collapse as
they complete, so a long run stays readable; `TAB` opens any of them. Org
applies `#+startup:` visibility only when a buffer is first visited, which is
long before a reply streams in, so llemar folds this content explicitly. `llemar-mode` derives from `org-mode`, so
folding, links, export, and `C-x C-w` all work as usual.

### Conversation mode line

```text
 Llemar  "Session title" │ Sonnet │ Assistant          ~$0.45  60k/200k (30%)
```

The project is the working directory's root folder name. The title truncates
first in narrow windows. The turn label distinguishes User (ready for input),
Assistant, Tool, Compacting, Retrying, Error, and Disconnected; color supplements
these labels using your theme's existing faces.

The right-hand group shows estimated cumulative session cost in USD, followed
by estimated context tokens / model window and percentage. This is not a bill
or a subscription usage meter. Values come from pi's `get_session_stats`, refreshed
at startup and after assistant responses, compaction, and settled runs. Missing
values show an em dash, including context usage temporarily unknown after
compaction. No compaction threshold is assumed, and redisplay never sends RPCs.

### Compaction

`M-x llemar-compact` (or `C-c C-m`) asks pi to compact context on demand once
the agent is idle. With `C-u`, enter optional instructions for the summary.
`C-c C-k` can cancel compaction. Automatic threshold and overflow compactions
use the same presentation, without interrupting continued generation.

The mode line shows `Compacting` during the operation. After confirmed
success, the compacted prefix becomes a timestamped top-level `Compacted`
section with `Source` (the preserved original transcript) and `Summary`
(pi's actual retained summary). Recent messages still in context stay under
`Current`, along with subsequent output and any unsent draft. Repeated
compactions create sibling archives rather than replacing earlier records.
Failed or cancelled compactions leave the conversation structure intact.

On resume, Llemar uses pi's raw session entries and active branch to recover
pre-compaction source and summaries. Saved Org archive annotations are reused
when their compaction IDs match that branch, along with a trailing local draft.
These Org copies never replace pi's authoritative model context. If raw history
or an exact rendered boundary is unavailable, Llemar reports the limitation
rather than claiming retained messages were removed or silently dropping source.

### Edit and write diffs

Successful `edit` tool results include the normal success message followed by
pi's unified patch:

```org
#+begin_src diff
--- a/example.el
+++ b/example.el
@@ -1 +1 @@
-(message "Hello")
+(message "Hello, world")
#+end_src
```

Org uses `diff-mode` highlighting when `org-src-fontify-natively` is enabled.
Diffs are expanded by default, unlike other tool blocks; fold them with `TAB`.
They are kept complete, regardless of the ordinary tool-result line cap.
Failed edits and edit results without a patch retain their normal output.

For `write` calls, Llemar replaces the JSON argument preview with the path and
an expanded, additions-only `diff` block labeled **Proposed file contents
(entire file)**. This shows all supplied content at call time, before success
or failure is known. The normal result follows separately. It is not a
before/after diff: overwrites do not show removed or unchanged lines, and even
unchanged writes display their supplied contents. Empty files have an empty
block; missing final newlines are indicated explicitly. Contents are not
truncated and are not duplicated as escaped JSON.

Both presentations work live and when replaying saved history. Write previews
use only tool-call arguments: no extra filesystem reads, backend overrides, or
stored patches are needed. Older sessions with saved write arguments also get
the preview. Malformed arguments retain the normal JSON preview. File changes
made by shell commands do not get diff blocks.

### Resuming a session

`M-x llemar-resume` offers sessions Llemar has recorded for the current working
directory; `C-u M-x llemar-resume` offers sessions across directories. Selecting
one starts a pi process attached to that session, renders its saved history,
and leaves a fresh prompt ready to continue. Historical file-display requests
are passive: resuming does not reopen those files.

Resuming from an existing Llemar buffer likewise saves and closes the current
conversation after the resumed conversation starts successfully.

Only sessions driven through Llemar are offered, not sessions started in pi's
own interface. Enable `savehist-mode` to preserve Llemar's session registry
across Emacs restarts. Sessions are listed newest-first; when Consult is
installed, moving through candidates previews their saved Org transcripts.
Without Consult, the picker uses ordinary `completing-read`.

The companion extension asks the conversation's model to use `set_session_name`
once its overarching purpose is clear, and to correct the title when intent
becomes clearer or the topic changes substantially. It also adds a hidden title
review reminder on the third user-started run, then every five user-started
runs (3, 8, 13, …). Reviews do not require a rename or a separate model request;
brief tangents should leave a useful title unchanged. Tool-loop turns and
custom-message-started runs do not advance the schedule.

The review schedule is stored in pi's session history and follows the active
branch across resume and extension reload. Counting begins when this version
of the extension first handles a user request. Change the interval after the
initial review using pi's `--session-title-review-interval` flag (a positive
integer; invalid values fall back to five), for example:

```elisp
(setq llemar-extra-args '("--session-title-review-interval" "10"))
```

The title is saved in pi's session history and used for the picker and buffer
name. The first prompt remains a fallback until the model supplies a title.

Org preview copies are saved automatically when sending, when a run settles,
after resuming history, before starting a fresh session, and when killing a
conversation buffer. Configure their location with:

```elisp
(setq llemar-session-directory
      (expand-file-name "llemar/sessions/" user-emacs-directory))
```

Transcripts use stable filenames independent of their titles, are written
atomically with owner-only permissions, and may contain sensitive conversation
and tool output. They are preview copies, not the source used for resuming:
pi's session history remains authoritative. Older sessions gain previews when
next resumed.

## Showing files from the agent

Llemar explicitly loads its companion pi extension, which gives the agent an
`open_buffer` tool. Ask, for example, “show me the function that handles this.”
Pi validates the file and returns a structured display request; Llemar opens
it in another window without stealing focus. Optional line and character
column positions are 1-based. Only existing local files within the
conversation's launch directory are allowed, including after resolving symlinks.

This is a best-effort UI action: pi knows the file was validated, but does not
receive confirmation of display. Editor-side failures appear in a folded
`:LLEMAR_ERROR:` drawer beneath the tool call (expand with `TAB`), and in the
log. Historical tool results do not reopen files when resuming a session.
The companion files in `pi-extensions/` must remain beside `llemar.el`.

## Tests

```bash
./test/run-tests.sh
```

Byte-compiles with warnings as errors, runs checkdoc, offline companion-tool
unit tests (requires Node.js with `node --test`), then the ERT suite.
The tests drive `test/mock-pi`, a stand-in that speaks pi's RPC protocol and
replays named event scripts, so the suite needs no model, no network, and costs
nothing. Scenarios cover streaming and non-streaming turns, parallel tool calls
with out-of-order results, org-hostile prose and tool output, retries, aborts,
process death, session resume, and live and replayed edit/write diffs.

## Configuration

- `llemar-executable` — path to pi, default `"pi"`
- `llemar-extra-args` — extra pi arguments, e.g. `("--model" "claude-opus-5")`
- `llemar-buffer-name-function` — function used to name new conversation buffers
- `llemar-max-tool-result-lines` — tool output line cap, default 100, nil for no cap;
  edit/write diff blocks are not truncated
- `llemar-show-thinking` — render thinking into a `THINKING` drawer, default t
- `llemar-fold-thinking` — collapse a thinking drawer once complete, default t
- `llemar-fold-blocks` — collapse tool argument and result blocks, default t;
  diff blocks remain expanded
- `llemar-follow-output` — follow output in windows already at the end, default t
- `llemar-user-heading` / `llemar-assistant-heading` — headline text

## Keeping org structure intact

Agent output is prose and arbitrary command output, both of which can collide
with org syntax. Llemar escapes as it streams:

- A line of assistant prose beginning at column 0 with `*` — markdown bold, or
  a bullet — gets a leading space, so it cannot become a headline.
- Inside `#+begin_example` and `#+begin_src` blocks, lines beginning with `*`
  or `#+` are escaped with a leading comma, which org strips again on display
  and export. Org's outline scanner does not respect block boundaries, so
  without this a line of `ls` output could splinter the tree.
- Tool arguments are re-parsed from the raw protocol line before display, so
  `null`, `false`, and `{}` stay distinct instead of collapsing into one value.

Two markdown/org collisions remain, both cosmetic rather than structural, and
both go away with the markdown-to-org conversion listed below:

- A markdown heading (`# Title`) is an org comment, so it renders as one.
- A line of prose beginning with `#+` is read as an org keyword. An
  unterminated `#+begin_src` in prose does not swallow the headings after it,
  so the tree still holds.

## Next steps

- Markdown-to-org conversion for assistant prose, replacing the leading-space escape
- Surface queue state, token usage, and cost in the mode line
- Render pi's extension UI requests (dialogs, notifications)
- `AGENTS.md`, skills, and memory management from Emacs
