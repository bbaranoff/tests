#!/bin/bash
# osmo-bts-* en vie, VTY 4241
mod_titre() { echo "osmo-bts"; }
mod_run() {
    if ! vivant "osmo-bts-"; then verdict bts ECHEC "aucun osmo-bts-*"; return; fi
    local bts; bts="$(pgrep -fa -- "osmo-bts-" | grep -o 'osmo-bts-[a-z]*' | head -1)"
    port_ouvert 4241 && verdict bts OK "$bts, VTY 4241" || verdict bts ECHEC "$bts sans VTY 4241"
}
