#!/usr/bin/env bash
# Wrapper script that launchers can point at to start the Phoenix dev
# server. Local-only by default — config/dev.exs falls back to a libsql
# file at priv/data/to_do.db without any cloud sync.
#
# To run against the Turso primary instead (rare; only when you need to
# see prod data locally), source .envrc first:
#
#     source .envrc && ./.claude/run_phx.sh
#
# Or use the "phoenix-turso" entry in .claude/launch.json which sets the
# TURSO_* env vars directly.
set -e

# Hard-pin the worktree dir so cwd-state doesn't matter.
cd "$(dirname "$0")/.."

exec mix phx.server
