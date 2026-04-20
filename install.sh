#!/bin/sh
# OpenWrt Monitor Bot — interactive installer
# Usage: sh install.sh
# Run from the repo root (next to bot.sh).

set -e

BOT_DST="/usr/local/bin/wrt-monitor-bot.sh"
INIT_DST="/etc/init.d/wrt-monitor-bot"
CONFIG_DST="/etc/wrt-monitor-bot.conf"
IMG_DST="/usr/local/share/wrt-monitor-unauthorized.jpg"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Colors
if [ -t 1 ]; then
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_BLUE=$(printf '\033[34m')
    C_BOLD=$(printf '\033[1m')
    C_RST=$(printf '\033[0m')
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RST=""
fi

say()   { printf "%s%s%s\n" "$C_BLUE" "==>" "$C_RST $*"; }
ok()    { printf "%s✓%s %s\n" "$C_GREEN" "$C_RST" "$*"; }
warn()  { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RST" "$*"; }
err()   { printf "%s✗%s %s\n" "$C_RED" "$C_RST" "$*" >&2; }

prompt() {
    # $1=prompt, $2=default, $3=var_name
    local p="$1" def="$2" var="$3" val=""
    if [ -n "$def" ]; then
        printf "%s%s%s [%s]: " "$C_BOLD" "$p" "$C_RST" "$def"
    else
        printf "%s%s%s: " "$C_BOLD" "$p" "$C_RST"
    fi
    read -r val
    [ -z "$val" ] && val="$def"
    eval "$var=\"\$val\""
}

prompt_required() {
    local p="$1" var="$2" val=""
    while [ -z "$val" ]; do
        printf "%s%s%s: " "$C_BOLD" "$p" "$C_RST"
        read -r val
        [ -z "$val" ] && err "This field is required"
    done
    eval "$var=\"\$val\""
}

# === Sanity checks ===
say "Checking environment..."

if [ "$(id -u)" != "0" ]; then
    err "Must run as root"
    exit 1
fi

if [ -f /etc/openwrt_release ]; then
    ok "OpenWrt detected ($(awk -F= '/DISTRIB_RELEASE/{gsub(/['"'"'"]/,"",$2); print $2}' /etc/openwrt_release 2>/dev/null || echo unknown))"
else
    warn "This doesn't look like OpenWrt (no /etc/openwrt_release)."
    warn "The script uses OpenWrt-specific tools (uci, procd, busybox stat)."
    printf "Continue anyway? [y/N]: "
    read -r yn
    case "$yn" in
        y|Y) warn "Proceeding on non-OpenWrt system — expect issues" ;;
        *) exit 1 ;;
    esac
fi

if [ ! -f "$SCRIPT_DIR/bot.sh" ]; then
    err "bot.sh not found in $SCRIPT_DIR. Run installer from repo root."
    exit 1
fi

# === Dependencies ===
say "Checking dependencies..."
MISSING=""
for cmd in curl jsonfilter wg pidof awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING="$MISSING $cmd"
    fi
done

if [ -n "$MISSING" ]; then
    warn "Missing:$MISSING"
    # Map commands to opkg packages
    PKGS=""
    for c in $MISSING; do
        case "$c" in
            curl) PKGS="$PKGS curl" ;;
            wg) PKGS="$PKGS wireguard-tools" ;;
            jsonfilter) PKGS="$PKGS jsonfilter" ;;
        esac
    done
    if [ -n "$PKGS" ]; then
        say "Installing:$PKGS"
        opkg update >/dev/null
        # shellcheck disable=SC2086
        opkg install $PKGS
    fi
    # Recheck
    for cmd in $MISSING; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Still missing: $cmd"
            exit 1
        fi
    done
fi
ok "All dependencies present"

# === Collect config ===
echo
say "Configuration"
echo "Get BOT_TOKEN from @BotFather in Telegram."
echo "Get CHAT_ID by messaging @userinfobot in Telegram."
echo

prompt_required "Telegram BOT_TOKEN" BOT_TOKEN
prompt_required "Your Telegram CHAT_ID (numeric)" CHAT_ID

echo
echo "ntfy.sh is a public push notification service (https://ntfy.sh)."
echo "Topic is public — anyone who knows it reads your alerts."
echo "Leave empty to disable ntfy alerts."
echo

DEFAULT_TOPIC=$(head -c 6 /dev/urandom 2>/dev/null | hexdump -ve '1/1 "%02x"' 2>/dev/null || date +%s%N)
prompt "NTFY_TOPIC (press Enter to generate random or 'skip' to disable)" "wrt-bot-${DEFAULT_TOPIC}" NTFY_TOPIC
[ "$NTFY_TOPIC" = "skip" ] && NTFY_TOPIC=""

echo
echo "Network interfaces. Auto-detecting..."

WAN_GUESS=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || echo "eth1")
LAN_GUESS=$(uci -q get network.lan.device 2>/dev/null || uci -q get network.lan.ifname 2>/dev/null || echo "br-lan")
WG_GUESS=$(uci show network 2>/dev/null | grep -m1 "=interface" | while read -r line; do
    name=$(echo "$line" | cut -d. -f2 | cut -d= -f1)
    proto=$(uci -q get "network.${name}.proto" 2>/dev/null)
    [ "$proto" = "wireguard" ] && echo "$name" && break
done)
[ -z "$WG_GUESS" ] && WG_GUESS="wg0"

prompt "WAN interface" "$WAN_GUESS" WAN_IFACE
prompt "LAN interface" "$LAN_GUESS" LAN_IFACE
prompt "WireGuard interface" "$WG_GUESS" WG_IFACE

# LAN subnet prefix from uci
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
LAN_PREFIX=$(echo "$LAN_IP" | awk -F. '{print $1"."$2"."$3"."}')
prompt "LAN subnet prefix (for /top filter)" "$LAN_PREFIX" LAN_SUBNET_PREFIX

echo
prompt "AdGuard Home process name (empty to skip)" "AdGuardHome" AGH_PROCESS_NAME
if [ -n "$AGH_PROCESS_NAME" ]; then
    prompt "AdGuard Home URL" "http://${LAN_IP}:3000" AGH_URL
else
    AGH_URL=""
fi

echo
prompt "VPN process name to monitor (e.g. sing-box, xray, empty to skip)" "" VPN_PROCESS_NAME
VPN_LABEL="VPN"
if [ -n "$VPN_PROCESS_NAME" ]; then
    prompt "VPN friendly label" "VPN" VPN_LABEL
fi

echo
UNAUTHORIZED_IMG=""
if [ -f "$SCRIPT_DIR/assets/unauthorized.jpg" ]; then
    prompt "Install unauthorized.jpg image? [Y/n]" "y" INSTALL_IMG
    case "$INSTALL_IMG" in
        y|Y)
            cp "$SCRIPT_DIR/assets/unauthorized.jpg" "$IMG_DST"
            UNAUTHORIZED_IMG="$IMG_DST"
            ok "Image installed to $IMG_DST"
            ;;
    esac
fi

# === Write config ===
say "Writing config to $CONFIG_DST"
cat > "$CONFIG_DST" <<EOF
# Generated by install.sh on $(date)
# Edit this file and restart: service wrt-monitor-bot restart

BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"

NTFY_TOPIC="${NTFY_TOPIC}"
NTFY_SERVER="https://ntfy.sh"

WAN_IFACE="${WAN_IFACE}"
LAN_IFACE="${LAN_IFACE}"
WG_IFACE="${WG_IFACE}"
LAN_SUBNET_PREFIX="${LAN_SUBNET_PREFIX}"

AGH_PROCESS_NAME="${AGH_PROCESS_NAME}"
AGH_URL="${AGH_URL}"

VPN_PROCESS_NAME="${VPN_PROCESS_NAME}"
VPN_LABEL="${VPN_LABEL}"

SPEEDTEST_URL_DL="http://speedtest.selectel.ru/10MB"
SPEEDTEST_URL_UL="http://speedtest.selectel.ru/"
EXT_IP_URL="http://ifconfig.me/ip"

UNAUTHORIZED_IMG="${UNAUTHORIZED_IMG}"
UNAUTHORIZED_TEXT="🚫 Access denied. This bot is private."

STATE_DIR="/tmp"
POLL_INTERVAL=2
ALERT_INTERVAL=30
ALERT_RAM_THRESHOLD=90
ALERT_TEMP_THRESHOLD=80
ALERT_THROTTLE=600
WG_HANDSHAKE_TIMEOUT=180
CACHE_TTL_EXT_IP=300
CACHE_TTL_PEER=300
EOF
chmod 600 "$CONFIG_DST"
ok "Config written ($CONFIG_DST, mode 600)"

# === Install files ===
say "Installing bot script..."
mkdir -p /usr/local/bin
cp "$SCRIPT_DIR/bot.sh" "$BOT_DST"
chmod 755 "$BOT_DST"
ok "$BOT_DST"

say "Installing init script..."
cp "$SCRIPT_DIR/wrt-monitor-bot.init" "$INIT_DST"
chmod 755 "$INIT_DST"
ok "$INIT_DST"

# === Enable and start ===
say "Enabling and starting service..."
"$INIT_DST" enable
"$INIT_DST" stop 2>/dev/null || true
sleep 1
"$INIT_DST" start
sleep 2

if pgrep -f wrt-monitor-bot.sh >/dev/null 2>&1; then
    ok "Service is running"
else
    err "Service failed to start. Check: logread | grep wrt-monitor-bot"
    exit 1
fi

echo
echo "${C_GREEN}${C_BOLD}Installation complete!${C_RST}"
echo
echo "Next steps:"
echo "  1. Open Telegram and message your bot. Send /help."
if [ -n "$NTFY_TOPIC" ]; then
    echo "  2. Install ntfy app (https://ntfy.sh), subscribe to topic:"
    echo "     ${C_BOLD}${NTFY_TOPIC}${C_RST}"
    echo "     Or open in browser: https://ntfy.sh/${NTFY_TOPIC}"
fi
echo
echo "Useful commands:"
echo "  service wrt-monitor-bot restart    # restart after config change"
echo "  service wrt-monitor-bot stop       # stop"
echo "  logread | grep wrt-monitor         # view logs"
echo "  vi $CONFIG_DST                     # edit config"
