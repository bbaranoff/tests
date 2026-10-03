#!/bin/bash
# scripts/send-mt-sms.sh (proto-SMSC, SMS-over-GSUP) : MSC « SMS MT delivered » ou sms.txt
MOD_CHAINE=1
mod_titre() { echo "proto-SMSC -> mobile"; }
mod_run() {
    local avant lignes_avant rc recu=0 i v
    avant="$(msc_ctr "SMS MT" 1)"; : "${avant:=0}"
    lignes_avant="$(cat "$SMS_TXT" 2>/dev/null | wc -l)"
    bash "$REPO/scripts/send-mt-sms.sh" "$IMSI" "banc-max MT $STAMP" > "$OUT/sms-mt-envoi.txt" 2>&1; rc=$?
    for i in $(seq 1 "$SMS_MAX"); do
        v="$(msc_ctr "SMS MT" 1)"
        [ -n "$v" ] && [ "$v" -gt "$avant" ] 2>/dev/null && { recu=1; break; }
        tail -n +$((lignes_avant + 1)) "$SMS_TXT" 2>/dev/null | grep -q "banc-max MT $STAMP" && { recu=2; break; }
    done
    tail -n +$((lignes_avant + 1)) "$SMS_TXT" > "$OUT/sms-txt-nouveau.txt" 2>/dev/null
    case "$recu" in
        1) verdict sms-mt OK "MSC delivered $avant -> $v (${i}s)" ;;
        2) verdict sms-mt OK "recu par le mobile (sms.txt, ${i}s)" ;;
        *) verdict sms-mt ECHEC "send-mt rc=$rc, MSC delivered reste a ${v:-?}, rien dans sms.txt" ;;
    esac
}
