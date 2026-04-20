#!/bin/sh
# OpenWrt Monitor Bot — Telegram bot + ntfy.sh push alerts for OpenWrt routers
# https://github.com/Duke1715/openwrt-monitor-bot

set -u

# === Load config ===
CONFIG_FILE="${WRT_BOT_CONFIG:-/etc/wrt-monitor-bot.conf}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config not found: $CONFIG_FILE" >&2
    echo "Set WRT_BOT_CONFIG env var or create /etc/wrt-monitor-bot.conf" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_FILE"

# Required
: "${BOT_TOKEN:?BOT_TOKEN required in config}"
: "${CHAT_ID:?CHAT_ID required in config}"

# Optional with defaults
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
WAN_IFACE="${WAN_IFACE:-eth1}"
LAN_IFACE="${LAN_IFACE:-br-lan}"
WG_IFACE="${WG_IFACE:-wg0}"
LAN_SUBNET_PREFIX="${LAN_SUBNET_PREFIX:-192.168.1.}"
AGH_URL="${AGH_URL:-}"
AGH_PROCESS_NAME="${AGH_PROCESS_NAME:-AdGuardHome}"
VPN_PROCESS_NAME="${VPN_PROCESS_NAME:-}"
VPN_LABEL="${VPN_LABEL:-VPN}"
SPEEDTEST_URL_DL="${SPEEDTEST_URL_DL:-http://speedtest.selectel.ru/10MB}"
SPEEDTEST_URL_UL="${SPEEDTEST_URL_UL:-http://speedtest.selectel.ru/}"
EXT_IP_URL="${EXT_IP_URL:-http://ifconfig.me/ip}"
UNAUTHORIZED_IMG="${UNAUTHORIZED_IMG:-}"
UNAUTHORIZED_TEXT="${UNAUTHORIZED_TEXT:-🚫 Access denied. This bot is private.}"
STATE_DIR="${STATE_DIR:-/tmp}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
ALERT_INTERVAL="${ALERT_INTERVAL:-30}"
ALERT_RAM_THRESHOLD="${ALERT_RAM_THRESHOLD:-90}"
ALERT_TEMP_THRESHOLD="${ALERT_TEMP_THRESHOLD:-80}"
WG_HANDSHAKE_TIMEOUT="${WG_HANDSHAKE_TIMEOUT:-180}"
CACHE_TTL_EXT_IP="${CACHE_TTL_EXT_IP:-300}"
CACHE_TTL_PEER="${CACHE_TTL_PEER:-300}"
ALERT_THROTTLE="${ALERT_THROTTLE:-600}"

# Derived
API="https://api.telegram.org/bot${BOT_TOKEN}"
NTFY_URL=""
[ -n "$NTFY_TOPIC" ] && NTFY_URL="${NTFY_SERVER}/${NTFY_TOPIC}"

# State files
OFFSET_FILE="${STATE_DIR}/wrt_bot_offset"
INTRUDERS_LOG="${STATE_DIR}/wrt_bot_intruders.log"
WG_SNAPSHOT="${STATE_DIR}/wrt_bot_wg_snapshot"
EXT_IP_CACHE="${STATE_DIR}/wrt_bot_ext_ip"
WG_PEERS_PREV="${STATE_DIR}/wrt_bot_wg_peers_prev"
WG_PEERS_NOW="${STATE_DIR}/wrt_bot_wg_peers_now"
TG_RESPONSE_FILE="${STATE_DIR}/wrt_bot_tg_response.json"
ALERT_FLAG_RAM="${STATE_DIR}/wrt_bot_alert_ram"
ALERT_FLAG_TEMP="${STATE_DIR}/wrt_bot_alert_temp"
ALERT_FLAG_VPN="${STATE_DIR}/wrt_bot_alert_vpn"
REBOOT_CANCEL_FILE="${STATE_DIR}/wrt_bot_reboot_cancel"
REBOOT_TIMER_PID_FILE="${STATE_DIR}/wrt_bot_reboot_timer.pid"

# Runtime
PEER_CACHE=""
PEER_CACHE_TIME=0
REBOOT_PENDING=""
LAST_ALERT_CHECK=0

mkdir -p "$STATE_DIR" 2>/dev/null

# === HELPERS ===

# Escape value for curl --config double-quoted string.
_conf_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Call Telegram API via curl --config on stdin.
# Keeps BOT_TOKEN out of curl's argv (not visible in `ps`).
# Usage: _tg_post <endpoint> <config_line>...
_tg_post() {
    local endpoint="$1"
    shift
    {
        printf 'silent\n'
        printf 'request = "POST"\n'
        printf 'url = "%s/%s"\n' "$API" "$endpoint"
        printf 'max-time = 15\n'
        for line in "$@"; do
            printf '%s\n' "$line"
        done
    } | curl -K - > /dev/null 2>&1
}

# GET variant — returns response body on stdout.
# Usage: _tg_get <endpoint> [query_string]
_tg_get() {
    local endpoint="$1" query="${2:-}"
    local suffix=""
    [ -n "$query" ] && suffix="?${query}"
    {
        printf 'silent\n'
        printf 'max-time = 15\n'
        printf 'url = "%s/%s%s"\n' "$API" "$endpoint" "$suffix"
    } | curl -K -
}

send_msg() {
    _tg_post sendMessage \
        "data-urlencode = \"chat_id=$(_conf_escape "$CHAT_ID")\"" \
        "data-urlencode = \"text=$(_conf_escape "$1")\"" \
        'data-urlencode = "parse_mode=HTML"'
}

# Send image to arbitrary chat_id (used for unauthorized user response).
_send_photo_to() {
    local cid="$1" img="$2"
    _tg_post sendPhoto \
        "form = \"chat_id=$(_conf_escape "$cid")\"" \
        "form = \"photo=@$(_conf_escape "$img")\""
}

# Send plain text to arbitrary chat_id.
_send_text_to() {
    local cid="$1" text="$2"
    _tg_post sendMessage \
        "data-urlencode = \"chat_id=$(_conf_escape "$cid")\"" \
        "data-urlencode = \"text=$(_conf_escape "$text")\""
}

# ntfy push notification
# Args: title, message, priority (min|low|default|high|urgent), tags
send_ntfy() {
    [ -z "$NTFY_URL" ] && return 0
    curl -s -X POST "$NTFY_URL" \
        -H "Title: $1" \
        -H "Priority: ${3:-default}" \
        -H "Tags: ${4:-}" \
        -d "$2" > /dev/null 2>&1
}

human_bytes() {
    local bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        awk "BEGIN{printf \"%.1f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        awk "BEGIN{printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

time_ago() {
    local ts="$1"
    local now
    now=$(date +%s)
    if [ "$ts" = "0" ] || [ -z "$ts" ]; then
        echo "never"
        return
    fi
    local diff=$((now - ts))
    if [ "$diff" -lt 60 ]; then
        echo "${diff}s ago"
    elif [ "$diff" -lt 3600 ]; then
        echo "$((diff / 60))m ago"
    elif [ "$diff" -lt 86400 ]; then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

uptime_str() {
    awk '{d=int($1/86400); h=int($1%86400/3600); m=int($1%3600/60); if(d>0) printf "%dd %dh %dm", d, h, m; else if(h>0) printf "%dh %dm", h, m; else printf "%dm", m}' /proc/uptime
}

# Cache peer names from UCI (refresh every CACHE_TTL_PEER sec)
refresh_peer_cache() {
    local now
    now=$(date +%s)
    if [ $((now - PEER_CACHE_TIME)) -gt "$CACHE_TTL_PEER" ] || [ -z "$PEER_CACHE" ]; then
        PEER_CACHE=$(uci show network 2>/dev/null | grep -E 'public_key|description|allowed_ips' | tr '\n' ';')
        PEER_CACHE_TIME=$now
    fi
}

get_peer_name() {
    local pubkey="$1"
    refresh_peer_cache
    local section
    section=$(echo "$PEER_CACHE" | tr ';' '\n' | grep "public_key='${pubkey}'" | head -1 | cut -d. -f2)
    if [ -n "$section" ]; then
        local desc
        desc=$(echo "$PEER_CACHE" | tr ';' '\n' | grep "${section}.description=" | head -1 | sed "s/.*='//;s/'$//")
        if [ -n "$desc" ]; then
            echo "$desc"
            return
        fi
        echo "$section"
        return
    fi
    echo "Unknown"
}

# === COMMANDS ===
cmd_ping() {
    send_msg "🏓 pong"
}

cmd_status() {
    local up mem_total mem_avail mem_used mem_pct mem_used_mb mem_total_mb
    local disk temp conns load ext_ip

    up=$(uptime_str)
    load=$(awk '{print $1, $2, $3}' /proc/loadavg)
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    mem_used=$((mem_total - mem_avail))
    mem_pct=$((mem_used * 100 / mem_total))
    mem_used_mb=$((mem_used / 1024))
    mem_total_mb=$((mem_total / 1024))
    disk=$(df -h /overlay 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')
    [ -z "$disk" ] && disk=$(df -h / | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')
    conns=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo "0")

    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        temp="$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
    else
        temp="N/A"
    fi

    # External IP (cached)
    if [ ! -f "$EXT_IP_CACHE" ] || [ $(($(date +%s) - $(stat -c %Y "$EXT_IP_CACHE" 2>/dev/null || echo 0))) -gt "$CACHE_TTL_EXT_IP" ]; then
        ext_ip=$(curl -s --max-time 5 "$EXT_IP_URL" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        [ -n "$ext_ip" ] && echo "$ext_ip" > "$EXT_IP_CACHE"
    fi
    ext_ip=$(cat "$EXT_IP_CACHE" 2>/dev/null || echo "N/A")

    send_msg "<b>📊 Router Status</b>

⏱ Uptime: <b>${up}</b>
💻 Load: <b>${load}</b>
🌡 Temp: <b>${temp}</b>
🧠 RAM: <b>${mem_used_mb}/${mem_total_mb} MB (${mem_pct}%)</b>
💾 Disk: <b>${disk}</b>
🔗 Connections: <b>${conns}</b>
🌍 External IP: <b>${ext_ip}</b>"
}

cmd_wg() {
    local now final_msg total_rx total_tx online total
    now=$(date +%s)
    total_rx=0
    total_tx=0
    online=0
    total=0

    final_msg="<b>🔐 WireGuard Clients</b>"

    wg show "$WG_IFACE" dump 2>/dev/null | awk -F'\t' 'NR>1{print $1 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7}' > "${STATE_DIR}/wrt_bot_wg_dump"

    while IFS='|' read -r pubkey endpoint allowed_ips handshake rx tx; do
        total=$((total + 1))
        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        local name ip status hs_text rx_h tx_h
        name=$(get_peer_name "$pubkey")
        ip=$(echo "$allowed_ips" | sed 's|/32||')

        if [ "$handshake" != "0" ] && [ -n "$handshake" ] && [ $((now - handshake)) -lt "$WG_HANDSHAKE_TIMEOUT" ]; then
            status="🟢"
            online=$((online + 1))
        else
            status="⚪"
        fi

        hs_text=$(time_ago "$handshake")
        rx_h=$(human_bytes "$rx")
        tx_h=$(human_bytes "$tx")

        final_msg="${final_msg}

${status} <b>${name}</b> (${ip})
    ↓ ${rx_h}  ↑ ${tx_h}
    🕐 ${hs_text}"
    done < "${STATE_DIR}/wrt_bot_wg_dump"
    rm -f "${STATE_DIR}/wrt_bot_wg_dump"

    local total_rx_h total_tx_h
    total_rx_h=$(human_bytes "$total_rx")
    total_tx_h=$(human_bytes "$total_tx")

    final_msg="${final_msg}

━━━━━━━━━━━━━━━━━━
📊 Online: <b>${online}/${total}</b>
📥 Total ↓ ${total_rx_h}  📤 ↑ ${total_tx_h}"

    send_msg "$final_msg"
}

cmd_traffic() {
    local msg iface rx tx rx_h tx_h label
    msg="<b>📈 Interface Traffic</b>"

    for iface in "$WAN_IFACE" "$LAN_IFACE" "$WG_IFACE"; do
        rx=$(awk -v i="${iface}:" '$1==i{print $2}' /proc/net/dev)
        tx=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev)
        if [ -n "$rx" ]; then
            rx_h=$(human_bytes "$rx")
            tx_h=$(human_bytes "$tx")
            if [ "$iface" = "$WAN_IFACE" ]; then
                label="🌍 WAN"
            elif [ "$iface" = "$LAN_IFACE" ]; then
                label="🏠 LAN"
            elif [ "$iface" = "$WG_IFACE" ]; then
                label="🔐 WG"
            else
                label="${iface}"
            fi
            msg="${msg}

${label} (${iface}):
    ↓ ${rx_h}  ↑ ${tx_h}"
        fi
    done

    msg="${msg}

<i>* since boot ($(uptime_str))</i>"
    send_msg "$msg"
}

cmd_dns() {
    local agh_status
    if pgrep -f "$AGH_PROCESS_NAME" > /dev/null 2>&1; then
        agh_status="✅ Running"
    else
        agh_status="❌ Stopped"
    fi

    local extra=""
    [ -n "$AGH_URL" ] && extra="

<i>Dashboard: ${AGH_URL}</i>"

    send_msg "<b>🛡 ${AGH_PROCESS_NAME}</b>

Status: ${agh_status}${extra}"
}

cmd_clients() {
    local msg="<b>👥 LAN Devices</b>
"
    local count=0

    awk -v lan_iface="$LAN_IFACE" '
    BEGIN { FS=" " }
    FILENAME == "/tmp/dhcp.leases" {
        ip=$3; mac=$2; name=$4
        if(name == "*") name=""
        dhcp_name[ip]=name; dhcp_mac[ip]=mac
    }
    FILENAME == "/proc/net/arp" && $4 != "00:00:00:00:00:00" && $1 != "IP" && $6 == lan_iface {
        ip=$1; mac=$4; flags=$3
        if(flags == "0x2") {
            name=dhcp_name[ip]
            if(name == "") name="-"
            printf "%s|%s|%s\n", ip, mac, name
        }
    }
    ' /tmp/dhcp.leases /proc/net/arp 2>/dev/null | sort -t. -k4 -n > "${STATE_DIR}/wrt_bot_clients"

    while IFS='|' read -r ip mac name; do
        count=$((count + 1))
        msg="${msg}
📱 <b>${name}</b>
    ${ip} (${mac})"
    done < "${STATE_DIR}/wrt_bot_clients"
    rm -f "${STATE_DIR}/wrt_bot_clients"

    msg="${msg}

━━━━━━━━━━━━━━━━━━
Total: <b>${count}</b>"

    send_msg "$msg"
}

cmd_vpn() {
    if [ -z "$VPN_PROCESS_NAME" ]; then
        send_msg "ℹ️ VPN monitoring not configured (VPN_PROCESS_NAME is empty)"
        return
    fi

    local sb_status sb_pid sb_mem sb_up
    local sb_pid_found
    sb_pid_found=$(pidof "$VPN_PROCESS_NAME" 2>/dev/null | awk '{print $1}')
    if [ -n "$sb_pid_found" ]; then
        sb_status="✅ Running"
        sb_pid="$sb_pid_found"
        sb_mem=$(awk '/VmRSS/{printf "%.0f MB", $2/1024}' /proc/${sb_pid}/status 2>/dev/null || echo "N/A")

        local sb_start
        sb_start=$(stat -c %Y /proc/${sb_pid} 2>/dev/null)
        sb_up="N/A"
        if [ -n "$sb_start" ]; then
            local sb_diff=$(( $(date +%s) - sb_start ))
            sb_up=$(awk -v s="$sb_diff" 'BEGIN{d=int(s/86400);h=int(s%86400/3600);m=int(s%3600/60); if(d>0) printf "%dd %dh %dm",d,h,m; else if(h>0) printf "%dh %dm",h,m; else printf "%dm",m}')
        fi
    else
        sb_status="❌ Stopped"
        sb_mem="N/A"
        sb_up="N/A"
    fi

    send_msg "<b>🔒 ${VPN_LABEL}</b>

Process: <b>${VPN_PROCESS_NAME}</b>
Status: ${sb_status}
Uptime: <b>${sb_up}</b>
RAM: <b>${sb_mem}</b>"
}

cmd_speedtest() {
    send_msg "⏳ Running speedtest..."

    local dl_result dl_speed
    dl_result=$(curl -s -w '%{speed_download}' -o /dev/null --max-time 15 \
        "$SPEEDTEST_URL_DL" 2>/dev/null)
    if [ -n "$dl_result" ]; then
        dl_speed=$(awk "BEGIN{printf \"%.1f\", ${dl_result}/1048576}")
    else
        dl_speed="N/A"
    fi

    local ul_result ul_speed
    ul_result=$(dd if=/dev/zero bs=1024 count=1024 2>/dev/null | \
        curl -s -w '%{speed_upload}' -X POST -d @- --max-time 15 \
        "$SPEEDTEST_URL_UL" -o /dev/null 2>/dev/null)
    if [ -n "$ul_result" ]; then
        ul_speed=$(awk "BEGIN{printf \"%.1f\", ${ul_result}/1048576}")
    else
        ul_speed="N/A"
    fi

    send_msg "<b>🚀 Speedtest</b>

↓ Download: <b>${dl_speed} MB/s</b>
↑ Upload: <b>${ul_speed} MB/s</b>

<i>* from router</i>"
}

cmd_top() {
    local msg="<b>🏆 Top Clients by Connections</b>
"
    awk -v prefix="$LAN_SUBNET_PREFIX" -F'[ =]' '{
        for(i=1;i<=NF;i++) {
            if($i=="src" && index($(i+1), prefix)==1) {
                ip=$(i+1); count[ip]++; break
            }
        }
    } END {
        for(ip in count) print count[ip]"|"ip
    }' /proc/net/nf_conntrack | sort -t'|' -k1 -rn | head -10 > "${STATE_DIR}/wrt_bot_top"

    local rank=0
    while IFS='|' read -r cnt ip; do
        rank=$((rank + 1))
        local name
        name=$(awk -v ip="$ip" '$3==ip{print $4}' /tmp/dhcp.leases | head -1)
        [ "$name" = "*" ] || [ -z "$name" ] && name="$ip"
        local medal=""
        case "$rank" in
            1) medal="🥇" ;; 2) medal="🥈" ;; 3) medal="🥉" ;; *) medal="  ${rank}." ;;
        esac
        msg="${msg}
${medal} <b>${name}</b>
    ${ip} — ${cnt} conn"
    done < "${STATE_DIR}/wrt_bot_top"
    rm -f "${STATE_DIR}/wrt_bot_top"

    local total_conns
    total_conns=$(wc -l < /proc/net/nf_conntrack 2>/dev/null)
    msg="${msg}

━━━━━━━━━━━━━━━━━━
Total connections: <b>${total_conns}</b>"

    send_msg "$msg"
}

cmd_reboot() {
    if [ "$REBOOT_PENDING" = "yes" ]; then
        # Kill any pending auto-cancel timer — we're rebooting now
        if [ -f "$REBOOT_TIMER_PID_FILE" ]; then
            kill "$(cat "$REBOOT_TIMER_PID_FILE")" 2>/dev/null
            rm -f "$REBOOT_TIMER_PID_FILE"
        fi
        send_msg "♻️ <b>Rebooting...</b>"
        sleep 1
        reboot
    else
        # Kill any previous pending timer before starting a new one,
        # so repeated /reboot calls don't accumulate background sleeps.
        if [ -f "$REBOOT_TIMER_PID_FILE" ]; then
            kill "$(cat "$REBOOT_TIMER_PID_FILE")" 2>/dev/null
            rm -f "$REBOOT_TIMER_PID_FILE"
        fi
        REBOOT_PENDING="yes"
        send_msg "⚠️ <b>Reboot router?</b>

Send /reboot again to confirm.
Auto-cancel in 30 seconds."
        ( sleep 30 && touch "$REBOOT_CANCEL_FILE" ) &
        echo $! > "$REBOOT_TIMER_PID_FILE"
    fi
}

cmd_intruders() {
    if [ ! -f "$INTRUDERS_LOG" ] || [ ! -s "$INTRUDERS_LOG" ]; then
        send_msg "😇 No unauthorized attempts yet"
        return
    fi

    local total
    total=$(wc -l < "$INTRUDERS_LOG")
    local final_msg="<b>🐷 Unauthorized attempts (${total} total)</b>"

    awk -F'|' '{key=$2"|"$3"|"$4; count[key]++; last[key]=$1} END {for(k in count) print count[k]"|"k"|"last[k]}' \
        "$INTRUDERS_LOG" | sort -t'|' -k1 -rn | head -20 > "${STATE_DIR}/wrt_bot_intruders_tmp"

    while IFS='|' read -r cnt uid uname fname last_time; do
        local ulink=""
        if [ "$uname" != "no_username" ] && [ -n "$uname" ]; then
            ulink="@${uname}"
        else
            ulink="${fname}"
        fi
        final_msg="${final_msg}

🔸 <b>${ulink}</b> (id: ${uid})
    Attempts: ${cnt} | Last: ${last_time}"
    done < "${STATE_DIR}/wrt_bot_intruders_tmp"

    rm -f "${STATE_DIR}/wrt_bot_intruders_tmp"
    send_msg "$final_msg"
}

cmd_help() {
    local vpn_line=""
    [ -n "$VPN_PROCESS_NAME" ] && vpn_line="
/vpn — VPN status"

    send_msg "<b>🤖 OpenWrt Monitor</b>

<b>System:</b>
/status — CPU, RAM, disk, IP
/speedtest — internet speed
/reboot — reboot router (confirm)

<b>Network:</b>
/wg — WireGuard clients & traffic
/clients — LAN devices
/traffic — interface traffic
/top — top clients by connections

<b>Services:</b>${vpn_line}
/dns — DNS resolver status

<b>Security:</b>
/intruders — unauthorized access log

/help — this help"
}

# === ALERTS ===
check_alerts() {
    local now
    now=$(date +%s)
    [ $((now - LAST_ALERT_CHECK)) -lt "$ALERT_INTERVAL" ] && return
    LAST_ALERT_CHECK=$now

    # RAM alert
    local mem_total mem_avail mem_pct
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    if [ "$mem_pct" -gt "$ALERT_RAM_THRESHOLD" ]; then
        if [ ! -f "$ALERT_FLAG_RAM" ] || [ $(( now - $(stat -c %Y "$ALERT_FLAG_RAM" 2>/dev/null || echo 0) )) -gt "$ALERT_THROTTLE" ]; then
            send_ntfy "RAM Alert" "Memory usage: ${mem_pct}%" "high" "warning,computer"
            touch "$ALERT_FLAG_RAM"
        fi
    fi

    # Temperature alert
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local temp_c=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
        if [ "$temp_c" -gt "$ALERT_TEMP_THRESHOLD" ]; then
            if [ ! -f "$ALERT_FLAG_TEMP" ] || [ $(( now - $(stat -c %Y "$ALERT_FLAG_TEMP" 2>/dev/null || echo 0) )) -gt "$ALERT_THROTTLE" ]; then
                send_ntfy "Temperature Alert" "CPU: ${temp_c}°C — router is hot!" "urgent" "fire,thermometer"
                touch "$ALERT_FLAG_TEMP"
            fi
        fi
    fi

    # VPN down/up alert
    if [ -n "$VPN_PROCESS_NAME" ]; then
        if [ -z "$(pidof "$VPN_PROCESS_NAME" 2>/dev/null)" ]; then
            if [ ! -f "$ALERT_FLAG_VPN" ]; then
                send_ntfy "${VPN_LABEL} down" "${VPN_PROCESS_NAME} is not running!" "urgent" "rotating_light,lock"
                touch "$ALERT_FLAG_VPN"
            fi
        else
            if [ -f "$ALERT_FLAG_VPN" ]; then
                send_ntfy "${VPN_LABEL} recovered" "${VPN_PROCESS_NAME} is running again" "default" "white_check_mark,lock"
                rm -f "$ALERT_FLAG_VPN"
            fi
        fi
    fi

    # WG peer connect/disconnect
    wg show "$WG_IFACE" dump 2>/dev/null | awk -F'\t' 'NR>1{print $1"|"$5}' > "$WG_PEERS_NOW"
    if [ -f "$WG_PEERS_PREV" ] && [ -s "$WG_PEERS_NOW" ]; then
        while IFS='|' read -r pubkey hs; do
            local prev_hs name
            prev_hs=$(grep "^${pubkey}|" "$WG_PEERS_PREV" | cut -d'|' -f2)
            name=$(get_peer_name "$pubkey")

            # Connected
            if [ "$hs" != "0" ] && [ -n "$hs" ] && [ $((now - hs)) -lt "$WG_HANDSHAKE_TIMEOUT" ]; then
                if [ -z "$prev_hs" ] || [ "$prev_hs" = "0" ] || [ $((now - prev_hs)) -ge "$WG_HANDSHAKE_TIMEOUT" ]; then
                    send_ntfy "WG: connected" "${name}" "low" "green_circle,iphone"
                fi
            fi

            # Disconnected
            if [ "$hs" = "0" ] || [ -z "$hs" ] || [ $((now - hs)) -ge "$WG_HANDSHAKE_TIMEOUT" ]; then
                if [ -n "$prev_hs" ] && [ "$prev_hs" != "0" ] && [ $((now - prev_hs)) -lt "$WG_HANDSHAKE_TIMEOUT" ]; then
                    send_ntfy "WG: disconnected" "${name}" "min" "white_circle,iphone"
                fi
            fi
        done < "$WG_PEERS_NOW"
    fi
    [ -s "$WG_PEERS_NOW" ] && cp "$WG_PEERS_NOW" "$WG_PEERS_PREV"

    # Reset reboot confirmation (fired by the 30s auto-cancel timer)
    if [ -f "$REBOOT_CANCEL_FILE" ]; then
        REBOOT_PENDING=""
        rm -f "$REBOOT_CANCEL_FILE" "$REBOOT_TIMER_PID_FILE"
    fi
}

# === MAIN LOOP ===

# Init offset (skip messages that arrived while the bot was stopped)
if [ -f "$OFFSET_FILE" ]; then
    OFFSET=$(cat "$OFFSET_FILE")
else
    RESULT=$(_tg_get getUpdates "offset=-1" 2>/dev/null)
    LAST_UID=$(echo "$RESULT" | grep -o '"update_id":[0-9]*' | tail -1 | grep -o '[0-9]*')
    if [ -n "$LAST_UID" ]; then
        OFFSET=$((LAST_UID + 1))
    else
        OFFSET=0
    fi
    echo "$OFFSET" > "$OFFSET_FILE"
fi

# Init WG peer tracking
wg show "$WG_IFACE" dump 2>/dev/null | awk -F'\t' 'NR>1{print $1"|"$5}' > "$WG_PEERS_PREV" 2>/dev/null

send_msg "🚀 <b>OpenWrt Monitor started</b>
Send /help for commands"

send_ntfy "Monitor started" "OpenWrt Monitor is running. Alerts will be delivered here." "default" "rocket"

while true; do
    check_alerts

    RESPONSE=$(_tg_get getUpdates "offset=${OFFSET}&timeout=10" 2>/dev/null)

    if [ -z "$RESPONSE" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    echo "$RESPONSE" > "$TG_RESPONSE_FILE"

    i=0
    while true; do
        uid=$(jsonfilter -i "$TG_RESPONSE_FILE" -e "@.result[$i].update_id" 2>/dev/null)
        [ -z "$uid" ] && break
        cid=$(jsonfilter -i "$TG_RESPONSE_FILE" -e "@.result[$i].message.chat.id" 2>/dev/null)
        txt=$(jsonfilter -i "$TG_RESPONSE_FILE" -e "@.result[$i].message.text" 2>/dev/null)
        from_id=$(jsonfilter -i "$TG_RESPONSE_FILE" -e "@.result[$i].message.from.id" 2>/dev/null)
        from_user=$(jsonfilter -i "$TG_RESPONSE_FILE" -e "@.result[$i].message.from.username" 2>/dev/null)
        from_name=$(jsonfilter -i "$TG_RESPONSE_FILE" -e "@.result[$i].message.from.first_name" 2>/dev/null)

        if [ -n "$uid" ]; then
            new_offset=$((uid + 1))
            if [ "$new_offset" -gt "$OFFSET" ] 2>/dev/null; then
                OFFSET=$new_offset
                echo "$OFFSET" > "$OFFSET_FILE"
            fi
        fi

        i=$((i + 1))

        # Auth check
        if [ "$cid" != "$CHAT_ID" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S')|${from_id}|${from_user:-no_username}|${from_name}|${txt}" >> "$INTRUDERS_LOG"
            if [ -n "$UNAUTHORIZED_IMG" ] && [ -f "$UNAUTHORIZED_IMG" ]; then
                _send_photo_to "$cid" "$UNAUTHORIZED_IMG"
            else
                _send_text_to "$cid" "$UNAUTHORIZED_TEXT"
            fi
            continue
        fi

        [ -z "$txt" ] && continue

        # Route commands
        case "$txt" in
            /ping|/ping@*)       cmd_ping ;;
            /status|/status@*)   cmd_status ;;
            /wg|/wg@*)           cmd_wg ;;
            /traffic|/traffic@*) cmd_traffic ;;
            /dns|/dns@*)         cmd_dns ;;
            /clients|/clients@*) cmd_clients ;;
            /vpn|/vpn@*)         cmd_vpn ;;
            /speedtest|/speedtest@*) cmd_speedtest ;;
            /top|/top@*)         cmd_top ;;
            /reboot|/reboot@*)   cmd_reboot ;;
            /intruders|/intruders@*) cmd_intruders ;;
            /help|/help@*|/start|/start@*) cmd_help ;;
        esac
    done

    sleep "$POLL_INTERVAL"
done
