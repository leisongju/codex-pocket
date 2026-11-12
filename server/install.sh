#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
command -v python3 >/dev/null
command -v codex >/dev/null || { echo 'Run as the same user that runs Codex, with codex in PATH.' >&2; exit 1; }
command -v tmux >/dev/null || echo 'Optional terminal helper requires: sudo apt install tmux' >&2
install -d -m 700 "$HOME/.local/lib/codex-pocket" "$HOME/.local/bin"
install -m 700 runtime.py presentation.py "$HOME/.local/lib/codex-pocket/"
install -m 700 bridge.py "$HOME/.local/lib/codex-pocket/bridge.py"
install -m 700 codex-pocket "$HOME/.local/bin/codex-pocket"
echo 'Installed. Start a session: ~/.local/bin/codex-pocket'
echo 'Resume a session: ~/.local/bin/codex-pocket resume SESSION_UUID'
echo 'Host public key (paste the complete line into the iPhone app):'
cat /etc/ssh/ssh_host_ed25519_key.pub
