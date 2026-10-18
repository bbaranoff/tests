#!/bin/bash
# couche 1 selon le mode : grgsm = qemu+osmocon(+pont) ; dsp = c54x_exe+qemu+osmocon
mod_titre() { echo "$MODE"; }
mod_run() {
    local ko="" info="" p
    for p in "${L1_REQ[@]}";  do vivant "$p" || ko="$ko '$p'"; done
    for p in "${L1_INFO[@]}"; do vivant "$p" && info="$info $(basename "$p")"; done
    [ -n "$info" ] && info="(+$info )"
    pgrep -fa -- "qemu-system-arm|osmocon|c54x_exe|pont|trxcon|fake_trx|grgsm" > "$OUT/couche1-ps.txt" 2>/dev/null
    # fake_trx + trxcon (/tmp/ms2_l2) sont les sidecars BTS#1 / MS#2 que qosmo
    # lance toujours (run_modules 58/67, MOD_REQUIRED) : ils servent ms2/multi,
    # pas le MS de ce run. Le dire, sinon on croit le lien radio hors du DSP.
    local voie="qemu (gr-gsm) + pont.py"; [ "$MODE" = dsp ] && voie="c54x_exe + qemu + pont_dsp.py"
    grep -q "fake_trx\|trxcon" "$OUT/couche1-ps.txt" 2>/dev/null && \
        echo "# note : fake_trx + trxcon (-s /tmp/ms2_l2) = sidecars BTS#1 / MS#2 lances d'office par qosmo (run_modules 58/67) pour les barreaux ms2/multi ; le MS de ce run passe par $voie -> BTS#0" \
        >> "$OUT/couche1-ps.txt"
    [ -z "$ko" ] && verdict couche1 OK "${L1_REQ[*]} $info" || verdict couche1 ECHEC "absent :$ko $info"
}
