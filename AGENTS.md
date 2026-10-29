# Llemar Agent Instructions

## Architecture

Llemar is split into a front end and a back end:

- **Front end — Emacs (`llemar.el`).** An org-mode buffer per conversation.
  This is where the work in this repo happens: rendering, folding, escaping
  agent output so org structure stays intact, and the user-facing commands.
- **Back end — [pi](https://pi.dev), run as `pi --mode rpc`.** Llemar does not
  implement the agent itself; it spawns one pi process per conversation buffer
  and speaks pi's RPC protocol: newline-delimited JSON commands on stdin,
  responses and session events on stdout. System prompts, skills, memory, and
  context management belong to the back end.

`llm_backend/` is an earlier hand-rolled Rust back end, superseded by pi and
kept only for reference. Don't extend it.

## Test-driven development

Test-drive changes in this repository:

1. Write a failing test that captures the behaviour you want (or the bug you
   are fixing) and run it to see it fail for the expected reason.
2. Make the smallest change that makes it pass.
3. Refactor with the suite green.

Front-end tests drive `test/mock-pi`, a stand-in that speaks pi's RPC protocol
and replays named event scripts. When new behaviour depends on events pi
emits, add a scenario to `test/mock-pi` rather than calling a real model. The
suite must stay free, offline, and deterministic.

## Running the Emacs tests

Full check — byte-compile with warnings as errors, checkdoc, then ERT:

```bash
./test/run-tests.sh
```

ERT suite only:

```bash
emacs -Q --batch -l test/llemar-tests.el -f ert-run-tests-batch-and-exit
```

A single test, or tests matching a regexp:

```bash
emacs -Q --batch -l test/llemar-tests.el \
  --eval '(ert-run-tests-batch-and-exit "llemar-test-some-name")'
```

Run `./test/run-tests.sh` before calling a change done; byte-compile warnings
and checkdoc issues fail it just like a failing test.

## Style

<!-- Add style preferences here as they come up. -->
