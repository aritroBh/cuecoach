#!/bin/sh
# Create .worktrees/<name> on branch wt/<name> and copy the local Claude
# settings (build guard hook) into it. Usage: tools/new-worktree.sh plan-009
set -eu
name=${1:?usage: tools/new-worktree.sh <name>}
root=$(git rev-parse --show-toplevel)
free_gb=$(df -g / | awk 'NR==2{print $4}')
[ "$free_gb" -ge 40 ] || { echo "Only ${free_gb} GB free (need 40). Clean up first." >&2; exit 1; }
git -C "$root" worktree add "$root/.worktrees/$name" -b "wt/$name"
if [ -f "$root/.claude/settings.local.json" ]; then
  mkdir -p "$root/.worktrees/$name/.claude"
  cp "$root/.claude/settings.local.json" "$root/.worktrees/$name/.claude/"
fi
echo "$root/.worktrees/$name"
