# Upstream triage

This fork stays minimal: herdr's basic TUI layout and functionality, made macOS-native.
Upstream (`missuo/herdrm`) is adopted selectively by cherry-pick, not merged wholesale
(see `.claude/skills/upstream-check`). This file records what was decided so already
reviewed commits stop showing up as new.

**Last reviewed upstream commit:** `ab8f8ae` (v0.6.13), 2026-10-09.
Only commits after it need review.

## Taken (cherry-picked with `-x`, upstream hash in each commit message)

- `55d0d19` New Agent creates a space when the device has none
- `722ba85` Tell herdr attach the terminal draws Kitty graphics
- `5cfabed` SSH socket tunnel gets its own connection, never a ControlMaster
- `173939e`, `c499c71` Stop and reap tunnels orphaned by a killed app
- `5686ee6` Quit on SIGTERM without deadlocking the main queue

## Skipped on purpose (extra UI/config beyond the herdr layout, or features not used)

- Machine stats (meters, details panel, stats ssh session): `40f6ec2`, `84695dd`, `fc58043`,
  `de19fae`, `ab8f8ae`
- grazr accounts (switch, re-auth, dial, clock, refresh): everything touching `Grazr*`
- Custom launch arguments and YOLO mode: `620fb84`
- tailcat device fixes: `2e52786`, `81ef2ec`, `f845955`, `3dfa6fc`
- `fd92031` local Release version stamping, `0ba0ee5` CI release notes, changelog commits

Revisit a skipped item only if the user asks for it; it stays available in `upstream/main`.
