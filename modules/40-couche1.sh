#!/bin/bash
# couche 1 selon le mode : grgsm = qemu+osmocon(+pont) ; dsp = c54x_exe+qemu+osmocon
mod_titre() { echo "$MODE"; }
mod_run() {
    local ko="" info="" p
    for p in "${L1_REQ[@]}";  do vivant "$p" || ko="$ko '$p'"; done
    for p in "${L1_INFO[@]}"; do vivant "$p" && info="$info $(basename "$p")"; done
    [ -n "$info" ] && info="(+$info )"
    pgrep -fa -- "qemu-system-arm|osmocon|c54x_exe|pont|trxcon|fake_trx|grgsm" > "$OUT/couche1-ps.txt" 2>/dev/null
    [ -z "$ko" ] && verdict couche1 OK "${L1_REQ[*]} $info" || verdict couche1 ECHEC "absent :$ko $info"
}
