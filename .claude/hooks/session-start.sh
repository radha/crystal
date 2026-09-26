#!/bin/bash
# Cloud sessions only: provision the Crystal bootstrap compiler, the
# PostgreSQL test cluster (+ standby) and Redis, and export the spec
# environment into the session. See .agent-context/README.md.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

env_lines=$("$CLAUDE_PROJECT_DIR/.agent-context/setup/provision-linux.sh")
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "$env_lines" >> "$CLAUDE_ENV_FILE"
fi
exit 0
