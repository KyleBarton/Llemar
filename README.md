# Llemar

An LL(m) ema(cs) r(epl).

Llemar is an Emacs front end for [pi](https://pi.dev), a minimal agent harness.
It runs `pi --mode rpc` as a subprocess and renders the session into an
org-mode buffer.

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

Type your prompt under the trailing `* User` heading and press `C-c C-c`. The
reply streams in below it, and a fresh `* User` heading appears when the agent
settles.

| Key | Command |
| --- | --- |
| `C-c C-c` | Send the trailing user prompt |
| `C-c C-k` | Abort the current run |
| `C-c C-s` | Steer a running agent |
| `C-c C-n` | Start a fresh session |
| `C-c C-r` | Restart the pi process |
| `C-c C-i` | Report model, thinking level, and session id |
| `C-c C-l` | Show pi's stderr log |

A transcript looks like this:

```org
* User
What files are here?

* Assistant
:THINKING:
Let me check the repo.
:END:
Here is the plan.

** bash
#+begin_src json
{
  "command": "ls -la"
}
#+end_src
#+begin_example
README.md
llemar.el
#+end_example

* Assistant
Two files. Done.

* User
```

Each assistant turn is its own `* Assistant` heading, with tool calls nested
beneath the turn that made them. Thinking drawers and tool blocks collapse as
they complete, so a long run stays readable; `TAB` opens any of them. Org
applies `#+startup:` visibility only when a buffer is first visited, which is
long before a reply streams in, so llemar folds this content explicitly. `llemar-mode` derives from `org-mode`, so
folding, links, export, and `C-x C-w` all work as usual.

## Tests

```bash
./test/run-tests.sh
```

Byte-compiles with warnings as errors, runs checkdoc, then runs the ERT suite.
The tests drive `test/mock-pi`, a stand-in that speaks pi's RPC protocol and
replays named event scripts, so the suite needs no model, no network, and costs
nothing. Scenarios cover streaming and non-streaming turns, parallel tool calls
with out-of-order results, org-hostile prose and tool output, retries, aborts,
and process death.

## Configuration

- `llemar-executable` — path to pi, default `"pi"`
- `llemar-extra-args` — extra pi arguments, e.g. `("--model" "claude-opus-5")`
- `llemar-max-tool-result-lines` — tool output line cap, default 100, nil for no cap
- `llemar-show-thinking` — render thinking into a `THINKING` drawer, default t
- `llemar-fold-thinking` — collapse a thinking drawer once complete, default t
- `llemar-fold-blocks` — collapse tool argument and result blocks, default t
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
- Session resume: reattach a buffer to an existing pi session file
- Surface queue state, token usage, and cost in the mode line
- Render pi's extension UI requests (dialogs, notifications)
- `AGENTS.md`, skills, and memory management from Emacs
