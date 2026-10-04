# Sidebar restyle, space tab bar, herdr-driven splits — design

Date: 2026-10-04 · Status: draft for review · Scope: macOS app (`Sources/HerdrM`), HerdrKit

## Intent

HerdrM is a native macOS frontend for herdr. The reference is `penso/herdr-gpui`
(Rust), which mimics the original herdr TUI: a compact sidebar of Spaces and
Agents, a tab bar for the selected space, and the tab's panes laid out as herdr
has them split. Success: opening a space shows the same tabs and the same split
layout herdr has, the sidebar reads like the reference screenshot, and existing
behavior (drag-and-drop reorder, sticky headers, device switching, unread
tracking, attach/takeover) keeps working.

Out of scope: the usage/status strip at the bottom of the reference; remote-device
git branches; retiring `SplitContainer` (agent + app-owned local shell).

## Verified herdr API (0.9.3, live socket)

- `tab.list` / `herdr tab list`: `tab_id, workspace_id, label, number, pane_count,
  agent_status, focused`. Also `tab.create/get/focus/rename/close`.
- `pane.layout` (`herdr pane layout --pane <id>`): `layout.{area, focused_pane_id,
  panes[{pane_id, focused, rect}], splits[{id, direction(right|down), ratio, rect}],
  tab_id, workspace_id, zoomed}`. Rects are in cells. The split tree is
  reconstructed from `splits` + pane rects (a split's two children are the groups of
  panes on either side of its divider).
- Writes: `pane.focus`, `pane.resize`, `pane.split`, `pane.close`, `pane.zoom`.
- Event `layout.updated` (already listed in `Models.swift`).
- Panes carry `cwd` / `foreground_cwd`; there is no branch field.

## Stage 1 — Sidebar

- Space row: status ring + name; second line muted branch; right-aligned `↑N` when
  the branch is ahead of upstream.
- Section strip `new … menu` between Spaces and Agents; Agents header carries a
  `priority` label.
- Agent row: single line (~28pt): status ring, brand icon, kind, muted
  `space · title` right-aligned. Plugin stats lines (model/context/usage) move to a
  hover tooltip and stay in the accessibility label. Blocked keeps a short
  "needs input" in the warning color; unread-done keeps its filled dot.
- Footer unchanged (All Devices, status dot, settings).
- Keep `StickySection` wrappers and the `*RowDragHost` overlays, frames and
  `sidebarDragChrome`; only row content changes.
- Branch: new `GitBranchResolver` (HerdrKit, macOS) reads `<cwd>/.git/HEAD`
  (walking up to the repo root; handles worktree `.git` files), caches by root with
  a short TTL, local device only. Ahead count via `git rev-list --count @{u}..HEAD`
  run off the main actor, same cache. Remote devices show no branch line.
- Tests: resolver against temp repos (branch, detached HEAD, worktree file, no repo).

## Stage 2 — Space tab bar

- New `SpaceTabBar` above the main pane for the selected space: tabs from `tab.list`
  (status ring, label, `×`), `+`, and trailing split / `…` actions.
- Click → `tab.focus`; `+` → `tab.create`; `×` → `tab.close` (via the existing
  close-confirmation path); double-click → rename sheet (reuse the rename flow).
- `AppModel` gains `tabs(in:)` and `selectedTab` per space, refreshed with the
  existing workspace/pane refresh and on tab events. Selecting an agent selects its
  tab and focuses its pane. `selectedPane` remains the focused pane within the tab so
  unread, attach keep-alive and search keep working.
- Tests: tab-list decoding, selection resolution (agent → tab), ordering by `number`.

## Stage 3 — Herdr-driven splits

- Model: `PaneLayout` (decoded `pane.layout`) → `SplitTree` (leaf(pane) |
  split(direction, ratio, a, b)) built in HerdrKit and unit-tested with the two live
  samples (2-pane `right`; 3-pane `down` + nested `right`).
- View: `HerdrSplitView` renders the tree recursively; each leaf is a terminal view
  attached per pane (`agent attach <pane> --takeover` for agents,
  `terminal attach <terminal_id> --takeover` for shells). Leaf identity is keyed by
  pane id so a layout change does not rebuild surviving terminals (same rule as
  `SplitContainer`'s no-conditional-branch comment).
- Focus: focused pane gets the highlighted border; click → `pane.focus`.
- Resize: divider drag → `pane.resize` (throttled, ratio-based), optimistic local
  ratio until the next layout arrives.
- Sync: refresh on `layout.updated`; poll fallback only if events prove unreliable.
- Zoom: when `zoomed`, render only the focused pane.
- Single-pane tabs render exactly as today.

## Risks

- `AppModel` selection is pane-centric (69k file); Stage 2 changes it. Mitigation:
  keep `selectedPane` semantics, add tab selection on top, land behind tests.
- N simultaneous `--takeover` attaches per tab: verify on a real 3-pane tab before
  building the rest of Stage 3; fall back to attach-on-focus if they conflict.
- No screenshot capability in the agent session: visual checks are the user's;
  layout parsing/tree building and branch resolution are covered by unit tests.

## Verification

`make kit-test` (new HerdrKit tests), `make build` after each stage; user reviews
each stage visually before the next starts.
