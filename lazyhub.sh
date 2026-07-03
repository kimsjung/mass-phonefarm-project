#!/data/data/com.termux/files/usr/bin/bash
#
# lazyhub.sh - all-in-one script for multi-Roblox freeform setup
#
# Usage:
#   ./lazyhub.sh setup    -> enable freeform + force resizable (run once, then reboot)
#   ./lazyhub.sh init     -> launch all 5 packages into freeform with staggered
#                            starting positions, so you can manually drag/resize
#                            each one into place
#   ./lazyhub.sh save     -> save current window positions/sizes to config
#   ./lazyhub.sh launch   -> launch all 5 packages into saved freeform positions
#
# Typical first-time flow:
#   ./lazyhub.sh setup    (then reboot device)
#   ./lazyhub.sh init     (drag/resize each of the 5 windows into place)
#   ./lazyhub.sh save     (locks in what you just arranged)
#
# From then on, just:
#   ./lazyhub.sh launch
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
    echo "    placing at [$x,$y,$right,$bottom]"
    RUN "am task resize $taskid $x $y $right $bottom" >/dev/null 2>&1
    sleep 0.5
    RUN "am task resize $taskid $x $y $right $bottom" >/dev/null 2>&1

    echo "    [ok] $pkg placed"
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

cmd_start() {
    if [[ -f "$MONITOR_PID_FILE" ]] && kill -0 "$(cat "$MONITOR_PID_FILE")" 2>/dev/null; then
        echo "[!] monitor already running (pid $(cat "$MONITOR_PID_FILE")). Run '$0 stop' first if you want to restart it."
        exit 1
    fi

    echo "[i] launching all packages first..."
    cmd_launch

    echo "[i] starting background monitor (checks every ${MONITOR_INTERVAL}s, relaunches crashed apps)..."
    nohup bash "$0" _monitor_loop > "$MONITOR_LOG" 2>&1 &
    disown
    echo $! > "$MONITOR_PID_FILE"
    echo "[ok] monitor running as pid $(cat "$MONITOR_PID_FILE")"
    echo "[i] log: tail -f $MONITOR_LOG"
    echo "[i] stop anytime with: $0 stop"
}

cmd_stop() {
    if [[ -f "$MONITOR_PID_FILE" ]]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo "[ok] monitor (pid $pid) stopped."
        else
            echo "[i] monitor pid $pid was not running (already stopped)."
        fi
        rm -f "$MONITOR_PID_FILE"
    else
        echo "[i] no monitor pid file found - nothing to stop."
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
    _monitor_loop)
        cmd_monitor_loop
        ;;
    *)
        echo "Usage: $0 {setup|init|save|launch|start|stop}"
        echo ""
        echo "  setup   - enable freeform + force resizable activities (run once, then reboot)"
        echo "  init    - launch all 5 packages into freeform, staggered, for manual arranging"
        echo "  save    - save current window positions/sizes of all 5 packages"
        echo "  launch  - launch all 5 packages into their saved freeform positions"
        echo "  start   - launch all packages, then keep monitoring in background and"
        echo "            auto-relaunch any package that force-closes or isn't running"
        echo "  stop    - stop the background monitor started by 'start'"
        exit 1
        ;;
esac
