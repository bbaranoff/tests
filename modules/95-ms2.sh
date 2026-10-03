#!/bin/bash
# si un MS#2 ecoute en 4248 (profil hybride) : SMS et appel MS#1 -> MS#2
MOD_CHAINE=1; MOD_OPTIONNEL=1
mod_titre() { echo "VTY $MS2_VTY"; }
mod_run() {
    if ! port_ouvert "$MS2_VTY"; then verdict ms2 SAUTE "pas de MS#2 en $MS2_VTY dans ce montage"; return; fi
    local ms2 imsi2 msisdn2 ko="" lignes_avant ok i cc
    ms2="$(vty "$MS2_VTY" "show ms 1")"; printf '%s\n' "$ms2" > "$OUT/show-ms2.txt"
    if ! printf '%s' "$ms2" | grep -q "C3 camped normally"; then verdict ms2 ECHEC "MS#2 present mais pas campe"; return; fi
    imsi2="$(sed -n 's/^ *imsi \([0-9]\{15\}\).*/\1/p' /root/.osmocom/bb/mobile_faketrx_bts1.cfg 2>/dev/null | head -1)"
    msisdn2="$(vty "$MSC_VTY" "show subscriber imsi ${imsi2:-0}" | sed -n 's/^ *MSISDN: *\([0-9]*\).*/\1/p' | head -1)"
    if [ -z "$msisdn2" ]; then verdict ms2 ECHEC "MS#2 (IMSI ${imsi2:-?}) sans MSISDN au MSC"; return; fi
    # SMS MS#1 -> MS#2 : les deux mobiles ecrivent dans le meme sms.txt.
    lignes_avant="$(cat "$SMS_TXT" 2>/dev/null | wc -l)"
    vty "$MOB_VTY" "sms 1 $msisdn2 banc-max MS1-MS2 $STAMP" > "$OUT/ms2-sms-vty.txt"
    ok=0
    for i in $(seq 1 "$SMS_MAX"); do
        tail -n +$((lignes_avant + 1)) "$SMS_TXT" 2>/dev/null | grep -q "MS1-MS2 $STAMP" && { ok=1; break; }; sleep 1
    done
    [ "$ok" = 1 ] || ko="$ko sms(MS#2 n'a rien recu)"
    # Appel MS#1 -> MS#2, decroche par la VTY de MS#2 des que sa RR sort d'idle.
    # [2026-10-03] « appel(CC aucune) » : l'appel partait juste apres le SMS, MS#1
    # encore sur son canal (ou en resynchro), et la VTY repondait aussitot
    # « Call has been released » sans RACH : le MSC n'a jamais vu de SETUP. On
    # attend les DEUX mobiles en service, puis appeler() reessaie sur rejet immediat.
    : > "$OUT/ms2-appel-vty.txt"
    for i in $(seq 1 20); do
        vty "$MS2_VTY" "show ms 1" | grep -q 'MM idle, normal service' && break; sleep 1
    done
    sleep 2
    appeler "$msisdn2" "$OUT/ms2-appel-vty.txt" 3 || say "appel MS#1 -> MS#2 rejete a chaque essai"
    ok=0
    for i in $(seq 1 "$CALL_MAX"); do
        vty "$MS2_VTY" "show ms 1" | grep -q "radio resource layer state: idle" || vty "$MS2_VTY" "call 1 answer" >> "$OUT/ms2-appel-vty.txt"
        cc="$(cc_state)"; [ "$cc" = ACTIVE ] && { ok=1; break; }; sleep 1
    done
    [ "$ok" = 1 ] && sleep "$CALL_S"
    vty "$MOB_VTY" "call 1 hangup" >> "$OUT/ms2-appel-vty.txt"; sleep 2
    [ "$ok" = 1 ] || ko="$ko appel(CC ${cc:-aucune})"
    [ -z "$ko" ] && verdict ms2 OK "SMS et appel MS#1 -> $msisdn2" || verdict ms2 ECHEC "$ko"
}
