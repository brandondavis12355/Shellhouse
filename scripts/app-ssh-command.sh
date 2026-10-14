#!/bin/sh
# The only commands the Shellhouse app's own SSH key may run on this host. initial_setup.sh authorizes that key with
#   restrict,port-forwarding,command="~/shellhouse/scripts/app-ssh-command.sh"
# so it can forward ports (the sandbox manager's socket, the bots' desktops) and run only what's below: the
# connection test (`hostname`) and the read-only resource stats in Settings. Anything else is refused, and it gets
# no shell, no pty, and no agent or X11 forwarding. A stolen copy of the app's key can't open a shell here.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
case "$SSH_ORIGINAL_COMMAND" in
  hostname)
    exec hostname ;;
  "cat /proc/loadavg"*)
    # Settings › Resource stats; the app's request is matched by how it starts, and this fixed script answers it.
    cat /proc/loadavg; echo ---; nproc; echo ---; free -b; echo ---; df -BG /
    exit 0 ;;
  *)
    echo "Shellhouse's app key may only forward the sandbox ports and run its status checks." >&2
    exit 1 ;;
esac
