# Sync + Apple Watch — design note

Status: **proposal** — not implemented. Decisions settled at the bottom.
Companion: `docs/USAGE.md` (user-facing).

## Goal

One **fast, focused scratchpad** — "something focused on a task and is fast,"
no fluff. A thought jotted on the Apple Watch syncs and is editable on iPhone and
Mac. The notes *are* `.md`, so they're portable into heavier tools (Obsidian,
VS Code, Xcode) — the format is the escape hatch, not a file manager. Distributed
through the App Store.

## Constraint that drives everything

Every platform has one distinct, minimal job, and they share one store:

- **Apple Watch** — a thought jot. Current pad + "New Scratchpad" (long-press →
  confirm). Nothing else.
- **iPhone / iPad** — the synced scratchpad, plus opening other `.md` files for
  **short edits on the go**.
- **macOS** — a quick way to open and **look at** a `.md` file. People using
  Markdown already have the heavy hitters; this is the thing that shows when you
  ⌘⇥, not something buried inside another app.

The resolution:

- **The synced scratchpad store is the spine.** One flat set of notes in CloudKit.
  Watch, iPhone, and Mac all read/write it. Everything in the store syncs.
- **Opening an arbitrary `.md` is a lightweight, unsynced layer on top** — read /
  short-edit on macOS and iOS, like opening a doc in a viewer. It is *not* a file
  manager, and it is *not* the store's source of truth.
- **Import / export** is the bridge: export a synced note to `.md`, import an
  external `.md` as a synced note. `.md` stays the portable format throughout.

So the model is one store, not two worlds: *the store syncs; quick `.md` viewing
is a thin, unsynced convenience around it.*

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
├─ archivedAt  Date?    (rolled off the watch's "current" pad — see watch section)
└─ deletedAt   Date?    (permanent delete on phone/Mac — soft delete, see below)
```

The **current scratchpad** is the note with `archivedAt == nil` (only one ever, by
construction). The watch shows only it; the phone/Mac show it on top of the archive.

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

### Apple Watch — a thought jot

watchOS has CloudKit as a native framework with subscriptions + push, so a watch
app **can sync directly** — it does not need to relay through the phone. But the
watch has a tight background budget (strictly limited background tasks/day), so
direct sync must be **incremental and resumable**, never assumed-complete.

The watch is **one pad and one gesture**:

- **Root = the current scratchpad.** Launching opens the current pad (the one note
  with `archivedAt == nil`) — it resumes, not a fresh pad, so a half-typed thought
  survives wrist-down. There is no list on the watch.
- **Input: keyboard and voice-to-text from one field.** A focused `TextField`
  brings up the system input UI, which includes the **on-screen QWERTY keyboard**
  (QuickPath swipe + autocorrect) **and** the **dictation mic**. No custom input
  code — the app just needs the capture field to be the focus target.
  - **Keyboard availability is screen-size-gated**: Series 7+ / Ultra only
    (Ultra 3, the paired device here, is fine). Older/SE watches get dictation +
    Scribble, no QWERTY — the field still works, input just degrades gracefully.
  - **Dictation is on-device / offline** since watchOS 10, so voice capture works
    with no signal — the exact "on the go" case.
- **New scratchpad: long-press → confirm.** A long-press (the watch's native
  `contextMenu` — gives the haptic for free) offers **"New Scratchpad."** Tapping
  it archives the current pad (`archivedAt = now`) and opens a fresh empty one.
  The two-step flow makes an accidental roll impossible; an **empty pad is not
  archived** (no noise in the archive). The archived pad syncs to iCloud and
  reappears on iPhone/Mac.
- **No tabs, no view modes, no file management, no archive browsing** on the watch.
- Local mirror of the working set (the current pad, a few recent notes); full sync
  when the app wakes, incremental fetch each time.

Design for the watch to prefer direct CloudKit, with the phone relay
(`WCSession`) as the low-latency fallback — real-world watch/CloudKit setups have
hit container-ID and initialization quirks, so the phone remains the most reliable
path when it's paired.

### iPhone / iPad — the scratchpad, plus quick `.md` edits

- The **synced scratchpad** is the center: current pad on top, archive below, flat
  list, no hierarchy. Edit in the existing editor (source / preview / split).
- **Open other `.md` files for short edits on the go** — the file picker stays,
  but as a lightweight quick-edit layer, not a file manager. Opening an external
  `.md` lets you read/tweak it and save back; it is not synced, and does not join
  the store unless the user imports it.

### macOS — quick open and look at a `.md`

- **The fast view/edit surface.** Open a `.md` (⌘⇥ first, ⌘O, drag onto the Dock
  icon) and *look* — this is the lightweight native viewer that shows when you
  ⌘⇥, not something buried inside another app. It is deliberately not a project
  editor, not Xcode/VS Code/Obsidian.
- **Synced notes read/write the CloudKit store** too — same store as the phone and
  watch; export to `.md` or import an external `.md` as a synced note.
- No file-manager ambition: quick open/view/short-edit, not tab farms over
  arbitrary paths.

## Competition & differentiator

The space exists — dictation-to-a-note on the watch is table stakes. Rough map:

| App | Watch capture | Markdown | macOS editor | Model |
|---|---|---|---|---|
| Tot Mini (Iconfactory) | ✓ dictation + Scribble | auto-translates | ✗ — capture app | one-time |
| Nota | ✓ | vault sync (Pro) | ✗ | subscription |
| Scratchpad (Sindre Sorhus) | ✓ | ✗ plain text | ~ single note | one-time |
| SnipNotes / Yellow Note / Watch Notes | ✓ | ✗ | ✗ | free / IAP |
| **écri mark down (this)** | planned | **native** | **fast ⌘⇥ viewer** | **personal** |

The differentiator is the combination, not any single feature:

- **A real Markdown editor on every surface.** The watch is capture-only, but every
  captured thought is a real, editable Markdown note in a full editor (syntax
  highlighting, source/preview/split, formatting, themes) on macOS and iOS. Tot
  translates to Markdown but is a capture app with no editor; Nota's editor is
  behind a subscription.
- **No hierarchy, no vault, no plugin system.** Deliberately the anti-Obsidian:
  no folder tree, no vault, no account, no AI. Open and write.
- **macOS is the fast ⌘⇥ viewer.** The lightweight thing that shows when you
  switch apps to glance at a `.md` — most scratchpad apps treat the Mac as an
  afterthought (a dot, a list), and the heavy `.md` editors are Xcode / VS Code /
  Obsidian. This sits in the middle: fast to open, native, no project ceremony.
- **Private + no subscription.** CloudKit private DB, your own iCloud, no AI
  scanning content, no recurring cost.

Honest caveat: this is a personal app, not a market play. The differentiator that
matters is that it's built to one person's exact workflow — and that workflow
happens to sit in the macOS-editing-first gap these apps leave open.

## Entitlements / project changes

- Add the **iCloud** capability with a **CloudKit container** to the app target(s).
- Add a **watchOS target** to the project (the app currently shares one SwiftUI
  target across macOS/iOS; the watch is a new target sharing model + sync code).
- Keep one container ID shared by iOS, macOS, and watch.

## Phases

1. **Sync core (iOS + macOS)** — container, `SyncService`, record mapping, current-
   pad + archive model, soft delete, LWW conflicts.
2. **macOS quick `.md` viewer + synced notes** — fast open/look, store reads/writes,
   import/export bridge.
3. **iPhone scratchpad UI** — current pad on top, archive below, flat list; external
   `.md` quick-edit.
4. **Watch app** — current pad + long-press "New Scratchpad", keyboard + dictation,
   local mirror, direct CloudKit + WCSession fallback, incremental background sync.
5. **Polish** — offline edge cases, multi-window truth, migration from the current
   file-only workflow.

## Decisions (settled)

- **D1 — macOS role.** Quick open-and-look at `.md` (⌘⇥-visible, lightweight) plus
  synced-store reads/writes. Not records-only, not a file manager.
- **D2 — Watch draft behavior.** Relaunch **resumes the current pad** — it is the
  rolling scratchpad, not a fresh pad. Rolling to a new one is long-press →
  confirm "New Scratchpad" → archive current → fresh empty pad; empty pads are
  not archived.
- **D3 — What syncs.** Everything in the CloudKit store syncs; quick-opened `.md`
  files never do.

## Risks

- **The store vs quick-opened `.md` could drift** — mitigated by keeping quick-open
  explicitly unsynced and by the import/export bridge; never auto-migrating files
  into records.
- **Accidental roll on the watch** — mitigated by the two-step long-press →
  confirm, and by never archiving an empty pad.
- **watchOS background budget** — mitigated by incremental/resumable sync and a
  phone fallback.
- **CloudKit container config bugs on watch** (seen in the field) — mitigate by
  using one shared container ID and testing the watch path early.
- Scope creep on the watch — the one-pad + one-gesture line is a deliberate wall.

## References

- Apple — [Keeping your watchOS app's content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date): CloudKit on watchOS, direct access, subscriptions, background budget.
- WWDC21 — [There and back again: Data transfer on Apple Watch](https://developer-rno.apple.com/videos/play/wwdc2021/10003/): Core Data + CloudKit (`NSPersistentCloudKitContainer`) for all-device sync.
- WWDC26 watchOS Group Lab — watch runtime constraints; sync must be resumable/incremental.
- [Supported capabilities (watchOS)](https://developer-apple-com.analytics-portals.com/help/account/reference/supported-capabilities-watchos): iCloud: CloudKit is a watchOS capability.
- Field reports: [SwiftData+CloudKit not arriving on watch](https://developer.apple.com/forums/thread/733397?answerId=758300022#758300022) (container-ID bug), [CloudKit init issues → WCSession fallback](https://developer.apple.com/forums/thread/742100).
- Watch text entry: [watchOS 10 keyboard activation](https://www.nextpit.com/how-tos/apple-watch-keyboard-activate-how-to-use-watchos-10) — keyboard is screen-size-gated (Series 7+ / Ultra); dictation works on all models; input methods share one text field.
