# Safe Bashrc Auto-Sync (Publish-Only) — Design Notes

Status: design only. Not yet implemented in `~/.bashrc`.
Scope: harden the existing `sync_commit_push_bashrc` function for a future
second machine, while preserving the current "cheap when idle, auto-backed-up
to GitHub" behavior.

This document records the trade-offs, design decisions, and known
breakdown points of the proposed solution. It is intentionally skeptical:
every section names where the approach is weak.

---

## 1. Problem statement

Today `sync_commit_push_bashrc` runs on every shell start and, after an
edit, commits the current `~/.bashrc` into the dotfiles repo and pushes to
`origin/main`. With a single machine this is safe and useful: it produces a
versioned backup on GitHub that you can `git show` at any time.

The moment a **second machine** exists, the naive version breaks: editing
bashrc on machine B advances `origin/main`, so opening a shell on machine A
(even one that has not been edited) can attempt a push that is no longer
fast-forward. The proposed design makes that case safe instead of corrupting
or clobbering history.

## 2. The fork: publish-only vs. bidirectional

The single most important decision is **what "sync" means across machines**.
Two distinct behaviors exist and they are not the same:

- **Publish-only (safe push).** If *this* machine edited bashrc, push it —
  but never stomp a remote that moved ahead. Conflicts are reported for
  manual resolution.
- **Bidirectional sync.** Also pull a newer remote bashrc back into
  `~/.bashrc` on this machine.

The proposed design targets **publish-only**. Rationale: with machine #2 not
yet existing, there is no need to pull. Adding pull now would complicate the
shell-init path and introduce a class of failure (overwriting local edits with
remote content) that has no payoff yet.

**Decision required when implementing:** confirm publish-only is still the
intent. If bidirectional is wanted, see section 7 for what changes. Until
then, the function name `sync_*` arguably overstates behavior — it is
publish, not sync.

## 3. Proposed sequence (publish-only-safe)

Ordered so that the remote is inspected *before* any local commit, keeping
the working tree clean if a rebase is needed:

1. Guard: if `~/.bashrc` equals the tracked copy (`cmp -s`), return early.
   This keeps shell init cheap when nothing changed — preserves current behavior.
2. Ensure the repo exists and has upstream `origin/main`; otherwise return 0
   (no-op, same as today).
3. `git fetch origin main`.
   - Offline or auth-expired fetch must degrade to a **warning**, never a
     fatal error. A failed shell-start push must not break the prompt.
4. Compute `BEHIND = $(git rev-list --count HEAD..origin/main)`.
5. Copy `~/.bashrc` → tracked copy.
6. `git add bashrc`; if `git diff --cached --quiet`, return 0 (no real change).
7. `git commit -m "update bashrc ($(hostname) $(date -Iseconds))"`.
   - Including `hostname` and a timestamp fixes the flat `update bashrc`
     history problem for free.
8. If `BEHIND > 0`: `git rebase origin/main`.
   - On failure → conflict handler (section 5), then return 1.
9. `git push --force-with-lease origin main`.
   - Rejection → bounded retry (refetch, rebase, push) ×3.
   - Still failing → red error with next steps (section 5), return 1.
10. Success log.

## 4. The load-bearing safety choice

The push uses **`--force-with-lease`, not plain `--force`**. This is the
property that makes publish-only actually safe: the push is rejected if
`origin/main` advanced since the local fetch. A concurrent edit on machine B
therefore blocks machine A's push rather than overwriting it.

"Safe publish-only" means **never blind-force**, not "never lose data."
The remaining risk is the *older-stomp*: if this machine holds a bashrc that
is actually older than `origin/main` but differs from its own tracked copy, it
will commit and (with lease) be rejected rather than clobber. The lease turns
a potential data loss into a reported conflict. Because bashrc edits are
infrequent, the divergent-edit window is tiny — but it is the case the design
must defend against, and the lease is what defends it.

## 5. Conflict branch (the requested red error)

`git rebase` leaving the repo mid-rebase at **shell startup** is the worst
outcome, so the handler must restore a clean working tree before explaining:

```
conflict_handler():
  if "bashrc" appears in `git diff --name-only --diff-filter=U`:
    git rebase --abort          # critical: restore clean tree at shell init
    print_red_error:
      "bashrc has conflicting edits on two machines.
       Origin main moved ahead and the changes overlap.
       Nothing was pushed. To resolve:
         cd <dotfiles dir>
         git fetch origin
         git pull --rebase origin main
         # open bashrc, fix the <<<<<<< markers
         git add bashrc
         git rebase --continue
         git push --force-with-lease origin main
       Then reopen your shell."
    return 1
```

The `--abort` keeps the user's shell usable even though resolution is manual.
Manual resolution is acceptable here because divergent edits are rare; auto-
merging bashrc is not worth the complexity.

## 6. Trade-offs

| Trade-off | Accepted | Why |
|---|---|---|
| Auto-push on shell init (network at startup) | Yes | Only triggers after a real edit (`cmp` guard); gives hands-off GitHub backup |
| Manual conflict resolution | Yes | Divergent edits are rare; auto-merge of a config file risks silent corruption |
| `--force-with-lease` over plain push | Yes | Prevents stomping a remote that moved ahead |
| Rebase (linear history) over merge | Yes | Cleaner history; bashrc is single-file and low-conflict |
| No remote→local pull | Yes (for now) | No second machine yet; pull adds overwrite risk with no current payoff |
| `cmp`-gated fetch | Yes | Keeps idle shells fast; fetch only when there is something to publish |

### Costs introduced by this design

- **More moving parts than today.** Fetch, behind-count, rebase, lease push,
  retry, conflict abort. Each is a place to fail. The current code is a
  straight copy-commit-push; this is a small state machine.
- **Shell-init latency after an edit.** A rebase + push adds seconds the first
  shell after an edit. Acceptable because it is gated behind an actual change.
- **Reliance on `gh`/`git` auth at startup.** Mitigated by degrading fetch
  failures to warnings, but a permanently-expired token means your *only*
  push-based backup silently stops working. You still have manual `git push`
  and the ability to pull, so this is low-risk — but it is a real gap: the
  auto-push is not a guaranteed backup, only a convenient one.

## 7. Where this will break down

1. **Second machine without bidirectional pull.** If you ever edit bashrc on
   machine B and then open a shell on machine A, A's push is rejected (good),
   but A never learns about B's change. You must remember to pull manually.
   The `sync` name will mislead you. Fix: implement the pull half (below).

2. **Older-stomp before lease rejection.** The lease protects against a remote
   that moved *since your fetch*. It does **not** protect against this machine
   holding genuinely stale content that differs from its own tracked copy. The
   lease makes that a rejection, not a clobber — but you still get a failed
   push and a manual resolve. This is the fundamental limit of publish-only.

3. **Concurrent shells, both edited.** The rare case where two shells on the
   same machine both catch a diff and both commit+push. The retry loop plus
   lease handles the second writer (it gets rejected), but you may see a
   transient red error. Resolves on next shell. Benign, not corrupting.

4. **Mid-rebase abort leaves you to remember.** The handler aborts and tells
   you the steps, but nothing re-runs it for you. If you ignore it, the next
   shell will hit the same divergence and print the same error. Self-correcting
   only when you follow the steps.

5. **Branch / upstream assumptions.** The design hard-codes `main` and
   `origin/main`. If you move to a branch workflow, `BEHIND`, rebase, and push
   all bypass it. The function would either no-op or push to the wrong place.
   Make branch name a variable, not a literal, before adopting any branch model.

6. **`git` unavailable or repo not a git dir.** Step 2 returns 0 today; the
   new design must preserve that exact early-return so a broken repo never
   blocks the prompt.

### Bidirectional variant (only if needed later)

To add remote→local pull, step 8 gains a branch:

```
if BEHIND > 0 and LOCAL_DIFF == 0:
    git merge --ff-only origin/main
    copy tracked copy -> ~/.bashrc       # propagate remote change locally
elif BEHIND > 0 and LOCAL_DIFF != 0:
    git rebase origin/main  -> conflict handler
```

This introduces a new risk the publish-only version avoids: a remote change
can overwrite local `~/.bashrc` without you explicitly asking. Only adopt it
when a second machine actually exists and you want two-way consistency.

## 8. Implementation readiness

- Do **not** implement until machine #2 exists. The current naive version is
  correct for one machine and cheaper to reason about.
- When implementing, keep the existing `cmp` early-return and the
  `[[ -d $repo/.git ]]` repo guard; add only: pre-commit fetch + behind
  count, rebase-on-behind, `--force-with-lease` push, and the aborting
  conflict handler.
- Name the function to reflect behavior. `sync_commit_push_bashrc` implies
  two-way sync it does not perform. Consider `publish_bashrc_to_dotfiles` or
  `backup_bashrc` until bidirectional is real.

## 9. Open questions

- Confirm publish-only (no pull) is the intended scope.
- Is `main`/`origin/main` guaranteed, or should branch be a variable?
- Should a failed/offline push log to a file so you notice the backup stopped?
- Does the red error text need to link the actual dotfiles dir path at runtime?