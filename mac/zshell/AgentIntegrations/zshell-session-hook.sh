#!/bin/sh
# ZSHELL_SESSION_HOOK_VERSION=1
case "$1" in claude|codex) ;; *) exit 0 ;; esac
case "$2" in _session-start|_lifecycle) ;; *) exit 0 ;; esac
if [ "$ZSHELL_AUTOMATION" = 1 ] && [ -x "$ZSHELL_EXECUTABLE" ]; then
  exec "$ZSHELL_EXECUTABLE" +agent "$2" "$1"
fi
[ "$1" = codex ] || exit 0
# A daemon started outside Zshell has no pane environment or Zshell PATH. The
# managed link still points at the exact bundle that installed this hook.
zshell_hook_source=$0
if [ -L "$zshell_hook_source" ]; then
  zshell_hook_target=$(/usr/bin/readlink "$zshell_hook_source") || exit 0
  case "$zshell_hook_target" in
    /*) zshell_hook_source=$zshell_hook_target ;;
    *) zshell_hook_source=$(/usr/bin/dirname "$zshell_hook_source")/$zshell_hook_target ;;
  esac
fi
case "$zshell_hook_source" in
  *.app/Contents/Resources/*)
    zshell_hook_bin=${zshell_hook_source%/Contents/Resources/*}/Contents/MacOS/zshell
    if [ -x "$zshell_hook_bin" ]; then
      exec "$zshell_hook_bin" +agent "$2" "$1"
    fi
    ;;
esac
zshell_hook_bin=$(command -v zshell) || exit 0
exec "$zshell_hook_bin" +agent "$2" "$1"
