#!/bin/sh
# shellcheck shell=sh
# anynines / CloudFoundry-specific container entrypoint.
#
# Why this exists:
#   CF diego/garden always runs the container with its own init as PID 1
#   (/tmp/garden-init) and executes the image command via `/bin/sh -c`,
#   so the stock entrypoint-dispatch.sh NEVER gets PID 1. Its fallback
#   branch skips the s6 supervision tree → cloudflared / dashboard /
#   sshd never start, leaving only `hermes gateway run`.
#
# This wrapper preserves the stock behaviour in normal Docker (PID 1 →
# /init) and, in the CF fallback case, manually backgrounds the three
# side services by reusing the stock s6-rc.d run scripts, then hands
# off to main-wrapper.sh exactly like the stock fallback does.
#
# Usage (CF manifest command):
#   command: /opt/hermes/docker/entrypoint-anynines.sh gateway run

set -e

if [ "$$" -eq 1 ]; then
    exec /init /opt/hermes/docker/main-wrapper.sh "$@"
fi

echo "[hermes] [anynines] CF fallback (not PID 1): manual side-service bootstrap" >&2
export PATH="/command:/package/admin/s6/command:${PATH}"

# CF fallback: /init never runs here, so /run/s6/container_environment only
# holds the tiny stage2-hook seed — not the CF-injected env (TUNNEL_TOKEN,
# SSH_ENABLED, HERMES_DASHBOARD_*, ...). `with-contenv` would then wipe the
# process env and re-seed from that near-empty dir, silently disabling all
# side services (only `hermes gateway run` would survive). Ask with-contenv
# to keep the current environment instead; this mirrors normal s6-overlay
# behaviour where /init already populated container_environment from the
# same process env we launch with. See also the S6_KEEP_ENV contract in
# s6-overlay's with-contenv.
export S6_KEEP_ENV=1

# Stock root bootstrap: UID/GID remap, volume chown, config seeding,
# skills sync (same as the official non-PID-1 fallback).
/opt/hermes/docker/stage2-hook.sh

mkdir -p /opt/data/logs
chown -R hermes:hermes /opt/data 2>/dev/null || true

# --- cloudflared ---
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    (
        cd /opt/data || exit 1
        nohup /command/with-contenv sh /opt/hermes/docker/s6-rc.d/cloudflared/run \
            > /opt/data/logs/cloudflared.log 2>&1 &
    )
    echo "[hermes] [anynines] cloudflared launched" >&2
else
    echo "[hermes] [anynines] TUNNEL_TOKEN unset, cloudflared skipped" >&2
fi

# --- dashboard ---
case "${HERMES_DASHBOARD:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        (
            cd /opt/data || exit 1
            nohup /command/with-contenv sh /opt/hermes/docker/s6-rc.d/dashboard/run \
                > /opt/data/logs/dashboard.log 2>&1 &
        )
        echo "[hermes] [anynines] dashboard launched" >&2
        ;;
    *)
        echo "[hermes] [anynines] HERMES_DASHBOARD unset/false, dashboard skipped" >&2
        ;;
esac

# --- sshd ---
case "${SSH_ENABLED:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        # CF holds port 2222 for its own diego-sshd, so default to 22.
        export SSH_PORT="${SSH_PORT:-22}"
        (
            cd /opt/data || exit 1
            nohup /command/with-contenv sh /opt/hermes/docker/s6-rc.d/sshd/run \
                > /opt/data/logs/sshd.log 2>&1 &
        )
        echo "[hermes] [anynines] sshd launched on ${SSH_PORT}" >&2
        ;;
    *)
        echo "[hermes] [anynines] SSH_ENABLED unset/false, sshd skipped" >&2
        ;;
esac

# Same hand-off as the stock fallback: route CMD args → `hermes <args>`.
exec /opt/hermes/docker/main-wrapper.sh "$@"