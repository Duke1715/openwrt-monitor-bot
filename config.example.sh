# OpenWrt Monitor Bot — configuration
# Copy to /etc/wrt-monitor-bot.conf and edit.
# File is sourced as POSIX shell — use KEY="value" syntax.

# ============================================================
# REQUIRED
# ============================================================

# Telegram bot token from @BotFather
BOT_TOKEN=""

# Your Telegram chat ID (numeric). Get it from @userinfobot.
# Only this chat_id can query the bot; others get UNAUTHORIZED_TEXT/IMG.
CHAT_ID=""

# ============================================================
# NTFY.SH PUSH ALERTS (optional)
# ============================================================

# Topic name on ntfy.sh. Subscribe to it in the ntfy mobile app.
# WARNING: topic is public — anyone who knows it reads your alerts.
# Use a long random string: e.g. "myrouter-a7k3m9xq2w".
# Leave empty to disable ntfy alerts entirely.
NTFY_TOPIC=""

# ntfy server (change if you self-host).
NTFY_SERVER="https://ntfy.sh"

# ============================================================
# NETWORK INTERFACES (match your OpenWrt config)
# ============================================================

# WAN interface (where internet comes in). Find via: ip link
WAN_IFACE="eth1"

# LAN bridge. Usually br-lan.
LAN_IFACE="br-lan"

# WireGuard interface. Leave default if you don't use WG.
WG_IFACE="wg0"

# Prefix of your LAN subnet — used by /top to filter conntrack.
# For 192.168.1.0/24 use "192.168.1."
# For 10.0.0.0/24 use "10.0.0."
LAN_SUBNET_PREFIX="192.168.1."

# ============================================================
# SERVICES MONITORING (optional)
# ============================================================

# AdGuard Home process name (for /dns command). Empty to disable.
AGH_PROCESS_NAME="AdGuardHome"

# AdGuard Home web UI URL (appended to /dns command output).
AGH_URL="http://192.168.1.1:3000"

# VPN process name for alerts (e.g. sing-box, xray, openvpn).
# Empty to disable VPN monitoring and /vpn command.
VPN_PROCESS_NAME=""

# Friendly VPN label shown in messages.
VPN_LABEL="VPN"

# ============================================================
# SPEEDTEST (optional — customize if default is slow)
# ============================================================

# URL for download test (10MB file recommended).
SPEEDTEST_URL_DL="http://speedtest.selectel.ru/10MB"

# URL that accepts POST for upload test.
SPEEDTEST_URL_UL="http://speedtest.selectel.ru/"

# External IP lookup service.
EXT_IP_URL="http://ifconfig.me/ip"

# ============================================================
# UNAUTHORIZED ACCESS RESPONSE (optional)
# ============================================================

# Path to image shown to strangers who try to use the bot.
# Leave empty to use UNAUTHORIZED_TEXT instead.
UNAUTHORIZED_IMG=""

# Fallback text if UNAUTHORIZED_IMG is not set or missing.
UNAUTHORIZED_TEXT="🚫 Access denied. This bot is private."

# ============================================================
# ADVANCED (you probably don't need to change these)
# ============================================================

# Where to keep runtime state (offset, logs, caches).
# /tmp is fine — resets on reboot.
STATE_DIR="/tmp"

# Main loop sleep between Telegram polls (seconds).
POLL_INTERVAL=2

# How often to run alert checks (seconds).
ALERT_INTERVAL=30

# RAM usage % that triggers an alert.
ALERT_RAM_THRESHOLD=90

# CPU temperature (°C) that triggers an alert.
ALERT_TEMP_THRESHOLD=80

# Same alert won't fire more often than this (seconds).
ALERT_THROTTLE=600

# WG peer is considered online if last handshake was within this many seconds.
WG_HANDSHAKE_TIMEOUT=180

# Cache TTL for external IP lookup (seconds).
CACHE_TTL_EXT_IP=300

# Cache TTL for UCI peer names (seconds).
CACHE_TTL_PEER=300
