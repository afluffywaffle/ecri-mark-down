# Sync + Apple Watch — design note

Status: **proposal** — not implemented. Open decisions marked **☐** at the bottom.
Companion: `docs/USAGE.md` (user-facing).

## Goal

Scratchpad notes that sync across macOS, iPhone/iPad, and Apple Watch, with **no
file hierarchy** — notes are a flat list, true to the product intent. The watch is
a quick-capture + glance surface. The existing file-based `.md` workflow on macOS
is preserved as an import/export **gateway**, not replaced.

## Constraint that drives everything

The macOS app's identity is "open any `.md` wherever it lives" (Finder, drag-drop,
security-scoped bookmarks). Sync wants a single canonical store every device
agrees on. The resolution:

- **Synced notes** live in CloudKit records. iPhone, iPad, Watch, and macOS all
  read/write the same record set. This is the source of truth for synced content.
- **Local scratch files** stay on macOS exactly as today — tabs over arbitrary
  paths, **not** synced. This preserves the original lightweight scratchpad.
- **Import / export** moves content between the two worlds: export a synced note
  to `.md`, import a `.md` as a synced note. No hidden filesystem imposed on the
  user.

So the app has two surfaces, and the line between them is explicit: *records sync,
files don't.*

## Why CloudKit (private database), not iCloud Drive

| | CloudKit records | iCloud Drive / ubiquitous container |
|---|---|---|
| Natural shape | Flat list of notes — matches "no hierarchy" | Filesystem — hierarchy is smuggled in |
| Watch access | Native framework, direct sync | watchOS has no full iCloud Drive container access to the same degree |
| Sync engine | Built in (change tags, subscriptions, push) | Built in (per-file) |
| Cost | Free tier generous for personal use | — |
| Friction | New storage layer + entitlement | Reuses existing `fileURL` path |

CloudKit's flat record model is the only one that matches the product intent *and*
gives the watch a clean path.

## Data model

One record type, flat, no relationships:

```
Note
├─ id          String   (UUID, the record ID / stable identity)
├─ title       String
├─ content     String   (markdown)
├─ createdAt   Date
├─ updatedAt   Date     (drives ordering + conflict resolution)
└─ deletedAt   Date?    (soft delete — see below)
```

Content is stored inline as a string; a scratchpad note is small, so CloudKit
records (default ~1 MB each) are more than enough — no `CKAsset` needed.

## Sync architecture

**Recommendation: a thin hand-rolled CloudKit layer over the existing `@Observable`
store**, not Core Data / `NSPersistentCloudKitContainer`.

- The app is deliberately light and the model is plain `@Observable` classes.
  Core Data would be a large architectural change to solve a small problem.
- A `SyncService` singleton owns `CKDatabase`, maps `Document ↔ CKRecord`, and
  talks to `EditorStore` through a small adapter. The existing editors don't change.
- Incremental sync via `CKFetchRecordZoneChangesOperation` (change tags) — a
  few records, so this is simple.

Tradeoff to be aware of: `NSPersistentCloudKitContainer` (Core Data + CloudKit) is
Apple's blessed path — automatic sync, conflict handling, works under Family Setup
— at the cost of migrating the whole model to Core Data. For a personal scratchpad
I'd avoid that weight, but it's the fallback if hand-rolled sync gets fiddly.

### Conflict policy

**Last-writer-wins on `updatedAt`**, with a note-level guard: a device never
overwrites a locally-newer note with an older one, and edits made while offline
re-merge on the next fetch. Full 3-way merge / CRDT is overkill for notes.

### Deletion

**Soft delete** (`deletedAt`). Deletion propagates to all devices through the same
record path; records are purged after N days. Without soft delete, a tombstone
would be needed anyway to push "delete" to devices that missed it.

### Offline

CloudKit caches locally and re-syncs on connectivity. Editors never block on the
network — writes land in the local store immediately and push later (same
debounced-autosave shape the app already has).

## Platform story

### iOS / iPadOS (primary)

The existing SwiftUI UI stays. Opening/saving a synced note goes through
`SyncService` instead of the file picker. The file picker remains for importing
external `.md` into the synced store.

### macOS

Two coexisting modes, distinguished at open time:

- **File tabs** — exactly as today, arbitrary paths, unsynced (original scratchpad).
- **Synced notes** — read/write the CloudKit store; exportable to `.md`, and a
  `.md` can be imported.

This is the one real behavioral fork: the macOS app grows a "synced notes" surface
alongside file tabs. If the user would rather the macOS app become records-only
(`.md` purely import/export), that's **☐ D1** below.

### Apple Watch

watchOS has CloudKit as a native framework with subscriptions + push, so a watch
app **can sync directly** — it does not need to relay through the phone. But the
watch has a tight background budget (strictly limited background tasks/day), so
direct sync must be **incremental and resumable**, never assumed-complete.

Scoped watch surface (scratchpad-friendly):

- **Root = scratchpad, always.** Launching the app opens a fresh capture surface
  — on the go, the goal is "get a thought down," so capture is the landing, not a
  list. **☐ D2** covers what to do with an unsaved draft on relaunch.
- **Input: keyboard and voice-to-text from one field.** A focused `TextField`
  brings up the system input UI, which includes the **on-screen QWERTY keyboard**
  (QuickPath swipe + autocorrect) **and** the **dictation mic**. No custom input
  code — the app just needs the capture field to be the focus target.
  - **Keyboard availability is screen-size-gated**: Series 7+ / Ultra only
    (Ultra 3, the paired device here, is fine). Older/SE watches get dictation +
    Scribble, no QWERTY — the field still works, input just degrades gracefully.
  - **Dictation is on-device / offline** since watchOS 10, so voice capture works
    with no signal — the exact "on the go" case.
- **Recents/glance is secondary** — reachable from the scratchpad (button /
  crown), showing recent notes read-only. Never the landing surface.
- **No tabs, no view modes, no file management** on the watch.
- Local mirror of the small working set (few records); full sync when the app
  wakes, incremental fetch each time.

Design for the watch to prefer direct CloudKit, with the phone relay
(`WCSession`) as the low-latency fallback — real-world watch/CloudKit setups have
hit container-ID and initialization quirks, so the phone remains the most reliable
path when it's paired.

## Entitlements / project changes

- Add the **iCloud** capability with a **CloudKit container** to the app target(s).
- Add a **watchOS target** to the project (the app currently shares one SwiftUI
  target across macOS/iOS; the watch is a new target sharing model + sync code).
- Keep one container ID shared by iOS, macOS, and watch.

## Phases

1. **Sync core (iOS + macOS)** — container, `SyncService`, record mapping, import/
   export gateway, soft delete, LWW conflicts.
2. **macOS synced-notes surface** — resolves ☐ D1; pick tab-vs-record UX.
3. **Watch app** — scratchpad-root capture (keyboard + dictation via one field),
   recents glance, local mirror, direct CloudKit + WCSession fallback, incremental
   background sync.
4. **Polish** — offline edge cases, multi-window truth, migration from the current
   file-only workflow.

## Open decisions

- **☐ D1 — macOS truth model.** Recommended: *records sync, files don't* (two
  surfaces, `.md` as gateway). Alternative: macOS becomes records-only, `.md` is
  import/export. Affects phase 2.
- **☐ D2 — Watch draft behavior on relaunch.** Root = scratchpad is locked. Open
  question: relaunch always starts a **fresh** capture (clean slate, matches "open
  to a scratchpad"), while any **unsaved** draft from the last session is preserved
  (recoverable, never silently dropped) — e.g. surfaced in recents marked "Draft"
  with tap-to-return and discard. Recommended: fresh capture + preserved-draft
  recovery. Alternative: resume the last unsaved draft directly. Watch apps are
  dismissed by wrist-down mid-capture, so an in-progress thought must survive even
  though launch shows a clean pad.
- **☐ D3 — What syncs.** Every note in the store, or only a "synced" subset?
  Recommended: everything in the CloudKit store syncs; local files never do.

## Risks

- **Split-brain (records vs files)** is the main one — mitigated by the explicit
  import/export gateway and by never auto-migrating files into records.
- **watchOS background budget** — mitigated by incremental/resumable sync and a
  phone fallback.
- **CloudKit container config bugs on watch** (seen in the field) — mitigate by
  using one shared container ID and testing the watch path early.
- Scope creep on the watch — the capture + glance line is a deliberate wall.

## References

- Apple — [Keeping your watchOS app's content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date): CloudKit on watchOS, direct access, subscriptions, background budget.
- WWDC21 — [There and back again: Data transfer on Apple Watch](https://developer-rno.apple.com/videos/play/wwdc2021/10003/): Core Data + CloudKit (`NSPersistentCloudKitContainer`) for all-device sync.
- WWDC26 watchOS Group Lab — watch runtime constraints; sync must be resumable/incremental.
- [Supported capabilities (watchOS)](https://developer-apple-com.analytics-portals.com/help/account/reference/supported-capabilities-watchos): iCloud: CloudKit is a watchOS capability.
- Field reports: [SwiftData+CloudKit not arriving on watch](https://developer.apple.com/forums/thread/733397?answerId=758300022#758300022) (container-ID bug), [CloudKit init issues → WCSession fallback](https://developer.apple.com/forums/thread/742100).
- Watch text entry: [watchOS 10 keyboard activation](https://www.nextpit.com/how-tos/apple-watch-keyboard-activate-how-to-use-watchos-10) — keyboard is screen-size-gated (Series 7+ / Ultra); dictation works on all models; input methods share one text field.
