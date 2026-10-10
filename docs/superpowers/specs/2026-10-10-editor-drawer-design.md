# Editor drawer (per-tab nvim, ⌘E)

## Goal

A right-hand drawer, owned by MacHerdr, that runs **nvim** so files can be read
next to the agent. One drawer per herdr tab; hiding it keeps nvim alive, so
buffers, cursor and undo survive toggling. Real editing work happens elsewhere
(a normal herdr tab running nvim) — the drawer is a viewer.

Flow that must feel instant: **⌘K → Files tab → pick a file → the drawer opens
with that file as the active buffer.** ⌘E shows/hides the drawer without
choosing a file.

## Decisions already made (with the user)

- MacHerdr-owned local process, not a herdr pane. herdr's layout is never touched
  and the drawer is invisible to herdr's own TUI. It dies with the app.
- Files reach a running nvim over its RPC socket (`--listen`), not by typing
  into the pty.
- Toggle key: ⌘E.
- Local devices only. Remote spaces get no drawer.
- ⌘K file selection **replaces** the earlier "type `:e` into an nvim pane / open
  a new nvim tab" behavior (that code is deleted, see Removals).

## Behavior

### Identity and lifetime
- Key: `EditorDrawerKey(deviceID, tabID)` of the tab containing the selected pane.
- A drawer is created lazily by the first ⌘E or ⌘K file open on that tab.
- Hiding sets `isVisible = false`; the view stays in the hierarchy (opacity 0, no
  hit testing, surface hidden) exactly like `model.shellSessions`, so the process
  and its content survive.
- Ends when: the user quits nvim (process exit → session removed, socket
  deleted, drawer hides; the next open starts a fresh nvim); the tab disappears
  from the device's tab list (reconciled on refresh → process terminated); or
  the app quits.

### Visibility rules
The drawer is drawn only while a herdr pane is attached
(`selectedAttachedEntry != nil`, `selectedShellID == nil`, `!isFileManagerActive`)
and the selected tab has a visible drawer. Selecting another tab shows that
tab's own drawer state. Other drawers keep running, hidden.

### ⌘E
- No drawer for this tab → create one (plain `nvim` in the tab's directory), show
  it, focus it.
- Drawer visible → hide it, return keyboard focus to the attached terminal.
- Drawer hidden → show it, focus it.
- Disabled when the selection is remote or nothing is attached. Lives in the
  Terminal menu as "Toggle Editor Drawer".

### ⌘K file open
`AppModel.openFile` keeps its signature (`path` absolute, `space`, `directory`):
1. No drawer for the tab → create one running `nvim -- <path>` and show it.
2. Drawer exists → show it, then make nvim edit `<path>` over RPC (below).
3. Focus the drawer.

### Opening a file in a running nvim
Two `nvim --server <socket>` client calls, run by a short-lived `Process`:
1. `--remote-send '<C-\><C-N>'` — leaves insert / terminal / cmdline mode so the
   next command is not swallowed.
2. `--remote-expr 'execute("edit " . fnameescape("<path>"))'` — the path is
   escaped as a Vim double-quoted string (backslash and `"`), then `fnameescape`
   handles the rest on the nvim side. This replaces the Swift-side
   `vimEscapedPath` for this purpose.

If the socket is gone (nvim crashed between the exit event and the call) the
session is dropped and the open is retried once as a fresh launch.

### Launching nvim
The app's launch environment is sparse, so nvim is started through the user's
login shell:
`/bin/sh -c 'cd "$1" && exec "${SHELL:-/bin/zsh}" -l -c "exec nvim --listen \"\$0\" ..."'`
(exact quoting is an implementation detail covered by a unit test on the built
argv). `--listen` takes `$TMPDIR/macherdr-nvim-<uuid>.sock`.

The absolute path of `nvim` for the RPC client calls is resolved once with
`$SHELL -l -c 'command -v nvim'` and cached. If nvim cannot be found, the user
sees the standard action-error alert ("nvim was not found in your shell PATH").

### Layout
`terminalStack` (under the space tab bar) becomes the left side of a new
`DrawerSplit`: `[ terminal area | divider | drawers ]`.
- Width ratio is a single `@AppStorage("editorDrawerRatio")`, default 0.45,
  clamped 0.25…0.7, draggable divider (same behavior as `SplitContainer`'s,
  deliberately a separate small view: `SplitContainer` hard-codes the ⌘D shell's
  dimming and focus semantics).
- The left side must keep one structural position (same warning as
  `SplitContainer`): the drawer appears by changing a frame width, not by
  branching the view tree, otherwise every attach would be torn down.
- Drawer views render with the same font/theme/mouse settings as
  `ShellTerminalView`, via a new optional `command: TerminalCommand?` parameter
  on `ShellTerminalView` (nil = today's login shell).

## Components

| Unit | Responsibility | Depends on |
|---|---|---|
| `EditorDrawerKey`, `EditorDrawerSession` (HerdrKit-free app types) | identity, socket path, directory, visibility | — |
| `EditorDrawerRegistry` (pure, unit-tested) | key → session; `toggle`, `show`, `remove`, `reconcile(liveTabs:)` returns sessions to terminate | — |
| `NvimCommand` (pure, unit-tested) | builds the launch `TerminalCommand` and the two client argv arrays | — |
| `NvimLocator` | resolves/caches the nvim path via the login shell | `Process` |
| `AppModel` additions | `selectedTabKey`, `toggleEditorDrawer()`, rewritten `openFile`, reconcile hook in refresh | registry, `NvimCommand` |
| `DrawerSplit` + `EditorDrawerView` | layout, divider, kept-alive drawer terminals | `ShellTerminalView` |
| Terminal menu item | ⌘E | `AppModel` |

## Removals
`HerdrService.openInEditor`, `launchEditor`, `foregroundProcessNames`,
`isEditorProcessName`, `vimEscapedPath`, and their test, plus the pane-search
branch in `AppModel.openFile`. They exist only for the superseded behavior.

## Error handling
- nvim missing → action-error alert; no drawer created.
- Client RPC non-zero exit → drop session, retry once as a fresh launch, then
  surface the alert.
- Socket file always removed on session end and best-effort at app start
  (`macherdr-nvim-*.sock` older than the process).

## Testing
- Unit: registry (toggle/show/remove/reconcile), `NvimCommand` argv and path
  quoting (spaces, quotes, `$`), RPC expression escaping.
- Integration (manual, documented in the plan): ⌘E toggles and buffers survive;
  ⌘K file opens in a new drawer and in an existing one that is in insert mode;
  `:q` closes the drawer; closing the herdr tab terminates its nvim; switching
  tabs swaps drawers; remote space disables ⌘E.

## Open risks
1. **⌘E may be consumed by the terminal view** (`LineBreakTerminalView` maps
   ⌘-editing keys to readline chords). Menu key equivalents should win, but this
   must be verified first in the plan; fallback is a different chord, to be
   chosen with the user.
2. `--remote-send` / `--remote-expr` behavior in terminal-mode and in
   cmdline-window edge cases needs a quick spike against the installed nvim
   before the plan commits to the two-call sequence.
3. Ghostty surface visibility toggling for a hidden-but-alive drawer relies on
   the same `setSurfaceVisible` path shell sessions use; assumed, to be
   confirmed.
