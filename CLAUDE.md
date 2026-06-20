# CLAUDE.md

**Method:** Use the Write tool to overwrite .swift and .md files. **No sed!**

Act as a Senior iOS Engineer. Use **Swift 6.3** and the latest SwiftUI standards. Prioritize the **Observation framework**, **Swift Concurrency** (async/await), and **Swift Testing**. Avoid deprecated patterns like `@Published` or `XCTest` unless explicitly asked.

---

## Project Defaults
- Build with **Swift only**, preferably **Swift 6.3**.
- Only Apple frameworks and pure Swift.
- **No third-party dependencies** unless explicitly approved by the user.
- Default macOS/iOS/Xcode/Swift requirements must be documented in `README.md`.
- Always remove all copyrights/licenses if you are "translating" from other source code.

---

## Test Data & Assets
- **Standard Test Directory:** All external test assets (images, videos, sample data) are located at `~/Documents/Xcode/aTemp`.
- **Constraint:** Do not search for or assume the existence of test files in any other directory (e.g., Downloads, Desktop, or Pictures).
- **Usage:** If the app or tests require sample media, always reference this path or ask the user to confirm a filename within this specific folder.

---

## Architecture Rules
- **Package-First Modular Design:** The codebase must be strictly modularized using local Swift Packages. Organize packages into layers: `Core` (low-level), `Domain` (business logic), and `Features` (UI modules).
- **Zero Target Copying:** Reusable logic/models must live in packages. App and extension targets must never share source files directly via target membership.
- **The Scratchpad Exception:** New, experimental features or tiny helpers may live in the App target under `Sources/Scratchpad/`. 
    - **The Promotion Rule:** Promote scratchpad code to a package as soon as it stabilizes or needs to be shared.
- **Thin Targets:** App and extension targets must remain thin, acting only as orchestrators.

---

## Build & Deployment Rules
To avoid stale builds and DerivedData issues:
- **Build Directory:** Use a local `.build` folder in the project root.
- **Configuration:** Always build using the **Release** configuration.
- **Build Command:** Use `xcodebuild` with `SYMROOT` and `DSTROOT` pointing to the local `.build` folder.
    - `xcodebuild -scheme <Scheme> -configuration Release -derivedDataPath .build/DerivedData SYMROOT=.build/output`
- **Deployment:** After a successful build, the `.app` bundle must be copied to `~/Applications/`.
    - `cp -R .build/output/Release/<App>.app ~/Applications/`

---

## Code Style
- **Strict Isolation:** Adhere to Swift 6 isolation; prefer `@MainActor` on UI-bound types and explicit `Sendable` conformance.
- **Reference vs Value:** Prefer `struct` by default; use `final class` only when reference semantics are essential.
- **File Discipline:** One file per meaningful responsibility; no "god" files.
- **Resource Safety:** Check volume capacity before large file operations. Always use the standard test directory `~/Documents/Xcode/aTemp` for media processing tests.
- **Temp Paths:** Use `FileManager.default.temporaryDirectory` with uniquely named subdirectories for session-specific outputs.

---

## Workflow for Every Task
1. **The Re-entry Protocol (Critical after /clear):** If your memory is blank, you **must** ground yourself before coding:
    - **Check History:** Run `git log -n 1 -p` to see the code changes the user just committed from the previous session.
    - **Check State:** Read `SESSION_STATE.md` to identify the architectural "why" and the next immediate step.
2. Read `CLAUDE.md` and skim `README.md`.
3. Make the smallest clean change that fits the architecture.
4. **Build and Deploy** according to the "Build & Deployment Rules" above.
5. Update docs if reality changed.
6. **Compaction Warning:** When approaching context limits, STOP coding, update `SESSION_STATE.md` thoroughly, and wait for the user to `/clear`.

---

## End-of-Session Ritual
Before stopping work or letting the user run `/clear`, always:
1. **Build and Deploy** to guarantee a functional app in `~/Applications/`.
2. **Fix obvious errors** or report remaining failures.
3. **Update SESSION_STATE.md**: Document what was accomplished, current status, and the **exact** next command or step.
4. **Update README.md** if features or requirements changed.
5. **Handoff Note:** Leave a final summary line for the user to see before they commit and clear.

---

## SESSION_STATE.md Rules
Keep it short and factual. It must contain:
- Current architecture/modules.
- What is implemented / What is in progress.
- **Recent Fixes:** List the last 3 bug fixes to prevent regressions after a context clear.
- Known bugs/limitations.
- Immediate next steps.
- Build/run status.

---

## Review Checklist
- Is logic modularized in a package (or in `Scratchpad`)?
- Are targets thin?
- Is it Swift 6.3 compatible?
- App built in **Release** mode and moved to `~/Applications/`?
- Are test assets strictly pulled from `~/Documents/Xcode/aTemp`?
- `SESSION_STATE.md` contains the "next step" for the next session?

## Current Project Note
- Swiftorrent currently uses an umbrella `Package.swift` for reliable `xcodebuild` schemes while keeping local package manifests under `Packages/`.
- The app is deployed by bundling the Release Swift Package executable into `Swiftorrent.app` with `App/Resources/Info.plist`, then copying it to `~/Applications/`.
- To avoid stale app installs, remove `.build/DerivedData`, `.build/output/Release/Swiftorrent*`, and `~/Applications/Swiftorrent.app` before the final Release build/deploy pass.
