#!/bin/sh
# ZSHELL_SESSION_HOOK_VERSION=1
[ "$ZSHELL_AUTOMATION" = 1 ] || exit 0
[ -n "$ZSHELL_EXECUTABLE" ] || exit 0
case "$1" in claude|codex) ;; *) exit 0 ;; esac
case "$2" in _session-start|_lifecycle) ;; *) exit 0 ;; esac
exec "$ZSHELL_EXECUTABLE" +agent "$2" "$1"
