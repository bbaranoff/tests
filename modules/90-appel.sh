#!/bin/bash
# « call 1 <dest> » : CC ACTIVE cote mobile ou « MO Calls connect ack » +1 cote MSC, puis hangup
MOD_CHAINE=1
mod_titre() { echo "-> $DEST"; }
mod_run() {
    local setup_avant ack_avant actif=0 cc="" i ack setup
    setup_avant="$(msc_ctr "MO Calls" 1)"; ack_avant="$(msc_ctr "MO Calls" 2)"
    : "${setup_avant:=0}"; : "${ack_avant:=0}"
    attendre_service 20   # pas de RACH pendant la resynchro qui suit la liberation precedente
    vty "$MOB_VTY" "call 1 $DEST" > "$OUT/appel-vty.txt"
    for i in $(seq 1 "$CALL_MAX"); do
        cc="$(cc_state)"; [ "$cc" = ACTIVE ] && { actif=1; break; }
        ack="$(msc_ctr "MO Calls" 2)"
        [ -n "$ack" ] && [ "$ack" -gt "$ack_avant" ] 2>/dev/null && { actif=1; break; }
    done
    [ "$actif" = 1 ] && sleep "$CALL_S"
    show_ms > "$OUT/show-ms-appel.txt"
    vty "$MOB_VTY" "call 1 hangup" >> "$OUT/appel-vty.txt"; sleep 2
    setup="$(msc_ctr "MO Calls" 1)"; ack="$(msc_ctr "MO Calls" 2)"
    if [ "$actif" = 1 ]; then verdict appel OK "CC ${cc:-?} apres ${i}s, MSC setup $setup_avant->$setup, connect-ack $ack_avant->$ack"
    else verdict appel ECHEC "CC « ${cc:-aucune transaction} », MSC setup $setup_avant->$setup, connect-ack $ack_avant->$ack"; fi
}
