#!/bin/bash
# AdGuard Home watchdog: detects outages, auto-restarts, verifies fallback DNS,
# checks for new AdGuard Home image versions (daily, notify-only, never auto-updates),
# and notifies a Discord webhook at each meaningful state transition.
#
# Config: set DISCORD_WEBHOOK_URL, ADGUARD_IP, NEST_IP in config/watchdog.env
# (gitignored, not committed — see config/watchdog.env.example for the template).

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$REPO_DIR/data"
ENV_FILE="$REPO_DIR/config/watchdog.env"
LOG_FILE="$STATE_DIR/watchdog.log"
STATUS_FILE="$STATE_DIR/.watchdog_status"          # "ok" or "down"
RESTART_ATTEMPTED_FILE="$STATE_DIR/.watchdog_restart_attempted"
FALLBACK_NOTIFIED_FILE="$STATE_DIR/.watchdog_fallback_notified"
LAST_UPDATE_CHECK_FILE="$STATE_DIR/.watchdog_last_update_check"
LAST_NOTIFIED_IMAGE_FILE="$STATE_DIR/.watchdog_last_notified_image"

[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# ADGUARD_IP / NEST_IP come from config/watchdog.env (local, gitignored) — these
# placeholders are only a safety net if that file is missing or incomplete.
ADGUARD_IP="${ADGUARD_IP:-<adguard-host-ip>}"
NEST_IP="${NEST_IP:-<router-ip>}"
CONTAINER_NAME="adguardhome"
IMAGE_NAME="adguard/adguardhome"
BLOCKED_TEST_DOMAIN="doubleclick.net"
NORMAL_TEST_DOMAIN="example.com"
INTERNET_PROBE_IP="1.1.1.1"
UPDATE_CHECK_INTERVAL_SECONDS=86400   # once a day

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

notify() {
    local message="$1"
    log "NOTIFY: $message"
    if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        log "WARNING: DISCORD_WEBHOOK_URL not set in $ENV_FILE, skipping Discord notification"
        return
    fi
    local escaped
    escaped="$(json_escape "$message")"
    curl -s -H "Content-Type: application/json" -X POST \
        -d "{\"content\": \"$escaped\"}" \
        "$DISCORD_WEBHOOK_URL" > /dev/null
}

# Returns 0 if AdGuard is up and actively filtering (queried directly, bypassing the Nest).
check_adguard() {
    local result
    result="$(dig +time=3 +tries=1 +short "$BLOCKED_TEST_DOMAIN" @"$ADGUARD_IP" 2>/dev/null)"
    [ "$result" = "0.0.0.0" ]
}

# Returns 0 if the Nest's fallback (secondary) DNS is resolving normal domains for clients.
check_fallback() {
    local result
    result="$(dig +time=3 +tries=1 +short "$NORMAL_TEST_DOMAIN" @"$NEST_IP" 2>/dev/null | head -1)"
    [[ "$result" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && [ "$result" != "0.0.0.0" ]
}

# Returns 0 if there is raw internet connectivity (independent of any DNS).
check_internet() {
    ping -c 2 -t 5 "$INTERNET_PROBE_IP" > /dev/null 2>&1
}

# Pulls the latest AdGuard Home image (at most once per UPDATE_CHECK_INTERVAL_SECONDS)
# and notifies once if it differs from what the running container is using.
# Never auto-updates — just tells you to run `docker compose pull && docker compose up -d`.
check_for_image_update() {
    local now last_check
    now="$(date +%s)"
    last_check="$(cat "$LAST_UPDATE_CHECK_FILE" 2>/dev/null || echo 0)"
    if [ $((now - last_check)) -lt "$UPDATE_CHECK_INTERVAL_SECONDS" ]; then
        return
    fi
    echo "$now" > "$LAST_UPDATE_CHECK_FILE"

    local running_image_id
    running_image_id="$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null)"
    [ -z "$running_image_id" ] && return   # container not running, skip this round

    docker pull "$IMAGE_NAME:latest" >> "$LOG_FILE" 2>&1

    local latest_image_id
    latest_image_id="$(docker inspect --format='{{.Id}}' "$IMAGE_NAME:latest" 2>/dev/null)"
    [ -z "$latest_image_id" ] && return

    log "Image check: running=$running_image_id latest=$latest_image_id"

    if [ "$running_image_id" != "$latest_image_id" ]; then
        local already_notified
        already_notified="$(cat "$LAST_NOTIFIED_IMAGE_FILE" 2>/dev/null || echo "")"
        if [ "$already_notified" != "$latest_image_id" ]; then
            notify "🆕 A new AdGuard Home image is available. Update with: \`cd $REPO_DIR && docker compose pull && docker compose up -d\`"
            echo "$latest_image_id" > "$LAST_NOTIFIED_IMAGE_FILE"
        fi
    fi
}

main() {
    local prev_status
    prev_status="$(cat "$STATUS_FILE" 2>/dev/null || echo ok)"

    if check_adguard; then
        log "AdGuard check: OK"
        if [ "$prev_status" = "down" ]; then
            notify "✅ AdGuard DNS is back up and filtering normally (recovered since last check)."
        fi
        echo "ok" > "$STATUS_FILE"
        rm -f "$RESTART_ATTEMPTED_FILE" "$FALLBACK_NOTIFIED_FILE"
        check_for_image_update
        return
    fi

    log "AdGuard check: DOWN"
    echo "down" > "$STATUS_FILE"

    if [ ! -f "$RESTART_ATTEMPTED_FILE" ]; then
        notify "⚠️ AdGuard DNS is not responding on $ADGUARD_IP. Attempting automatic restart..."
        touch "$RESTART_ATTEMPTED_FILE"

        docker restart "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1

        local recovered=1
        for i in 1 2 3; do
            sleep 5
            if check_adguard; then
                recovered=0
                break
            fi
        done

        if [ "$recovered" -eq 0 ]; then
            notify "✅ Restarting the AdGuard container fixed the issue. Service is back up."
            echo "ok" > "$STATUS_FILE"
            rm -f "$RESTART_ATTEMPTED_FILE" "$FALLBACK_NOTIFIED_FILE"
            return
        else
            notify "🛑 AdGuard DNS restart did NOT fix the issue. Manual resolution needed on the Mac (check \`docker logs $CONTAINER_NAME\`, Docker Desktop, and that the Mac/network are reachable)."
        fi
    fi

    # Still down after a restart attempt (this run or a previous one) — check whether clients
    # are at least falling back to the secondary DNS correctly.
    if [ ! -f "$FALLBACK_NOTIFIED_FILE" ]; then
        if check_fallback; then
            notify "ℹ️ Fallback DNS is working as expected — devices still have internet access via the secondary DNS, but ads/trackers are not being filtered until AdGuard is restored."
            touch "$FALLBACK_NOTIFIED_FILE"
        else
            if check_internet; then
                notify "🔴 Fallback DNS is NOT working even though internet connectivity is up. Devices may be unable to resolve domains — check the Nest's DNS settings."
            else
                notify "🔴 Fallback DNS is not working and internet appears to be down. This may not be a DNS issue — check your internet connection/router."
            fi
            touch "$FALLBACK_NOTIFIED_FILE"
        fi
    fi
}

main
