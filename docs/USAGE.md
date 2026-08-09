# écri mark down — usage

Lightweight Markdown scratchpad for macOS and iOS/iPadOS. One codebase; macOS
keeps its tab strip and menus, iOS uses Safari-style tab paging.

## Getting a file in and out

**macOS**
- Open: File ▸ Open… (⌘O), drag a file onto the editor, or double-click a file
  in Finder. Files open as tabs or windows per Settings ▸ "Open documents in".
- Save: ⌘S (File ▸ Save); ⌘⇧S for Save As. Autosave (on by default) writes
  documents that already have a location.
- Reveal in Finder: ⌘⇧R or tab context menu.
- Recent: File ▸ Open Recent.

**iOS / iPadOS** (no menu bar — everything is on the toolbar)
- Open: **folder** icon (top-left) → document picker. Also double-tap an
  external markdown file to hand it in.
- Save: **down-arrow** icon (top-right) — enabled once the current tab is dirty.
  A new (untitled) document prompts for a location the first time you save.

## Tabs (Safari-style on iOS)

- **No tab strip.** The toolbar center shows the current document's title.
- **Swipe left/right** on the editor to page between open tabs.
- **Tabs button** (overlapping-squares, top-right) opens a tab overview:
  tap a tab to switch, **swipe left on a row** to close it, **+** for a new tab.
- **Tap the title** to rename the current document (inline field, like
  double-clicking a tab on macOS). Tab switching stays on the Tabs button.
- The modified (dirty) tab shows an orange dot in the overview.
- Closing a dirty tab asks **Save / Don't Save / Cancel** before discarding.

macOS keeps its top tab strip (double-click a tab to rename; ✕ or context menu
to close; drag a tab to a new window).

## View modes

iOS: pick **Source / Split / Preview** from the view menu (the toolbar button
showing the current mode). macOS: ⌘⇧P cycles, or use ⌘1/⌘2/⌘3.

- **Source** — raw Markdown with syntax highlighting.
- **Preview** — rendered HTML-style preview (headings, emphasis, code, quotes,
  lists, links, tables, images, task lists).
- **Split** — both at once. macOS: editor left / preview right. iOS/iPadOS:
  editor **top** / preview **bottom** (side-by-side would be too narrow).

## Editor chrome

- Line numbers, current-line highlight, sticky headings, status bar, formatting
  toolbar: each is toggleable. iOS: **ellipsis (⋯) → Show/Hide Formatting
  Toolbar**, and **ellipsis → Settings** for the rest. macOS: View ▸ Editor
  submenu and Settings.
- **Authoring mode** = formatting toolbar on. iOS: ellipsis menu; macOS: toolbar
  pencil button or View ▸ Editor ▸ Show Formatting Toolbar (⌘⇧B).

## Files

Plain text is stored as-is. `.md`, `.txt`, `.rtf`, `.epub`, `.docx` open (RTF/EPUB
are flattened to plain text; `.docx` reads/writes as plain paragraphs). Saving to
`.docx` warns that Markdown formatting is lost.
