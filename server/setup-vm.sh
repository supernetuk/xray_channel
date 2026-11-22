#!/usr/bin/env bash
# setup-vm.sh: set up (or update) an Xray server VM in one go.
#
#   1. Linux ops MCP     (optional, --mcp-host): lets Claude check the VM read-only through a connector
#   2. Cloudflare Tunnel (with --mcp-host): asks for the tunnel token, so the MCP is reachable with no open port
#   3. Xray server       VLESS + REALITY + Vision on TCP 443, first user, prints the client command
#
# Run as root on a fresh AlmaLinux / Rocky / RHEL 9-10 VM with a public IPv4 (Debian/Ubuntu: Xray part only):
#   curl -fsSL https://raw.githubusercontent.com/supernetuk/xray_channel/main/server/setup-vm.sh -o /root/setup-vm.sh \
#     && bash /root/setup-vm.sh --mcp-host ops-xray.example.com --sni www.example.ac.uk --user alice
#
# Running it again updates each part instead of reinstalling. The tunnel token is typed at a hidden prompt
# (or read from --tunnel-token-file); it is never put on the command line or in the shell history.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

REF="${XC_REF:-main}"
XC_RAW="${XC_REPO_RAW:-https://raw.githubusercontent.com/supernetuk/xray_channel/$REF}"
MCP_REPO="${XC_MCP_REPO:-https://github.com/supernetuk/Linux-MCP.git}"
MCP_DIR=/opt/Linux-MCP
XC_BIN=/usr/local/bin/xray-channel-server

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()    { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

MCP_HOST=""; SNI=""; HOST=""; USER_NAME="user1"; TOKEN_FILE=""; SKIP_MCP=no; SKIP_XRAY=no
while [ $# -gt 0 ]; do case "$1" in
  --mcp-host) MCP_HOST="$2"; shift 2 ;;
  --sni) SNI="$2"; shift 2 ;;
  --host) HOST="$2"; shift 2 ;;
  --user) USER_NAME="$2"; shift 2 ;;
  --tunnel-token-file) TOKEN_FILE="$2"; shift 2 ;;
  --no-mcp) SKIP_MCP=yes; shift ;;
  --no-xray) SKIP_XRAY=yes; shift ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  *) die "unknown option $1 (see --help)" ;;
esac; done

[ "$(id -u)" = 0 ] || die "run as root (sudo -i first)"
[ -n "$MCP_HOST" ] || SKIP_MCP=yes
if [ -n "$MCP_HOST" ]; then
  [[ "$MCP_HOST" =~ ^([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$ ]] || die "bad --mcp-host (e.g. ops-xray.example.com)"
fi
[[ "$USER_NAME" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || die "bad --user"
command -v curl >/dev/null || die "curl is required"

# ---------------------------------------------------------------------------------------------
# 1. Linux ops MCP
# ---------------------------------------------------------------------------------------------
if [ "$SKIP_MCP" = no ]; then
  c_step "1/3 Linux ops MCP ($MCP_HOST)"
  command -v dnf >/dev/null || die "the MCP part needs a dnf-based OS (AlmaLinux/Rocky/RHEL). Use --no-mcp on others."
  command -v git >/dev/null || dnf install -y -q git
  if [ -d "$MCP_DIR/.git" ]; then git -C "$MCP_DIR" pull -q --ff-only || c_warn "could not update $MCP_DIR (local changes?)"
  else git clone -q "$MCP_REPO" "$MCP_DIR"; fi
  bash "$MCP_DIR/install.sh" "$MCP_HOST" | tail -n 4
  systemctl is-active -q claude-ops-mcp || die "claude-ops-mcp is not running: journalctl -u claude-ops-mcp -n 30"
  c_ok "MCP running on 127.0.0.1:8765"

  # -------------------------------------------------------------------------------------------
  # 2. Cloudflare Tunnel
  # -------------------------------------------------------------------------------------------
  c_step "2/3 Cloudflare Tunnel"
  if ! command -v cloudflared >/dev/null; then
    curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo -o /etc/yum.repos.d/cloudflared.repo
    dnf install -y -q cloudflared
  fi
  if systemctl is-active -q cloudflared; then
    c_ok "cloudflared already connected (to change the token: cloudflared service uninstall, then run this again)"
  else
    if [ -n "$TOKEN_FILE" ]; then
      token=$(tr -d '[:space:]' < "$TOKEN_FILE")
    else
      echo "In Cloudflare: Networking > Tunnels > your tunnel > install command (Red Hat)."
      echo "Copy the token (the long eyJ... part) or the whole 'cloudflared service install ...' line, paste it here, press Enter."
      echo "Input is hidden."
      read -rsp "Tunnel token: " token </dev/tty; echo
    fi
    token="${token##* }"                 # accept the whole install command: keep the last word
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    [[ "$token" =~ ^eyJ[A-Za-z0-9_=-]{40,}$ ]] || die "that doesn't look like a tunnel token (it starts with eyJ). Nothing changed."
    cloudflared service install "$token" >/dev/null 2>&1 || die "cloudflared service install failed: is the token complete?"
    unset token
    sleep 3
    systemctl is-active -q cloudflared || die "cloudflared did not start: journalctl -u cloudflared -n 30"
    c_ok "Tunnel connected"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 3. Xray server
# ---------------------------------------------------------------------------------------------
if [ "$SKIP_XRAY" = no ]; then
  c_step "3/3 Xray server (VLESS + REALITY + Vision)"
  curl -fsSL "$XC_RAW/server/xray-channel-server" -o "$XC_BIN.new"
  bash -n "$XC_BIN.new" || die "downloaded xray-channel-server is broken"
  install -m 755 "$XC_BIN.new" "$XC_BIN"; rm -f "$XC_BIN.new"
  if [ -f /etc/xray-channel/server.env ]; then
    "$XC_BIN" update
    if [ -n "$SNI" ]; then "$XC_BIN" sni "$SNI"; fi
    c_ok "Xray server updated. Users: $XC_BIN list   Client command: $XC_BIN client-cmd <name>"
  else
    args=(install --user "$USER_NAME")
    if [ -n "$SNI" ]; then args+=(--sni "$SNI"); fi
    if [ -n "$HOST" ]; then args+=(--host "$HOST"); fi
    "$XC_BIN" "${args[@]}"
  fi
fi

# ---------------------------------------------------------------------------------------------
c_step "Done"
if [ "$SKIP_MCP" = no ]; then
  cat <<EOF
Claude connector (only once, if you haven't added it yet):
  1. Cloudflare: Networking > Tunnels > this tunnel > Routes > Add route > Published application:
       $MCP_HOST  ->  http://127.0.0.1:8765
  2. Show the MCP token here:   grep ^OPS_MCP_TOKEN= /etc/claude-ops/config.env
  3. Claude: Settings > Connectors > Add custom connector, URL:  https://$MCP_HOST/<token>/mcp
EOF
fi
if [ "$SKIP_XRAY" = no ]; then
  echo "Xray: keep the vless:// link above private: anyone with it can use this server."
fi
