#!/usr/bin/env bash
set -euo pipefail

fork_branch="${1:-glossolalia}"
upstream_remote="${UPSTREAM_REMOTE:-upstream}"
upstream_branch="${UPSTREAM_BRANCH:-main}"
upstream_ref="$upstream_remote/$upstream_branch"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "tracked worktree changes exist; commit or stash before rebasing" >&2
  exit 1
fi

git config rerere.enabled true
git config rerere.autoupdate true

git fetch --prune "$upstream_remote" "$upstream_branch"
git switch "$fork_branch"

old_base="$(git merge-base "$fork_branch" "$upstream_ref")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safety_name="${fork_branch//\//-}"
safety_branch="codex/safety-${safety_name}-pre-upstream-${timestamp}"
git branch "$safety_branch" "$fork_branch"

if git show-ref --verify --quiet refs/heads/main; then
  if git merge-base --is-ancestor main "$upstream_ref"; then
    git branch --force main "$upstream_ref"
  else
    echo "local main has commits outside $upstream_ref; leaving it unchanged" >&2
  fi
fi

if ! git rebase "$upstream_ref"; then
  echo
  echo "rebase stopped on conflicts"
  echo "resolve conflicts, then run: git rebase --continue"
  echo "abort with: git rebase --abort"
  echo "pre-rebase state: $safety_branch"
  exit 1
fi

echo "rebased $fork_branch onto $upstream_ref"
echo "pre-rebase state: $safety_branch"
echo "range-diff:"
git range-diff "$old_base..$safety_branch" "$upstream_ref..$fork_branch"
