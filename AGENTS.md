# Takes: notes for agents

## Worktrees

Never create a worktree or clone next to this repo (`../takes-<task>`). The user's coding folder fills up with them.

- Put a worktree in your scratchpad or temp directory, e.g. `git worktree add "$TMPDIR/takes-<task>" origin/main`.
- When your work is merged or abandoned, remove the worktree (`git worktree remove <path>`) and delete its local branch (`git branch -d <branch>`).
- Before removing a worktree you didn't create, make sure it has no uncommitted changes and no running process, and that its branch is merged into `origin/main`.
