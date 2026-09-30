#!/bin/bash
# --multi : hub inter-STP + conteneurs op2/op3 (lances par le demarrage), ss7_check, SMS et appel op1 -> op2 (100201)
MOD_CHAINE=1; MOD_OPTIONNEL=1
mod_titre() { echo "inter-operateur SS7"; }
# Le plan de numerotation du banc multi : MSISDN <noeud>00<op><ms>, donc
# l'abonne 1 de l'operateur 2 est 100201 (osmo_msisdn dans start.sh).
mod_run() {
    if [ "$MULTI" != 1 ]; then verdict multi SAUTE "sans --multi"; return; fi
    # Le banc multi est lance par 00-demarrage.sh (avec --restart) ou deja debout
    # (sans) : ici on ne lance rien, on constate.
    local hub="${MULTI_HUB_NAME:-osmo-inter-stp}" op2=osmo-operator-2 ko="" i
    docker ps --format '{{.Names}} {{.Status}}' > "$OUT/multi-docker-ps.txt" 2>/dev/null
    docker ps --format '{{.Names}}' | grep -qx "$hub" || ko="$ko hub($hub absent)"
    docker ps --format '{{.Names}}' | grep -qx "$op2" || ko="$ko $op2(absent)"
    if [ -n "$ko" ]; then verdict multi ECHEC "$ko (voir start-multi.log)"; return; fi
    # Le verdict SS7 vient du check du depot, pas d'une seconde lecture ici.
    ( cd "$REPO" && NO_COLOR=1 ./checks/ss7_check.sh --quick ) > "$OUT/multi-ss7_check.txt" 2>&1
    [ $? -eq 0 ] || ko="$ko ss7_check($(grep -c 'FAIL\|✗' "$OUT/multi-ss7_check.txt") echecs)"
    # SMS op1 -> op2 : le MSC natif compte le SUBMIT, celui de l'op 2 la remise.
    local dest=100201 mo_avant mt_avant mt v
    mo_avant="$(msc_ctr "SMS MO" 1)"; : "${mo_avant:=0}"
    mt_avant="$(msc_ctr "SMS MT" 1 "$op2")"; : "${mt_avant:=0}"
    vty "$MOB_VTY" "sms 1 $dest banc-max interop $STAMP" > "$OUT/multi-sms-vty.txt"
    attend_ctr "SMS MO" 1 "$mo_avant" "$SMS_MAX" >/dev/null || ko="$ko sms-mo(non soumis au MSC op1)"
    mt="$(attend_ctr "SMS MT" 1 "$mt_avant" "$SMS_MAX" "$op2")" || ko="$ko sms-mt-op2(delivered reste a $mt)"
    # Appel op1 -> op2 : on tient pour atteint un CC qui depasse l'initiation
    # (CALL_DELIVERED = l'op 2 fait sonner son abonne), personne ne decroche.
    local cc="" ok=0
    vty "$MOB_VTY" "call 1 $dest" > "$OUT/multi-appel-vty.txt"
    for i in $(seq 1 "$CALL_MAX"); do
        cc="$(cc_state)"
        case "$cc" in CALL_DELIVERED|ACTIVE|CONNECT_REQUEST) ok=1; break ;; esac
        sleep 1
    done
    vty "$MOB_VTY" "call 1 hangup" >> "$OUT/multi-appel-vty.txt"; sleep 2
    [ "$ok" = 1 ] || ko="$ko appel(CC ${cc:-aucune})"
    [ -z "$ko" ] && verdict multi OK "hub + op2, ss7_check, SMS et appel op1 -> $dest (CC $cc)" || verdict multi ECHEC "$ko"
}
