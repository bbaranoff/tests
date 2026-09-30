#!/bin/bash
# osmo-hlr, osmo-stp, osmo-msc, osmo-bsc, osmo-mgw : process ET VTY joignable
mod_titre() { echo "hlr stp msc bsc mgw"; }
mod_run() {
    local ko="" d p port
    for d in osmo-hlr:4258 osmo-stp:4239 osmo-msc:4254 osmo-bsc:4242 osmo-mgw:4243; do
        p="${d%%:*}"; port="${d##*:}"
        if ! vivant "$p"; then ko="$ko $p(absent)"
        elif ! port_ouvert "$port"; then ko="$ko $p(vty $port muet)"; fi
    done
    [ -z "$ko" ] && verdict coeur OK "process + VTY 4258 4239 4254 4242 4243" || verdict coeur ECHEC "$ko"
}
