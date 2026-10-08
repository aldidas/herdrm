---
name: upstream-check
description: Fetch the latest from upstream missuo/herdrm, compare it with main, explain what changed in plain language, and give a verdict (up to date / safe to merge / conflicts). Use when the user asks to check, pull, or compare upstream updates.
disable-model-invocation: true
---

# upstream-check

Read-only check of upstream `missuo/herdrm` against the personal branch `main`.
**`main` is the source of truth for the app.** Upstream is only an input: a merge is
acceptable only if everything on `main` still works afterwards. When upstream and my
branch disagree, my branch's behavior wins; adopt upstream's change only where it doesn't undo or
break mine. Judge every verdict by "could this break my branch?", not "does git merge cleanly?".

Never merge into `main` or push anywhere unless the
user explicitly asks afterwards. Remote git work goes to the fork `origin` (aldidas/herdrm) only.

## Fork goal and policy

The fork's goal is a **simple, minimalist app that keeps herdr's basic TUI layout and
functionality and is macOS-native**. So upstream is adopted **selectively by cherry-pick**
(`git cherry-pick -x`), not merged wholesale. Judge each new upstream commit by: does it fix a
bug on a path I use, or does it add UI/config/features beyond the herdr layout? Take the first
kind; skip the second unless the user asks. `docs/upstream-triage.md` records what was taken
and skipped and the last reviewed upstream commit; update it whenever you act on a check.

## Steps

1. **Ensure the remote.** If `upstream` is missing:
   `git remote add upstream https://github.com/missuo/herdrm.git && git remote set-url --push upstream DISABLED`.
   Then `git fetch upstream --tags`.

2. **Find what's new.** Use the real merge base, not a hardcoded commit (it moves after merges):
   - `BASE=$(git merge-base main upstream/main)`
   - `git log --oneline --no-merges $BASE..upstream/main`
   - Ignore commits already decided in `docs/upstream-triage.md` (review only those after its
     "last reviewed" hash).
   - If empty: report "up to date" with the upstream HEAD hash/date/latest tag and stop.

3. **Understand the updates.** For each new commit/tag, read the subject, the `CHANGELOG.md`
   diff (`git diff $BASE upstream/main -- CHANGELOG.md`), and `git diff --stat $BASE upstream/main`.
   Open the actual diff for anything non-trivial.

4. **Check impact on my work.**
   - Overlapping files: intersect `git diff --name-only $BASE upstream/main` with
     `git diff --name-only $BASE main`.
   - Trial merge without touching the tree: `git merge-tree --write-tree main upstream/main`
     (non-zero exit / `CONFLICT` lines = textual conflicts; list the files).
   - Even if textually clean, look at overlapping files for *semantic* clashes (renamed/removed
     APIs my code calls, changed behavior in areas I restyled: sidebar, split layout, key router,
     titlebar, Sparkle removal in `MacHerdrApp.swift`/`project.yml`, themes).
   - Dependency bumps (`project.yml`, `Package.resolved`, HerdrKit) deserve a mention.

5. **Verify that my branch survives the merge.** Required whenever upstream touched anything
   other than docs/CI/changelog, even if the merge was textually clean or conflicted (resolve
   conflicts in the throwaway branch in favor of my branch's behavior).
   In a throwaway worktree (scratchpad dir), not the main checkout:
   `git worktree add <scratch>/up-check -b tmp/upstream-check main`, `git merge upstream/main`,
   then `make kit-test && make build` there. Also check regressions beyond compiling:
   - `git diff main tmp/upstream-check` must contain only upstream's intended
     changes; any removed or altered line of mine is a red flag.
   - Confirm my features' code is still wired up (sidebar restyle, split layout/dividers,
     `HerdrKeyRouter`, space tab bar, theme picker, titlebar, Sparkle removal) by grepping for
     them in the merged tree.
   Report pass/fail with the relevant output, then remove the worktree and delete
   `tmp/upstream-check`. Skip only for docs/CI/changelog-only updates, and say so.

6. **Report**, in plain language for a non-maintainer reader:
   - **What's new upstream:** a short bullet list by user-visible effect (e.g. "fixes X",
     "adds Y"), not commit hashes. Mention version(s).
   - **Does it touch my work:** which of my features/files overlap, or "no overlap".
   - **Verdict**, exactly one of:
     - **Up to date** — nothing new.
     - **Safe to merge** — build and tests pass on the trial merge, none of my features changed or
       regressed, and the diff against my branch is only upstream's intended changes.
     - **Merge with care** — builds, but upstream changed code my features depend on or sit
       beside; say exactly which of my features could be affected and what to test by hand.
     - **Conflicts / would break my work** — conflicting files, or a clean merge that fails the
       build/tests or regresses a feature. Say what each side did and propose a resolution that
       keeps my behavior (or recommend skipping that upstream change).
   - **Next step:** recommend which commits to cherry-pick and which to skip (with reasons), and offer the exact
     action (a branch with `git cherry-pick -x …`, build/test, then fast-forward `main` and push
     to `origin`) and wait for the user's go-ahead. Prefer merge over rebase (rebase would force-push the fork).
