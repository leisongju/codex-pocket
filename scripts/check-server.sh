#!/bin/bash
# Run on your Mac if the development cloud cannot reach the SSH endpoint.
set -euo pipefail
if [[ $# -lt 3 ]]; then
    echo 'Usage: bash scripts/check-server.sh HOST PORT USER [IDENTITY_FILE]' >&2
    exit 1
fi
host=$1
port=$2
user=$3
options=(-p "$port" -o ConnectTimeout=15)
if [[ $# -ge 4 ]]; then options+=(-i "$4"); fi
# Uses the Mac's normal known_hosts verification. Does not send chat messages.
ssh "${options[@]}" "$user@$host" 'bash -lc '\''
  printf "Codex version: "
  codex --version
  printf "Queue capability:\n"
  codex queue --help
  printf "Host public key:\n"
  cat /etc/ssh/ssh_host_ed25519_key.pub
  printf "Bridge status:\n"
  python3 ~/.local/lib/codex-pocket/bridge.py eyJvcCI6InN0YXR1cyJ9
'\'''
