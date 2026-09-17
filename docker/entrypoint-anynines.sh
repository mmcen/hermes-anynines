#!/bin/sh
# shellcheck shell=sh
# ===========================================================================
# anynines / CloudFoundry entrypoint for hermes-agent-docker.
#
# Why this exists
# ---------------
# CF's diego/garden always runs the container with the platform's own init
# as PID 1 (/tmp/garden-init) and starts the image command as a child, so
# the stock entrypoint-dispatch.sh never owns PID 1. Its fallback branch
# skips s6-overlay entirely, which used to leave cloudflared / dashboard /
# sshd unsupervised (nohup'ed by hand, never restarted when they died).
#
# What this wrapper does
# ----------------------
#   PID 1 (plain Docker)  → hand over to s6-overlay's /init, exactly as the
#                           stock image does. Unchanged behaviour.
#   CF (not PID 1)        → run the stock stage2 bootstrap, assemble a small
#                           s6 scan directory (gateway + enabled side
#                           services) and run `s6-svscan` as the container's
#                           main process. Every service is then supervised:
#                           s6 restarts crashed ones automatically, and
#                           `s6 start|stop|restart|status|logs` (see the `s6`
#                           helper in /usr/local/bin) drives them by hand.
#
#   The gateway is supervised too, but its stdout flows through s6-supervise
#   to the container log stream, so `cf logs` keeps working as before.
#
# Usage (CF manifest command):
#   command: /opt/hermes/docker/entrypoint-anynines.sh gateway run
# ===========================================================================

set -eu

SCANDIR=/run/s6-anynines/service
SRC=/opt/hermes/docker/s6-anynines/service
DATA="${HERMES_HOME:-/opt/data}"
LOGDIR="$DATA/logs"

# shellcheck disable=SC1091
. /opt/hermes/docker/s6-anynines/lib.sh

# --- make the state dir usable by the runtime user --------------------------
# The gateway runs as 'hermes' on both paths (the fallback path drops via
# main-wrapper unless root mode is on; the PID-1 path always drops), and the
# stock bootstrap also does part of its work as hermes (config seeding, skills
# sync — see `as_hermes` in stage2-hook.sh). When HERMES_HOME sits under a
# directory only root can traverse, all of that fails with EACCES:
#   * fallback path: stage2 aborts under `set -e` → container crash loop
#   * PID-1 path (Railway, plain Docker with a custom HERMES_HOME, any platform
#     that mounts a persistent volume at /root/.hermes): cont-init fails and
#     the gateway dies with
#     `PermissionError: [Errno 13] Permission denied: '/root/.hermes/.env'`
# The canonical trigger is HERMES_HOME=/root/.hermes, because /root is 0700
# root. Only ancestors lacking other-execute are touched, so this is a no-op
# for the common case (/opt/data).
#
# /root needs 0755 rather than the 0711 that would normally be enough to
# traverse a directory: on this platform's overlay (grootfs) the hermes user
# cannot create entries under an execute-only /root.
prepare_state_dir() {
    p="$DATA"
    while :; do
        p="$(dirname "$p")"
        case "$p" in /|.|'') break ;; esac
        mode="$(stat -c %a "$p" 2>/dev/null || echo '')"
        case "$mode" in
            *[1357]) ;;                         # already traversable (o+x)
            '') ;;
            *) chmod 0755 "$p" 2>/dev/null || true ;;
        esac
    done
    mkdir -p "$DATA"
    if [ "$(stat -c %u "$DATA" 2>/dev/null)" != "$(id -u hermes 2>/dev/null)" ]; then
        echo "[hermes] [anynines] taking ownership of $DATA for hermes" >&2
        chown -R hermes:hermes "$DATA" 2>/dev/null || true
    fi
}

prepare_state_dir

if [ "$$" -eq 1 ]; then
    exec /init /opt/hermes/docker/main-wrapper.sh "$@"
fi

echo "[hermes] [anynines] CF fallback (not PID 1): s6-supervised services" >&2
export PATH="/command:/package/admin/s6/command:/usr/local/bin:${PATH}"

# /init never ran here, so /run/s6/container_environment holds only the tiny
# stage2-hook seed rather than the CF-injected environment. Tell with-contenv
# to keep the process environment instead of re-seeding from that near-empty
# directory — otherwise every s6-rc.d/*/run script sees an empty
# TUNNEL_TOKEN / SSH_ENABLED / HERMES_DASHBOARD_* and disables itself.
export S6_KEEP_ENV=1

# Stock root bootstrap: UID/GID remap, data-dir ownership, config seeding,
# skills sync (same as the official non-PID-1 fallback).
/opt/hermes/docker/stage2-hook.sh

if root_mode; then
    echo "[hermes] [anynines] ROOT MODE: hermes processes run as root (HERMES_HOME=$DATA)" >&2
else
    chown -R hermes:hermes "$DATA" 2>/dev/null || true
fi
mkdir -p "$LOGDIR"

# This platform has no persistence layer, so keep the data dir bounded:
# truncate oversized logs at every boot.
for f in "$LOGDIR"/*.log; do
    [ -f "$f" ] || continue
    sz=$(wc -c <"$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 5242880 ]; then
        : >"$f"
        echo "[hermes] [anynines] truncated oversized log: $f" >&2
    fi
done

# --- publish the session environment -----------------------------------------
# CF's diego-sshd gives ssh sessions a minimal PATH (/bin:/usr/bin) and drops
# the application environment entirely — so `hermes`/`s6` were not on PATH and
# HERMES_HOME was unset inside `cf ssh` (or the image's own sshd). Publish the
# values to every place a session actually reads:
#   /run/hermes-anynines/env.sh  → sourced by /etc/profile.d (login shells)
#                                  and /etc/bash.bashrc (interactive bash)
#   /etc/environment             → PAM (pam_env) sessions, e.g. the image sshd
#   /usr/bin symlinks            → `cf ssh -c …` / `ssh host cmd`, which never
#                                  source a startup file
SESSION_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/command:/opt/hermes/.venv/bin"

mkdir -p /run/hermes-anynines
{
    echo "# generated by /opt/hermes/docker/entrypoint-anynines.sh"
    echo "export HERMES_HOME='$DATA'"
    echo "export PATH='$SESSION_PATH'"
    echo "export HERMES_ANYNINES_RUN_AS_ROOT='$(root_mode && echo 1 || echo 0)'"
} >/run/hermes-anynines/env.sh
chmod 0644 /run/hermes-anynines/env.sh 2>/dev/null || true

# /etc/environment is a plain KEY=VALUE file (no shell expansion).
printf 'PATH="%s"\nHERMES_HOME="%s"\n' "$SESSION_PATH" "$DATA" >/etc/environment 2>/dev/null || true

ln -sf /usr/local/bin/s6 /usr/bin/s6 2>/dev/null || true
if root_mode; then
    # the gateway itself runs as root, so keep the CLI consistent with it
    ln -sf /opt/hermes/.venv/bin/hermes /usr/bin/hermes 2>/dev/null || true
else
    # stock behaviour: the shim drops to the hermes user before exec'ing
    ln -sf /opt/hermes/bin/hermes /usr/bin/hermes 2>/dev/null || true
fi
echo "[hermes] [anynines] session PATH published (hermes, s6 reachable in ssh sessions)" >&2

# --- assemble the supervised scan directory ---------------------------------

enable() {
    # copy one service definition into the (writable, tmpfs) scan directory
    s="$1"
    [ -d "$SRC/$s" ] || { echo "[hermes] [anynines] service definition missing: $s" >&2; return 0; }
    cp -R "$SRC/$s" "$SCANDIR/$s"
    chmod 0755 "$SCANDIR/$s" 2>/dev/null || true
    chmod 0755 "$SCANDIR/$s/run" 2>/dev/null || true
    [ -f "$SCANDIR/$s/finish" ] && chmod 0755 "$SCANDIR/$s/finish" 2>/dev/null || true
    return 0
}

rm -rf "$SCANDIR"
mkdir -p "$SCANDIR"

# The gateway is the application itself: always supervised, so a crash is
# restarted in place instead of taking the whole container down.
enable gateway

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    enable cloudflared
else
    echo "[hermes] [anynines] TUNNEL_TOKEN unset — cloudflared not supervised" >&2
fi

case "${HERMES_DASHBOARD:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        enable dashboard ;;
    *)
        echo "[hermes] [anynines] HERMES_DASHBOARD off — dashboard not supervised" >&2 ;;
esac

case "${SSH_ENABLED:-}" in
    1|true|TRUE|True|yes|YES|Yes)
        # CF keeps port 2222 for its own diego-sshd, so default to 22.
        export SSH_PORT="${SSH_PORT:-22}"
        enable sshd ;;
    *)
        echo "[hermes] [anynines] SSH_ENABLED off — sshd not supervised" >&2 ;;
esac

if [ ! -d "$SCANDIR/gateway" ]; then
    echo "[hermes] [anynines] FATAL: gateway service definition not found under $SRC — failing so the platform surfaces the error" >&2
    exit 1
fi

echo "[hermes] [anynines] supervised:$(for d in "$SCANDIR"/*; do [ -d "$d" ] && printf ' %s' "$(basename "$d")"; done)" >&2
echo "[hermes] [anynines] starting s6-svscan (scandir=$SCANDIR)" >&2

# --- supervise --------------------------------------------------------------
# s6-svscan cannot own PID 1 under CF, so it runs as a child and we keep the
# main process slot ourselves. That lets us handle the platform's SIGTERM:
# every service is asked to stop (SIGTERM to longruns) before we exit, instead
# of leaving orphans for the platform to SIGKILL.
s6-svscan "$SCANDIR" &
SVSCAN_PID=$!

stop_all() {
    trap '' TERM INT
    echo "[hermes] [anynines] SIGTERM received — stopping supervised services" >&2
    for d in "$SCANDIR"/*; do
        [ -d "$d" ] || continue
        s6-svc -d "$d" 2>/dev/null || true
    done
    # Give services a moment to exit, then take the supervision tree down.
    i=0
    while [ "$i" -lt 10 ]; do
        alive=0
        for d in "$SCANDIR"/*; do
            [ -d "$d" ] || continue
            s6-svstat -u "$d" >/dev/null 2>&1 && alive=1
        done
        [ "$alive" = 0 ] && break
        i=$((i + 1))
        sleep 1
    done
    s6-svscanctl -t "$SCANDIR" 2>/dev/null || true
    wait "$SVSCAN_PID" 2>/dev/null || true
    echo "[hermes] [anynines] shutdown complete" >&2
    exit 0
}

trap stop_all TERM INT

wait "$SVSCAN_PID" || true
echo "[hermes] [anynines] s6-svscan exited — stopping container" >&2
exit 1
