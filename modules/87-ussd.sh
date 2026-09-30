#!/bin/bash
# USSD *#100# (own-msisdn) et *#101# (own-imsi), routes du HLR : reponse du reseau + compteur MSC « MO NC SS/USSD »
MOD_CHAINE=1
# OPTIONNEL : l'USSD est un service a part (routes du HLR), il ne conditionne
# ni l'appel ni la voix. Son echec est note, il ne saute plus les barreaux
# suivants — sinon toute la couverture TCH restait « NON OBSERVE » a cause
# d'un *#100# sans reponse (run du 2026-09-29 22:37).
MOD_OPTIONNEL=1
mod_titre() { echo "*#100# *#101#, jamais teste avant ce script"; }
# La reponse arrive de facon asynchrone sur la VTY du mobile (« Service
# response: ... ») : on garde la session ouverte plus longtemps que pour une
# commande ordinaire. Preuve double : la reponse doit contenir ce que le HLR
# promet (notre MSISDN, notre IMSI), et le MSC doit compter la requete.
mod_run() {
    local ko="" req_avant est_avant out code attendu
    req_avant="$(msc_ctr "MO NC SS/USSD" 1)"; est_avant="$(msc_ctr "MO NC SS/USSD" 2)"
    : "${req_avant:=0}"; : "${est_avant:=0}"
    for code in "*#100#:${MSISDN}" "*#101#:${IMSI}"; do
        attendu="${code#*:}"; code="${code%%:*}"
        attendre_service 20   # apres la liberation du code precedent, le mobile resynchronise
        out="$( { printf 'enable\nservice 1 %s\n' "$code"; sleep 8; } | timeout --foreground 12 nc 127.0.0.1 "$MOB_VTY" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
        printf '%s\n' "$out" >> "$OUT/ussd-vty.txt"
        if printf '%s' "$out" | grep -q "Service response:.*${attendu:-@@}"; then :
        elif printf '%s' "$out" | grep -q "Service response:"; then ko="$ko $code(reponse sans $attendu)"
        else ko="$ko $code(pas de reponse : $(printf '%s' "$out" | grep -o 'Service request failed[^\n]*' | head -1))"; fi
        sleep 2
    done
    local req est; req="$(msc_ctr "MO NC SS/USSD" 1)"; est="$(msc_ctr "MO NC SS/USSD" 2)"
    [ "${req:-0}" -gt "$req_avant" ] 2>/dev/null || ko="$ko msc(requests $req_avant->$req)"
    [ -z "$ko" ] && verdict ussd OK "*#100# -> $MSISDN, *#101# -> $IMSI, MSC requests $req_avant->$req etablies $est_avant->$est" \
                 || verdict ussd ECHEC "$ko ; MSC requests $req_avant->$req etablies $est_avant->$est"
}
