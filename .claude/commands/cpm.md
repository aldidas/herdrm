---
description: Commit current changes, push to the fork, and make install
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git push origin:*), Bash(make install)
---

Commit, push, and install MacHerdr.

1. Run `git status` and `git diff` to see what changed. If there is nothing to commit, skip to step 3 only if the user asked for an install anyway; otherwise say so and stop.
2. Stage the relevant files by name and commit with a conventional-commit message matching `git log` style (`feat(scope): …`, `fix(scope): …`), ending with the Co-Authored-By line from the session attribution.
3. Push to `origin` (the fork, aldidas/herdrm) only. Never push to `upstream`.
4. Run `make install` (release build, replaces /Applications/MacHerdr.app, relaunches).

Report the commit hash and whether the install succeeded.
