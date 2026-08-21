#!/data/data/com.termux/files/usr/bin/bash
#
# lazyhub.sh - all-in-one script for multi-Roblox freeform setup
#
# Usage:
#   ./lazyhub.sh setup            -> enable freeform + force resizable (run once, then reboot)
#   ./lazyhub.sh init              -> launch all 5 packages into freeform with staggered
#                                     starting positions, so you can manually drag/resize
#                                     each one into place
#   ./lazyhub.sh save              -> save current window positions/sizes to config
#   ./lazyhub.sh launch            -> launch all 5 packages into saved freeform positions
#   ./lazyhub.sh start             -> launch + background monitor (auto-relaunch crashed apps)
#                                     + background webdisplay sender (if configured)
#   ./lazyhub.sh stop              -> stop both background loops started by 'start'
#   ./lazyhub.sh webdisplay-setup  -> ask for the web display URL, save it
#   ./lazyhub.sh webdisplay-send   -> send all json files once, right now (for testing)
#
# Typical first-time flow:
#   ./lazyhub.sh setup             (then reboot device)
#   ./lazyhub.sh init               (drag/resize each of the 5 windows into place)
#   ./lazyhub.sh save               (locks in what you just arranged)
#   ./lazyhub.sh webdisplay-setup   (one-time, enter your server URL)
#
# From then on, just:
#   ./lazyhub.sh start
#
# Requires ONE of: root (su), or Shizuku (rish)

set -u
CONF="$HOME/freeform.conf"

PACKAGES=(
    com.roblox.dclienu
    com.roblox.dcliena
    com.roblox.dclienw
    com.roblox.dclienq
    com.roblox.dcliens
)

# ---- pick a shell runner: su, or shizuku's rish ----
if command -v su >/dev/null 2>&1 && su -c 'id' >/dev/null 2>&1; then
    RUN() { su -c "$*"; }
    MODE="root"
elif command -v rish >/dev/null 2>&1; then
    RUN() { rish -c "$*"; }
    MODE="shizuku"
else
    echo "ERROR: no root (su) and no Shizuku (rish) found."
    echo "Set up one of them first."
    exit 1
fi

ensure_conf() {
    if [[ ! -f "$CONF" ]]; then
        echo "# package|x|y|width|height" > "$CONF"
        for pkg in "${PACKAGES[@]}"; do
            echo "$pkg|0|0|540|600" >> "$CONF"
        done
        echo "[i] created default $CONF"
    fi
}

get_taskid() {
    local pkg="$1"
    local dump
    dump=$(RUN "dumpsys activity activities")

    local tid
    tid=$(echo "$dump" | grep -A2 "$pkg/" | grep -oE 'taskId=[0-9]+' | head -n1 | cut -d= -f2)
    if [[ -n "$tid" ]]; then echo "$tid"; return; fi

    tid=$(echo "$dump" | grep "$pkg/" | grep -oE 't[0-9]+' | tail -n1 | tr -d 't')
    if [[ -n "$tid" ]]; then echo "$tid"; return; fi

    echo ""
}

get_current_bounds() {
    local pkg="$1"
    local dump
    dump=$(RUN "dumpsys activity activities")
    echo "$dump" \
        | grep -A 40 "$pkg" \
        | grep -oE 'bounds=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' \
        | head -n1
}

launch_and_place() {
    local pkg="$1" x="$2" y="$3" w="$4" h="$5"

    echo "[*] $pkg -> resolving launch activity..."
    local comp
    comp=$(RUN "cmd package resolve-activity --brief '$pkg'" | tail -n 1 | tr -d '\r')

    if [[ -z "$comp" || "$comp" != *"/"* ]]; then
        echo "    [!] could not resolve activity for $pkg, skipping"
        return 1
    fi
    echo "    resolved: $comp"

    # If the app crashed, Android often leaves its old task alive in Recents.
    # Relaunching with --windowingMode 5 against an EXISTING task gets ignored
    # (the flag only applies when a brand-new task is created) - so the app
    # comes back fullscreen, not freeform, and never gets positioned.
    # force-stop first to guarantee a clean, fresh task every time.
    RUN "am force-stop '$pkg'" >/dev/null 2>&1
    sleep 0.5

    RUN "am start -n '$comp' --windowingMode 5" >/dev/null 2>&1

    local taskid=""
    for i in 1 2 3 4 5; do
        sleep 1
        taskid=$(get_taskid "$pkg")
        [[ -n "$taskid" ]] && break
    done

    if [[ -z "$taskid" ]]; then
        echo "    [!] taskId for $pkg not found, launched but not positioned"
        return 1
    fi
    echo "    taskId=$taskid"

    local right=$((x + w))
    local bottom=$((y + h))
    local target="bounds=[$x,$y][$right,$bottom]"
    echo "    placing at [$x,$y,$right,$bottom]"

    local matched=0
    for attempt in 1 2 3 4 5 6; do
        RUN "am task resize $taskid $x $y $right $bottom" >/dev/null 2>&1
        sleep 2
        local current
        current=$(get_current_bounds "$pkg")
        if [[ "$current" == "$target" ]]; then
            matched=1
            break
        fi
    done

    if [[ "$matched" == "1" ]]; then
        echo "    [ok] $pkg placed and confirmed"
    else
        echo "    [!] $pkg still didn't stabilize at target bounds after retries"
    fi
}

cmd_setup() {
    echo "[i] using mode: $MODE"
    echo "[*] enabling freeform support..."
    RUN "settings put global enable_freeform_support 1" >/dev/null 2>&1
    echo "[*] forcing resizable activities (needed for apps like Roblox that block resizing)..."
    RUN "settings put global force_resizable_activities 1" >/dev/null 2>&1
    ensure_conf
    echo "[ok] setup done."
    echo "[!] IMPORTANT: reboot your device now for these settings to fully apply."
}

cmd_init() {
    echo "[i] using mode: $MODE"
    RUN "settings put global enable_freeform_support 1" >/dev/null 2>&1

    echo "[i] launching all 5 packages into freeform with staggered starting positions."
    echo "[i] after this, manually drag/resize each window where you want it,"
    echo "[i] then run: $0 save"
    echo ""

    local i=0
    local base_w=540
    local base_h=600
    local step=60

    for pkg in "${PACKAGES[@]}"; do
        local x=$((step * i))
        local y=$((step * i))
        launch_and_place "$pkg" "$x" "$y" "$base_w" "$base_h"
        i=$((i + 1))
    done

    echo ""
    echo "[i] init done. Arrange the windows, then run: $0 save"
}

cmd_save() {
    echo "[i] using mode: $MODE"
    local dump
    dump=$(RUN "dumpsys activity activities")

    get_bounds_for() {
        local pkg="$1"
        echo "$dump" \
            | grep -A 40 "$pkg" \
            | grep -oE 'bounds=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' \
            | head -n1
    }

    echo "# package|x|y|width|height" > "$CONF"

    for pkg in "${PACKAGES[@]}"; do
        b=$(get_bounds_for "$pkg")
        if [[ -z "$b" ]]; then
            echo "[!] $pkg: no active window found (is it open in freeform?) - skipped"
            continue
        fi
        coords=$(echo "$b" | grep -oE '\-?[0-9]+' | tr '\n' ' ')
        read -r x1 y1 x2 y2 <<< "$coords"
        w=$((x2 - x1))
        h=$((y2 - y1))
        echo "$pkg|$x1|$y1|$w|$h" >> "$CONF"
        echo "[ok] $pkg -> x=$x1 y=$y1 w=$w h=$h"
    done

    echo "[i] saved to $CONF"
}

cmd_launch() {
    echo "[i] using mode: $MODE"
    RUN "settings put global enable_freeform_support 1" >/dev/null 2>&1
    ensure_conf

    while IFS='|' read -r pkg x y w h; do
        [[ "$pkg" =~ ^#.*$ || -z "$pkg" ]] && continue
        launch_and_place "$pkg" "$x" "$y" "$w" "$h"
    done < "$CONF"

    echo "[i] done - all packages launched."
}

# ============================================================
#  App monitor (auto-relaunch crashed packages)
# ============================================================

MONITOR_PID_FILE="$HOME/.lazyhub_monitor.pid"
MONITOR_LOG="$HOME/.lazyhub_monitor.log"
MONITOR_INTERVAL=10   # seconds between checks

is_running() {
    local pkg="$1"
    local pid
    pid=$(RUN "pidof $pkg" 2>/dev/null | tr -d '\r')
    [[ -n "$pid" ]]
}

cmd_monitor_loop() {
    # internal - runs forever in background, checking each package is alive
    ensure_conf
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] monitor started (interval=${MONITOR_INTERVAL}s)"
    while true; do
        sleep "$MONITOR_INTERVAL"
        while IFS='|' read -r pkg x y w h; do
            [[ "$pkg" =~ ^#.*$ || -z "$pkg" ]] && continue
            if ! is_running "$pkg"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!] $pkg not running - relaunching"
                launch_and_place "$pkg" "$x" "$y" "$w" "$h"
            fi
        done < "$CONF"
    done
}

# ============================================================
#  Web display sender (POSTs json files to your server)
# ============================================================

WEBDISPLAY_URL_FILE="$HOME/.lazyhub_webdisplay_url"
WEBDISPLAY_DIR="/sdcard/Delta/LAZYHUB/WebDisplay"
WEBDISPLAY_PID_FILE="$HOME/.lazyhub_webdisplay.pid"
WEBDISPLAY_LOG="$HOME/.lazyhub_webdisplay.log"
WEBDISPLAY_INTERVAL=900   # 15 minutes
WEBDISPLAY_MAX_RETRIES=3

cmd_webdisplay_setup() {
    echo "Enter the web display URL (example: http://51.21.21.5:34599/web-display)"
    read -r -p "URL: " url
    if [[ -z "$url" ]]; then
        echo "[!] empty URL, not saved."
        exit 1
    fi
    echo "$url" > "$WEBDISPLAY_URL_FILE"
    echo "[ok] saved: $url"
    echo "[i] json files will be read from: $WEBDISPLAY_DIR"
    mkdir -p "$WEBDISPLAY_DIR" 2>/dev/null
}

send_one_json() {
    local file="$1" url="$2"
    local attempt=1
    local code

    while [[ $attempt -le $WEBDISPLAY_MAX_RETRIES ]]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            --data-binary @"$file" \
            --connect-timeout 10 --max-time 30 \
            "$url")

        if [[ "$code" =~ ^2 ]]; then
            echo "[ok] $(basename "$file") -> HTTP $code"
            return 0
        fi

        echo "[!] $(basename "$file") -> HTTP ${code:-no response} (attempt $attempt/$WEBDISPLAY_MAX_RETRIES)"
        attempt=$((attempt + 1))
        [[ $attempt -le $WEBDISPLAY_MAX_RETRIES ]] && sleep $((attempt * 3))
    done

    echo "[!] $(basename "$file") -> FAILED after $WEBDISPLAY_MAX_RETRIES attempts"
    return 1
}

cmd_webdisplay_send_once() {
    if [[ ! -f "$WEBDISPLAY_URL_FILE" ]]; then
        echo "[!] webdisplay not configured. Run: $0 webdisplay-setup"
        return 1
    fi
    local url
    url=$(cat "$WEBDISPLAY_URL_FILE")

    if [[ ! -d "$WEBDISPLAY_DIR" ]]; then
        echo "[!] folder not found: $WEBDISPLAY_DIR"
        return 1
    fi

    local found=0
    for f in "$WEBDISPLAY_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        found=1
        send_one_json "$f" "$url"
    done

    if [[ "$found" == "0" ]]; then
        echo "[i] no .json files found in $WEBDISPLAY_DIR"
    fi
}

cmd_webdisplay_loop() {
    # internal - runs forever in background, sending every WEBDISPLAY_INTERVAL seconds
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] webdisplay sender started (interval=${WEBDISPLAY_INTERVAL}s)"
    while true; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] sending batch..."
        cmd_webdisplay_send_once
        sleep "$WEBDISPLAY_INTERVAL"
    done
}

# ============================================================
#  start / stop - runs everything together in background
# ============================================================

cmd_start() {
    if [[ -f "$MONITOR_PID_FILE" ]] && kill -0 "$(cat "$MONITOR_PID_FILE")" 2>/dev/null; then
        echo "[!] already running (monitor pid $(cat "$MONITOR_PID_FILE")). Run '$0 stop' first if you want to restart."
        exit 1
    fi

    echo "[i] launching all packages first..."
    cmd_launch

    echo "[i] starting background app monitor (checks every ${MONITOR_INTERVAL}s)..."
    nohup bash "$0" _monitor_loop > "$MONITOR_LOG" 2>&1 &
    disown
    echo $! > "$MONITOR_PID_FILE"
    echo "[ok] monitor running as pid $(cat "$MONITOR_PID_FILE")"

    if [[ -f "$WEBDISPLAY_URL_FILE" ]]; then
        echo "[i] starting background webdisplay sender (every ${WEBDISPLAY_INTERVAL}s)..."
        nohup bash "$0" _webdisplay_loop > "$WEBDISPLAY_LOG" 2>&1 &
        disown
        echo $! > "$WEBDISPLAY_PID_FILE"
        echo "[ok] webdisplay sender running as pid $(cat "$WEBDISPLAY_PID_FILE")"
    else
        echo "[i] webdisplay not configured, skipping sender. Run '$0 webdisplay-setup' to enable it."
    fi

    echo "[i] logs: tail -f $MONITOR_LOG   |   tail -f $WEBDISPLAY_LOG"
    echo "[i] stop anytime with: $0 stop"
}

cmd_stop() {
    local stopped_any=0

    if [[ -f "$MONITOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "[ok] app monitor (pid $pid) stopped."
            stopped_any=1
        fi
        rm -f "$MONITOR_PID_FILE"
    fi

    if [[ -f "$WEBDISPLAY_PID_FILE" ]]; then
        local pid
        pid=$(cat "$WEBDISPLAY_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "[ok] webdisplay sender (pid $pid) stopped."
            stopped_any=1
        fi
        rm -f "$WEBDISPLAY_PID_FILE"
    fi

    if [[ "$stopped_any" == "0" ]]; then
        echo "[i] nothing was running."
    fi
}

case "${1:-}" in
    setup)
        cmd_setup
        ;;
    init)
        cmd_init
        ;;
    save)
        cmd_save
        ;;
    launch)
        cmd_launch
        ;;
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    webdisplay-setup)
        cmd_webdisplay_setup
        ;;
    webdisplay-send)
        cmd_webdisplay_send_once
        ;;
    _monitor_loop)
        cmd_monitor_loop
        ;;
    _webdisplay_loop)
        cmd_webdisplay_loop
        ;;
    *)
        echo "Usage: $0 {setup|init|save|launch|start|stop|webdisplay-setup|webdisplay-send}"
        echo ""
        echo "  setup             - enable freeform + force resizable (run once, then reboot)"
        echo "  init              - launch all 5 packages into freeform, staggered, for manual arranging"
        echo "  save              - save current window positions/sizes of all 5 packages"
        echo "  launch            - launch all 5 packages into their saved freeform positions"
        echo "  start             - launch all packages + background app monitor + webdisplay sender"
        echo "  stop              - stop both background loops started by 'start'"
        echo "  webdisplay-setup  - configure the URL to POST json files to"
        echo "  webdisplay-send   - send all json files once, right now (for testing)"
        exit 1
        ;;
esac
