# CLAUDE.md

Act as a senior macOS engineer. Use the latest stable Swift and SwiftUI. The app is a SwiftPM package built by script; there is no Xcode project. Minimum OS versions are in `README.md`.

## Session start
1. Current state (loaded automatically): @SESSION_STATE.md
2. Run `git status -s && git log --oneline -5`. Treat the state as claims, not facts: before the first code change, run the tests so you know which failures were already there.
3. Before adding or moving code, read `docs/ARCHITECTURE.md` (layout, packages, dependency rules).
4. `docs/WORKFLOW.md` is the user's own guide: don't read it unless asked.

## Everything stays in this repo
- Plans: `docs/plans/<topic>.md`, never `~/.claude/plans`. Sections: **Goal** (2–3 sentences, what the user gets), **Steps** (checkboxes, one commit each), **Done when** (which tests exist, what to check by hand). Show the user the plan before writing code. Tick steps as they land; when scope changes, add a dated line saying why. When done, move any lasting "why" to `docs/decisions/`, then delete the plan.
- Decisions between real alternatives (storage, architecture, a dependency): `docs/decisions/NNNN-short-title.md` with context, decision, consequences; 20 lines max.
- Don't save Claude Code auto memories. Anything worth remembering goes in `SESSION_STATE.md` or `docs/`.
- Scratch files, logs, downloads: `tmp/` (gitignored). Never `/tmp`, `~` or any other folder.
- Sample media: `Fixtures/` (large files in `Fixtures/local/`, gitignored). Never look for media elsewhere on disk; if a file is missing, ask.
- The only thing written outside the repo is the deployed app in `~/Applications/`.

## Swift standards
- Latest Swift language mode with strict concurrency: async/await and actors, explicit `Sendable`, UI types on `@MainActor`.
- Observation (`@Observable`), not `ObservableObject`/`@Published`.
- Swift Testing for unit tests; XCTest only for UI and performance tests. Every bug fix starts with a failing regression test.
- `struct` by default; `final class` only when reference semantics are essential.
- One file per responsibility; no god files.
- Apple frameworks and pure Swift only. No third-party dependencies unless the user approves.
- No copyright/license headers or author names (real or fake) in any file. Remove them from code you write, port or touch.
- App runtime: check free disk space before large file writes; put temporary output in a unique subfolder of `FileManager.default.temporaryDirectory`.

## While working
- Ambiguous requirement or a hard-to-undo choice: ask first. Otherwise state your assumptions in one line and go.
- Make the smallest clean change that fits the architecture: no speculative abstractions, options or error handling for cases that can't happen.
- Touch only what the task needs: no drive-by refactors or reformatting. Match the surrounding style; remove anything your change left unused.
- After code changes: test, build and deploy (below). Docs-only changes need no build.
- Update `README.md` or `docs/ARCHITECTURE.md` when reality changes.
- When the user corrects something that will come up again, add one line under Lessons.
- Context nearly full: stop, overwrite `SESSION_STATE.md`, ask the user to `/clear`.

## Build, test, deploy
Always Release, tests included. Build output lives in `.build/` (gitignored), never the default DerivedData. Logs go to `tmp/` and are overwritten each run; read past the summary only on failure.

```sh
mkdir -p tmp
# Unit tests: the root package and each package under Packages/ (-enable-testing keeps @testable import working in Release)
swift test -q -c release -Xswiftc -enable-testing --package-path <.|Packages/Package> > tmp/test.log 2>&1; echo "exit $?"; tail -20 tmp/test.log
# Build, wrap into a .app, install to ~/Applications, then double-click to test
Scripts/build.sh
```
- `Scripts/build.sh` is app-agnostic: it takes the app name from `CFBundleExecutable` in `App/Resources/Info.plist`, which must match the executable target in `Package.swift`. Errors are printed; the full log is `tmp/build.log`. Keep it generic; never hardcode an app name in it.
- No macOS toolchain (Linux/cloud session): skip build and deploy, and say so.

## Wrap-up: when the user says "git commit push main" or ends the session
1. If code changed since the last build: test, build, deploy. Fix obvious errors or report them.
2. Overwrite `SESSION_STATE.md` (its format is in the file).
3. Commit all changes with a descriptive message and push to `main`.
4. Finish with a one-line summary.

## Lessons
- _none yet_
