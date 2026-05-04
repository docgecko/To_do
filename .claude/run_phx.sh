#!/usr/bin/env bash
# Wrapper script that the launch.json points at.
# Sources the local .envrc (TURSO credentials, etc.) so the Phoenix server
# starts in libsql embedded-replica mode automatically.
set -e

# Hard-pin the worktree dir so cwd-state doesn't matter.
cd "$(dirname "$0")/.."

if [ -f .envrc ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.envrc
  set +a
fi

exec mix phx.server
