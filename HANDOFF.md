# Handoff — écri mark down

Thread-scoped handoffs. Each `## Thread:` section is a cold-start map for one
work-thread; a `/clear` wipes all chat context, so this file + the git log are the
only things that carry work forward.

---

## Thread: ios-port

> Stamped 2026-08-09 (Sunday). Cold-start map for the iOS port + CloudKit sync /
> Apple Watch design thread.

### What this project is

**écri mark down** — a lightweight, dependency-free SwiftUI Markdown scratchpad.
One Xcode target (`écri mark down.xcodeproj`) shares code across **macOS, iOS,
iPadOS, visionOS** via `#if os(macOS)` / `#if !os(macOS)` conditionals. Product
intent: **fast, focused scratchpad** — no file hierarchy, no vault, no AI. Notes
ARE `.md`, so they're portable into Obsidian/VS Code. Headed to the App Store
(`afluffywaffle.e-cri-mark-down`, bundle id already used on device).

### Current state

- Branch **`ios-port`** (HEAD `e0e2f97`), 4 commits ahead of `main`:
  `6652ccf` iOS port (the big one) → `5f551b0` + `665a706` + `9394d12` design docs → `e0e2f97` README fix.
- **PR #3 is open** — `ios-port` → `main`:
  https://github.com/afluffywaffle/ecri-mark-down/pull/3
  (The earlier PR #2 auto-closed when the old branch name was deleted during a rename.)
- **Device-verified:** the iOS port builds and runs on a **physical iPhone Air**
  (install via `devicectl`, verified launch). macOS still builds (verified the same
  session). SourceKit diagnostics are noise — the real compiler (xcodebuild) always
  succeeded.
- Working tree is **clean**.

**ONE next step: user reviews + merges PR #3.** After that, the iOS port is in
`main` and the next real work is the sync/watch design (pipeline below).

### Pipeline / todo (in this order)

1. **Merge PR #3** (user action or `gh pr merge 3 --squash`). Low risk. Do first —
   everything else builds on `main` being current.
2. **CloudKit sync core (iOS + macOS)** — the spine of the design doc. Add the
   iCloud/CloudKit entitlement + container, a `SyncService` singleton wrapping
   `CKDatabase`, map `Document ↔ CKRecord`, current-pad + archive model, soft
   delete, last-writer-wins. Design: `docs/SYNC-WATCH-DESIGN.md`.
   Medium-high risk (first CloudKit work in this codebase) — but it unblocks 3 & 4.
3. **iPhone scratchpad UI** — current pad on top, archive below, flat list; keep
   the existing `.md` quick-edit via the file picker. `écri mark down/ContentView.swift`.
4. **Watch app (RISKIEST — do LAST)** — new watchOS target. One current pad +
   long-press `contextMenu` "New Scratchpad" → archive → fresh pad. Keyboard +
   dictation via one focused `TextField`. Direct CloudKit with `WCSession` phone
   relay fallback. High risk: new target, watch background budget, CloudKit-on-watch
   container quirks.
5. **Polish** — offline edge cases, multi-window truth, migration from the current
   file-only workflow.

**Deliberately out of scope (settled):**
- **macOS stays as-is.** The user's explicit call: keep macOS's current behavior
  (open any `.md`, tabs, find/outline, autosave) — do NOT convert it to a
  records-only store. It's the fast "⌘⇥ viewer" but that's already what it does;
  no rework.
- Design decisions **D1/D2/D3 are SETTLED** (see doc §"Decisions (settled)") — do
  not re-open. D2: watch relaunch **resumes the current pad** (rolling pad); empty
  pads never archive. D3: everything in the store syncs; quick-opened `.md` never
  does.
- No Core Data / `NSPersistentCloudKitContainer` — thin hand-rolled CloudKit layer
  over the existing `@Observable` store (fallback only if hand-rolled gets fiddly).

### Gotchas a cold session WILL hit

- **Scheme name is NFD-accented.** Passing `-scheme "écri mark down"` typed
  literally fails ("does not contain a scheme named…"). Capture the exact bytes:
  ```bash
  cd "/Users/jayromacorda/Develop/écri mark down"
  SCHEME=$(xcodebuild -project "écri mark down.xcodeproj" -list 2>/dev/null | awk '/Schemes:/{getline; gsub(/^ +/,""); print; exit}')
  xcodebuild -project "écri mark down.xcodeproj" -scheme "$SCHEME" -destination 'platform=macOS' build
  ```
  (Full note: memory `xcodebuild-scheme-normalization`.)
- **SourceKit diagnostics are phantom.** LSP will report "Cannot find type
  'PendingOpen' in scope" etc. for every build. IGNORE them — the real check is
  `xcodebuild … 2>&1 | grep -E "error:|BUILD"`. This has been true the whole port.
- **iOS toolbar needs a NavigationStack.** `ContentView`'s iOS `root` property
  wraps the editor row in `NavigationStack`, because `.principal` /
  `.navigationBarLeading` toolbar placements are silently dropped without a nav
  bar. Do not "simplify" this away.
- **Crowded `ToolbarItemGroup` drops items on iPhone.** Use separate
  `ToolbarItem`s (as in `toolbar`). The ⋯ `Menu` holds authoring + Settings.
- **iOS device id rotates.** iPhone Air id seen in logs (`2689AD0A-…` at stamp
  time) changes between boots. Always re-resolve:
  ```bash
  xcrun devicectl list devices   # find "iPhone Air" row → <DEVICE_ID>
  xcrun devicectl device install app --device <DEVICE_ID> "/path/to/écri mark down.app"
  xcrun devicectl device process launch --device <DEVICE_ID> afluffywaffle.e-cri-mark-down
  ```
- **Bundle id:** `afluffywaffle.e-cri-mark-down`.
- **New source files auto-join the target** (`PBXFileSystemSynchronizedRootGroup`)
  — no `.pbxproj` edit needed when adding `*.swift` inside the app folder. Only
  entitlements/project-level changes need Xcode.
- **Per-page editor state** on iOS lives in `EditorPageView` (its own caret,
  topVisibleIndex, wordCount) so paged tabs don't fight over shared `@State`.
  `EditorActionBus.shared` (formatting/find) routes to the active page via
  `isActive` + `claimBus()`.

### What NOT to re-derive

- The iOS port itself is DONE and device-verified (Safari-style tabs, toolbar,
  title-tap rename, view menu, per-tab state, bus routing) — don't rebuild it.
- The macOS **window-close save guard** (`WindowCloseGuard`, `WindowAccessor`) is
  in place and correct; don't re-architect.
- The **EPUB/docx security fixes** (`c0a1073`, `3fd66cf`, `577dc93`, `ad6b064`)
  predate this branch and are already in `main`.
- Conflict policy (LWW on `updatedAt`), soft-delete, the rolling-pad watch model —
  all settled in `docs/SYNC-WATCH-DESIGN.md`; read it before any sync work.

### Done log (this thread)

- `6652ccf` (2026-08-09) — **feat: iOS port** — Safari-style tab paging, iOS
  `NavigationStack` toolbar, title-tap rename, view menu (Source/Split/Preview),
  per-page editor state, macOS window-close save guard, `docs/USAGE.md`. Both
  platforms built; installed + launched on physical iPhone Air.
- `5f551b0` (2026-08-09) — docs: sync + Apple Watch design note (CloudKit store,
  watch scratchpad, phases).
- `665a706` (2026-08-09) — docs: competition & differentiator.
- `9394d12` (2026-08-09) — docs: settled one-store model, per-platform roles,
  D1/D2/D3 resolved, long-press New Scratchpad model.
- `e0e2f97` (2026-08-09) — docs: README preview-capability fix (stale claim).

### Next session — paste this to start

```
Project: /Users/jayromacorda/Develop/écri mark down
Thread: ios-port — read HANDOFF.md "## Thread: ios-port" first.

First, regenerate the in-session task list from the Pipeline section of that
thread (TaskCreate each item) — the file is the source of truth, not chat.

State: on branch ios-port, HEAD e0e2f97, PR #3 open (ios-port → main).
Build both platforms to confirm you're cold-start clean:
  SCHEME=$(xcodebuild -project "écri mark down.xcodeproj" -list 2>/dev/null | awk '/Schemes:/{getline; gsub(/^ +/,""); print; exit}')
  xcodebuild -project "écri mark down.xcodeproj" -scheme "$SCHEME" -destination 'platform=macOS' build
Then do Pipeline item #1 (merge PR #3). Report what you did.
```
