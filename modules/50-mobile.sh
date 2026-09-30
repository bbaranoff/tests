#!/bin/bash
# process `mobile` et sa VTY (4247 grgsm / 4347 dsp) qui decrit MS 1
MOD_RELANCE_PILE=1
mod_titre() { echo "VTY $MOB_VTY"; }
mod_run() {
    if ! vivant "mobile"; then verdict mobile ECHEC "process mobile absent"; return; fi
    if ! port_ouvert "$MOB_VTY"; then verdict mobile ECHEC "process present mais VTY $MOB_VTY muette"; return; fi
    local ms; ms="$(show_ms)"; printf '%s\n' "$ms" > "$OUT/show-ms-initial.txt"
    if printf '%s' "$ms" | grep -q "MS '1' is"; then verdict mobile OK "VTY $MOB_VTY repond, IMSI ${IMSI:-?}"
    else verdict mobile ECHEC "VTY $MOB_VTY ne decrit pas MS 1"; fi
}
