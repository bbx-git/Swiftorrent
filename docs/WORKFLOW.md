# Workflow

Your guide to using this template with Claude Code. Claude doesn't read this file unless you ask.

## Starting a new app
1. One time: on GitHub, open this template's **Settings → General** and tick **Template repository**. Then **Use this template → Create a new repository** gives each new app a fresh repo with these files and no history.
2. Clone the new repo to your Mac, start Claude Code in that folder and say "let's start". `SESSION_STATE.md` loads automatically; Claude asks for the app name and minimum macOS version.
3. Claude creates everything else: `Package.swift`, `App/Resources/Info.plist`, the packages and the first build. There is no Xcode project; you never open Xcode.

## Daily loop
| You say | What happens |
|---|---|
| Just describe the task | State is already loaded; no "read this first" needed |
| "write a plan for X" | Claude writes `docs/plans/x.md`, shows it and stops |
| "go" / "do step 2" | Claude works through the plan, ticking steps as they land |
| You correct something | Claude adds a one-line lesson so it doesn't repeat |
| "git commit push main" | Test, run `Scripts/build.sh` (installs to `~/Applications`), update state, commit, push |
| `/clear` | Fresh session; state loads again |

## Plans
- Small tasks (a bug, a tweak, one screen): just ask, no plan.
- Bigger features (several steps or files, or anything worth thinking through first): "write a plan for iCloud sync". Read it, edit it or say what to change, then "go".
- Don't use the built-in plan mode (Shift+Tab): it can only save plans to `~/.claude/plans`, outside the repo. Asking "write a plan" in normal or auto mode saves to `docs/plans/`, and Claude still stops before coding.
- Auto mode is fine for building: Claude runs tests and builds without asking each time. Before "git commit push main" you can ask "show me what changed".

## Tips
- One feature per session: "git commit push main", `/clear`, next feature. A fresh short session beats a long one in cost and accuracy.
- App work happens in Claude Code on your Mac (terminal or desktop app). Web sessions run on Linux without the macOS toolchain, so they can't build or deploy; they're fine for docs and planning.
- Say how you'll check the result ("dropping a video into the window shows a thumbnail"). It becomes the plan's "Done when" or a test.
- `Scripts/build.sh` is app-agnostic (the name comes from `App/Resources/Info.plist`); don't edit it per app. The template is macOS only; iOS apps need an Xcode project and a different build.
- Put sample media in `Fixtures/` before asking for media features.
- If Lessons in `CLAUDE.md` passes ~15 lines, ask Claude to merge similar ones.
- Improved `CLAUDE.md` inside an app? Copy the change back to the template; apps made from it don't get later updates.
- `/context` shows what's using your tokens.
- Choosing between real options? Say "record this decision"; it goes to `docs/decisions/`.

## Limits
- Rules are instructions, not hard checks. If structure drifts, correct it once and it becomes a lesson.
- The template is written for Swift. The general rules work for Python or C++, but the build commands, Swift standards and layout don't; those need their own template.
