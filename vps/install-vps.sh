#!/bin/bash
# Run on the server as root, after mac/install.sh copied the bridge token to
# /etc/code-mcp/homekit.token. Adds homekit_tools.py to your FastMCP server's folder,
# registers it in server.py, sets the Mac's tailnet URL in the service's env file, and
# restarts the service. Backs up server.py and the env file first.
#
# Settings (environment, or vps/config.local.sh next to this script, which git ignores):
#   MAC_IP        the Mac's Tailscale IPv4 address (required), e.g. 100.x.y.z
#   CODE_MCP_DIR  folder holding server.py          (default /opt/code-mcp)
#   ENV_FILE      the service's EnvironmentFile     (default /etc/code-mcp.env)
#   SERVICE       systemd unit to restart           (default code-mcp)
#   PYTHON        the service's Python interpreter  (default python3)
#
# server.py must create `mcp = FastMCP(...)`, define `audit(tool, **kw)`, and end with
# `if __name__ == "__main__":` exactly once.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/config.local.sh" ] && . "$HERE/config.local.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
D="${CODE_MCP_DIR:-/opt/code-mcp}"
ENV_FILE="${ENV_FILE:-/etc/code-mcp.env}"
SERVICE="${SERVICE:-code-mcp}"
PYTHON="${PYTHON:-python3}"
if [ -z "${MAC_IP:-}" ]; then
  echo "Set MAC_IP to the Tailscale IPv4 address of the Mac (environment or vps/config.local.sh)." >&2
  exit 1
fi

[ -s /etc/code-mcp/homekit.token ] || { echo "missing /etc/code-mcp/homekit.token (run the Mac install first)"; exit 1; }
cp -a "$D/server.py" "$D/server.py.bak-$STAMP"
cp -a "$ENV_FILE" "$ENV_FILE.bak-$STAMP"
install -m 644 "$HERE/homekit_tools.py" "$D/homekit_tools.py"

if ! grep -q '^import homekit_tools' "$D/server.py"; then
  python3 - "$D/server.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
marker = 'if __name__ == "__main__":'
block = ("# ---------- HomeKit tools (homekit_tools.py; Mac over Tailscale, HomeKit Bridge app) ----------\n"
         "import homekit_tools\nhomekit_tools.register(mcp, audit)\n\n")
assert s.count(marker) == 1, "main guard not found exactly once"
open(p, "w").write(s.replace(marker, block + marker))
PY
fi
grep -q '^HOMEKIT_MCP_URL=' "$ENV_FILE" || echo "HOMEKIT_MCP_URL=http://$MAC_IP:8767/mcp" >> "$ENV_FILE"
grep -q '^HOMEKIT_MCP_TOKEN_FILE=' "$ENV_FILE" || echo "HOMEKIT_MCP_TOKEN_FILE=/etc/code-mcp/homekit.token" >> "$ENV_FILE"

"$PYTHON" -c "import sys; sys.path.insert(0,'$D'); import homekit_tools; print('module ok')"
systemctl restart "$SERVICE"
sleep 3
systemctl is-active "$SERVICE" && echo "$SERVICE restarted; backups: $D/server.py.bak-$STAMP $ENV_FILE.bak-$STAMP"
