#!/bin/sh
# hermes-agent-docker — session environment for interactive shells.
#
# Sourced by:
#   /etc/profile.d/00-hermes-anynines.sh   (login shells, e.g. ssh interactive)
#   /etc/bash.bashrc                       (interactive non-login bash)
#
# Why this is needed: CF's diego-sshd hands ssh sessions a minimal PATH
# (/bin:/usr/bin) and does not pass the application environment, so `hermes`
# and `s6` were not on PATH and HERMES_HOME was unset.
#
# The entrypoint generates /run/hermes-anynines/env.sh at boot with the real
# HERMES_HOME and run mode (it is the only place that knows them). Fall back
# to a sane default when that file is absent — e.g. a runtime that skipped the
# anynines boot path (plain Docker), where the image environment is intact.

if [ -r /run/hermes-anynines/env.sh ]; then
    . /run/hermes-anynines/env.sh
else
    case ":$PATH:" in
        *:/opt/hermes/.venv/bin:*) ;;
        *) PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/command:/opt/hermes/.venv/bin:${PATH}" ;;
    esac
    export PATH
fi
