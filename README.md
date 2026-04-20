# OpenWrt Monitor Bot

Lightweight Telegram bot + [ntfy.sh](https://ntfy.sh) push alerts for monitoring OpenWrt routers. A single shell script, no daemons to build, no databases.

- **Telegram** — on-demand queries (`/status`, `/wg`, `/top`, `/speedtest`, ...)
- **ntfy.sh** — instant push notifications for VPN down, RAM/temp spikes, WireGuard peer connects/disconnects

Tested on OpenWrt 24.10 (aarch64). Works on any OpenWrt with `curl`, `jsonfilter`, and `wireguard-tools`.

---

## Features

### Telegram commands

| Command | What it does |
|---|---|
| `/status` | Uptime, CPU load, RAM, disk, temperature, external IP, connection count |
| `/wg` | WireGuard peers with traffic, online status, last handshake, totals |
| `/clients` | Devices in LAN (from DHCP leases + ARP) |
| `/traffic` | RX/TX per interface since boot |
| `/top` | Top 10 LAN clients by active connections (medal ranking) |
| `/speedtest` | Download/upload speed from the router |
| `/dns` | Status of your DNS resolver (AdGuard Home by default) |
| `/vpn` | Status of your VPN process (uptime, RAM) — configurable |
| `/reboot` | Reboot router (requires confirmation, auto-cancels after 30s) |
| `/intruders` | Log of unauthorized access attempts (sorted by attempts) |
| `/help` | Command list |
| `/ping` | Connectivity check |

### ntfy.sh alerts

Alerts arrive as push notifications on your phone via the [ntfy app](https://ntfy.sh/docs/subscribe/phone/):

| Event | Priority | Throttle |
|---|---|---|
| VPN process down | `urgent` (rings) | once per event |
| VPN recovered | `default` | — |
| RAM > threshold | `high` | 10 min |
| CPU temp > threshold | `urgent` | 10 min |
| WG peer connected | `low` (quiet) | per event |
| WG peer disconnected | `min` (silent) | per event |

All thresholds are configurable.

### Security

- Bot only responds to a single `CHAT_ID`. Others get a configurable image/text reply.
- Every unauthorized attempt is logged (TG id, username, name, timestamp) — viewable with `/intruders`.
- Config file has mode `600`.
- `BOT_TOKEN` is passed to `curl` via `--config -` (stdin), not in argv — so it does not appear in the output of `ps`. (Relies on `printf` being a builtin in busybox `ash`, which it is on OpenWrt.)
- ntfy topic is public — **use a long random topic name** (installer generates one). If you need authentication, [self-host ntfy](https://docs.ntfy.sh/install/) and set `NTFY_SERVER`.

---

## Requirements

- OpenWrt 21.02+ (developed on 24.10)
- Packages: `curl`, `jsonfilter` (usually pre-installed), `wireguard-tools` (only if you use WG)
- `busybox` with `pidof`, `awk` (default on OpenWrt)

The installer checks and installs missing packages.

---

## Quick install

On the router:

```sh
cd /tmp
git clone https://github.com/Duke1715/openwrt-monitor-bot.git
cd openwrt-monitor-bot
sh install.sh
```

The installer will:
1. Check dependencies, install missing packages via `opkg`
2. Prompt for `BOT_TOKEN`, `CHAT_ID`, `NTFY_TOPIC`, and interface names (with auto-detection)
3. Write `/etc/wrt-monitor-bot.conf` (mode 600)
4. Install `bot.sh` → `/usr/local/bin/`, init → `/etc/init.d/`
5. Enable and start the service

Verify with `/ping` in Telegram.

---

## Manual install

```sh
# Dependencies
opkg update
opkg install curl wireguard-tools   # jsonfilter is usually pre-installed

# Files
cp bot.sh /usr/local/bin/wrt-monitor-bot.sh
chmod 755 /usr/local/bin/wrt-monitor-bot.sh

cp wrt-monitor-bot.init /etc/init.d/wrt-monitor-bot
chmod 755 /etc/init.d/wrt-monitor-bot

cp config.example.sh /etc/wrt-monitor-bot.conf
chmod 600 /etc/wrt-monitor-bot.conf
vi /etc/wrt-monitor-bot.conf   # fill in BOT_TOKEN, CHAT_ID, etc.

# Service
service wrt-monitor-bot enable
service wrt-monitor-bot start
```

---

## Getting credentials

### Telegram `BOT_TOKEN`

1. Open Telegram, message [@BotFather](https://t.me/BotFather)
2. `/newbot` → pick a name and username
3. Copy the token, it looks like `1234567890:AAHMh7yGu...`

### Telegram `CHAT_ID`

1. Message [@userinfobot](https://t.me/userinfobot) in Telegram
2. It replies with your numeric `Id`

### ntfy.sh topic

The installer generates a random topic for you. If you want to set it manually:

1. Pick a long random string, e.g. `wrt-bot-a7k3m9xq2w`
2. Install the [ntfy app](https://ntfy.sh/docs/subscribe/phone/) on your phone
3. Subscribe to your topic
4. Or view in browser: `https://ntfy.sh/YOUR_TOPIC`

**Warning:** ntfy.sh topics are unauthenticated by default. Anyone who knows the topic name sees your alerts. Use a long random string. For stronger privacy, [self-host ntfy](https://docs.ntfy.sh/install/) and set `NTFY_SERVER`.

---

## Configuration

All options live in `/etc/wrt-monitor-bot.conf`. Change and restart:

```sh
service wrt-monitor-bot restart
```

### Required

| Variable | Description |
|---|---|
| `BOT_TOKEN` | Telegram bot token |
| `CHAT_ID` | Your numeric Telegram chat id |

### Network

| Variable | Default | Description |
|---|---|---|
| `WAN_IFACE` | `eth1` | WAN interface name (`ip link` to find) |
| `LAN_IFACE` | `br-lan` | LAN bridge |
| `WG_IFACE` | `wg0` | WireGuard interface |
| `LAN_SUBNET_PREFIX` | `192.168.1.` | For `/top` conntrack filter |

### Services

| Variable | Default | Description |
|---|---|---|
| `AGH_PROCESS_NAME` | `AdGuardHome` | DNS resolver process name (for `/dns`). Empty to disable. |
| `AGH_URL` | — | Dashboard URL shown in `/dns` |
| `VPN_PROCESS_NAME` | — | VPN process to monitor (`sing-box`, `xray`, etc.). Empty disables `/vpn` and VPN alerts. |
| `VPN_LABEL` | `VPN` | Friendly label in messages |

### ntfy

| Variable | Default | Description |
|---|---|---|
| `NTFY_TOPIC` | — | Topic name. Empty disables all ntfy alerts. |
| `NTFY_SERVER` | `https://ntfy.sh` | Server URL (change if self-hosting) |

### Thresholds

| Variable | Default | Description |
|---|---|---|
| `ALERT_INTERVAL` | `30` | Alert check interval (seconds) |
| `ALERT_RAM_THRESHOLD` | `90` | RAM % to trigger alert |
| `ALERT_TEMP_THRESHOLD` | `80` | CPU °C to trigger alert |
| `ALERT_THROTTLE` | `600` | Min seconds between same alerts |
| `WG_HANDSHAKE_TIMEOUT` | `180` | Peer online if handshake within N sec |

### Speedtest

| Variable | Default | Description |
|---|---|---|
| `SPEEDTEST_URL_DL` | Selectel 10MB | Download test file |
| `SPEEDTEST_URL_UL` | Selectel | POST target for upload test |
| `EXT_IP_URL` | `ifconfig.me/ip` | External IP lookup |

### Unauthorized responses

| Variable | Default | Description |
|---|---|---|
| `UNAUTHORIZED_IMG` | — | Path to image shown to strangers |
| `UNAUTHORIZED_TEXT` | English generic text | Fallback if image not set |

Place any `.jpg` at the path in `UNAUTHORIZED_IMG`. To install with the bundled example, put your image at `assets/unauthorized.jpg` before running `install.sh`.

---

## WireGuard peer names

The bot shows friendly names for WG peers by reading `description` from UCI. To name your peers:

```sh
uci set network.my_peer_section.description='John iPhone'
uci commit network
```

Without a description the bot shows the UCI section name, or `Unknown`.

---

## Architecture

- **Single script** (`bot.sh`) — ~700 lines of POSIX `sh`
- **Polling** — main loop calls Telegram `getUpdates` with a 10-second server-side long-poll timeout (`timeout=10`). Between iterations it sleeps `POLL_INTERVAL` seconds (default `2`). When updates arrive, Telegram returns immediately regardless of the timeout.
- **Alert checks** — run at most once per `ALERT_INTERVAL` seconds (default `30`), evaluated at the top of each loop iteration.
- **JSON parsing** — via `jsonfilter` (built into OpenWrt), no `jq` dependency
- **State** — plain files in `STATE_DIR` (default `/tmp`) — offset, logs, peer cache, alert flags. Reset on reboot.
- **Peer name cache** — `uci show network` result cached for `CACHE_TTL_PEER` seconds to avoid re-parsing UCI on every message
- **External IP cache** — `CACHE_TTL_EXT_IP` TTL to avoid hammering the lookup service
- **Alert throttle** — RAM/temp alerts rate-limited by `ALERT_THROTTLE` (default 10 min) to avoid spam
- **`curl` timeouts** — `--max-time 15` for getUpdates (long-poll=10 + margin), `--max-time 5` for external IP, `--max-time 15` for speedtest phases.
- **Recovery alerts** — VPN sends an explicit "recovered" notification when the process comes back. RAM/temp alerts do not send a "normalized" notification — they rely on `ALERT_THROTTLE` to stop firing once conditions improve (intentionally asymmetric to reduce notification noise on flapping thresholds).

Memory footprint: ~1.5 MB RSS (busybox `sh` + a few curl invocations).

---

## Troubleshooting

**Bot doesn't respond**

```sh
logread | grep wrt-monitor
ps | grep wrt-monitor-bot
cat /etc/wrt-monitor-bot.conf    # check BOT_TOKEN, CHAT_ID
```

Test the token manually:
```sh
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getMe"
```

**Wrong interfaces in `/traffic`**

Check actual names: `ip link` or `cat /proc/net/dev`. Update `WAN_IFACE`/`LAN_IFACE`/`WG_IFACE` and restart.

**`/top` shows no clients**

Check `LAN_SUBNET_PREFIX` matches your LAN (e.g. `10.0.0.` instead of default `192.168.1.`).

**ntfy alerts not arriving**

1. Check topic subscription in the ntfy app
2. Test from router: `curl -d "test" https://ntfy.sh/YOUR_TOPIC`
3. If `NTFY_TOPIC` is empty in config, alerts are disabled

**VPN alert fires when VPN is up**

The bot uses `pidof "$VPN_PROCESS_NAME"`. Check the exact name: `ps | grep -i your-vpn`.

**RAM/temp alerts are noisy**

Raise `ALERT_RAM_THRESHOLD` / `ALERT_TEMP_THRESHOLD` or increase `ALERT_THROTTLE`.

---

## Development

### Syntax check

```sh
sh -n bot.sh install.sh wrt-monitor-bot.init
```

Run automatically via GitHub Actions on every push/PR (see `.github/workflows/shellcheck.yml`).

### Portability

The script targets **OpenWrt / busybox**. It uses:

- `stat -c %Y` (GNU/busybox form — BSD/macOS `stat` uses `-f %m`)
- `uci` for peer name lookup
- `pidof`, `awk`, `jsonfilter` from busybox
- `/proc/net/nf_conntrack`, `/proc/net/arp`, `/tmp/dhcp.leases` (OpenWrt paths)

It will **not** run on macOS or generic desktop Linux without modifications. Test on a real OpenWrt device or in a container (e.g. `openwrtorg/rootfs`).

### Running with a custom config path

```sh
WRT_BOT_CONFIG=./test-config.sh sh bot.sh
```

---

## License

MIT — see [LICENSE](LICENSE).

---

## Contributing

Pull requests welcome. Keep the script portable (`/bin/sh`, no bashisms, no extra dependencies).

Ideas that would fit nicely:
- Per-peer traffic deltas (last hour, last day)
- Inline buttons for `/reboot` confirmation
- `/backup` command to sysupgrade backup
- Support for multiple `CHAT_ID`s (comma-separated)
- Self-hosted ntfy with auth token
