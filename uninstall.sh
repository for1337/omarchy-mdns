#!/usr/bin/env bash
# uninstall.sh — remove leo.mdns from the current user.
#
# Removes the symlink at ~/.config/omarchy/plugins/leo.mdns/ and (if jq is
# available) the plugin entry from ~/.config/omarchy/shell.json. Does NOT
# touch the device cache at ~/.local/state/omarchy/mdns-devices.json —
# pass --purge to delete that too.
#
# Run after this:
#     omarchy restart shell

set -euo pipefail

PLUGIN_ID="leo.mdns"
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
STATE_JSON="$HOME/.local/state/omarchy/mdns-devices.json"

purge=""
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) purge=1 ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 64
      ;;
  esac
  shift
done

# 1. Symlink ---------------------------------------------------------------
if [ -L "$PLUGIN_DST" ]; then
  rm "$PLUGIN_DST"
  echo "ok: removed symlink $PLUGIN_DST"
elif [ -e "$PLUGIN_DST" ]; then
  echo "warning: $PLUGIN_DST exists but is not a symlink — left in place." >&2
  echo "         Remove it manually if you want a full uninstall." >&2
else
  echo "ok: no symlink at $PLUGIN_DST (already uninstalled)"
fi

# 2. shell.json entry ------------------------------------------------------
if [ -f "$SHELL_JSON" ] && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg id "$PLUGIN_ID" '
    .plugins = (.plugins // [] | map(select(.id != $id)))
  ' "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"
  echo "ok: removed '$PLUGIN_ID' from $SHELL_JSON"
else
  echo "note: $SHELL_JSON or 'jq' not available — edit by hand to drop the entry."
fi

# 3. Cache -----------------------------------------------------------------
if [ "$purge" = "1" ] && [ -e "$STATE_JSON" ]; then
  rm "$STATE_JSON"
  echo "ok: deleted $STATE_JSON"
elif [ -e "$STATE_JSON" ]; then
  echo "note: device cache left in place at $STATE_JSON (pass --purge to delete)"
fi

cat <<EOF

Run:
  omarchy restart shell
EOF