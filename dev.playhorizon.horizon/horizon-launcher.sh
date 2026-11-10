#!/bin/sh
# The sandbox has its own $XDG_RUNTIME_DIR; only its app/<app-id> folder is shared with the
# host, so the game's control socket goes there for horizon-ctl and its MCP server to reach.
export HORIZON_CONTROL="${HORIZON_CONTROL:-$XDG_RUNTIME_DIR/app/$FLATPAK_ID/horizon-control.sock}"
exec horizon-launcher-bin "$@"
