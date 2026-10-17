#!/usr/bin/env bash
# Usage: ./deploy.sh [-n]   (-n = dry run)
set -euo pipefail

REMOTE_USER="christian"
REMOTE_HOST="192.168.1.6"
REMOTE_DIR="~/Cerisier"

cd "$(dirname "$0")"

[[ -x bin/server/cerisier_server ]] || { echo "bin/server/cerisier_server missing; run 'nimble build' first" >&2; exit 1; }

# One multiplexed connection shared by every ssh/rsync call, so the password is asked once.
CTL="$(mktemp -u /tmp/cerisier-deploy-XXXXXX.sock)"
SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60)
ssh_remote() { ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@"; }
trap 'ssh "${SSH_OPTS[@]}" -O exit "$REMOTE_USER@$REMOTE_HOST" 2>/dev/null || true' EXIT

RSYNC_OPTS=(-avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r -e "ssh ${SSH_OPTS[*]}")
[[ "${1:-}" == "-n" ]] && RSYNC_OPTS+=(--dry-run)

# data/ (SQLite db, uploads) lives only on the server and is never touched.
ssh_remote "mkdir -p $REMOTE_DIR"

# -R keeps the relative paths so each source lands at the same place under REMOTE_DIR.
rsync "${RSYNC_OPTS[@]}" -R \
  bin/server/cerisier_server \
  web \
  tools \
  start-llama.sh \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"

# --chmod above strips the exec bit from files; restore it where needed.
[[ "${1:-}" == "-n" ]] || ssh_remote \
  "cd $REMOTE_DIR && chmod +x bin/server/cerisier_server start-llama.sh"

echo "Deployed to $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
