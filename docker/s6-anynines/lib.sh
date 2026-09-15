#!/bin/sh
# shellcheck shell=sh
# Shared helpers for the anynines s6 service definitions.
# This file is sourced (not executed) by docker/s6-anynines/service/*/run.

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|True|yes|YES|Yes|on|ON) return 0 ;;
    esac
    return 1
}

# Root mode — run the hermes processes as root instead of dropping to the
# 'hermes' user.
#
#   HERMES_ANYNINES_RUN_AS_ROOT=1   image-level switch (documented one)
#   HERMES_ALLOW_ROOT_GATEWAY=1     upstream switch, also accepted here since
#                                   hermes itself requires it when euid == 0
#
# Only meaningful when the container actually starts as root (always the case
# in the CF fallback). Root mode requires HERMES_HOME to point somewhere root
# can write — e.g. /root/.hermes; /root is 0700 root, so the hermes user
# (uid 10000) cannot write there.
root_mode() {
    [ "$(id -u)" = 0 ] || return 1
    is_truthy "${HERMES_ANYNINES_RUN_AS_ROOT:-}" && return 0
    is_truthy "${HERMES_ALLOW_ROOT_GATEWAY:-}" && return 0
    return 1
}

# State directory used by the supervised processes.
state_dir() {
    printf '%s' "${HERMES_HOME:-/opt/data}"
}
