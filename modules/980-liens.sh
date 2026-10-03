#!/bin/bash
# --multi : tous les liens entre mobiles du banc (op1 natif, MS#2, op2, op3) : SMS et appel sur chaque paire, ASP inter-STP de chaque operateur
MOD_CHAINE=1; MOD_OPTIONNEL=1
# 6 mobiles = 30 paires pour le SMS, 15 pour l'appel : bien plus que les 240 s
# par defaut d'un barreau.
MOD_TIMEOUT="${LIENS_TIMEOUT:-2400}"
mod_titre() { echo "liens multi-operateur (SMS + appel, toutes les paires)"; }
# Un « point » est un mobile joignable par sa VTY : sur l'hote (MS#1 du mode,
# MS#2 du profil hybride) ou dans un conteneur operateur (un faketrx en 4248 et
# un QEMU Calypso en 4347, chacun avec son propre abonne). Son MSISDN vient du
# MSC de SON operateur : l'IMSI est lue dans la conf que le process de ce port
# a ouverte, pas devinee.
#   LIENS_FULL=1   l'appel est joue dans les DEUX sens (defaut : une paire = un appel)
#   LIENS_SMS_ONLY=1   pas d'appel (rapide)

_ep_vty() {   # $1 = indice du point, $2 = commande VTY mobile
    if [ -z "${EP_CONT[$1]}" ]; then vty "${EP_PORT[$1]}" "$2"; else vty_in "${EP_CONT[$1]}" "${EP_PORT[$1]}" "$2"; fi
}
_ep_en_service() {   # $1 = indice, [$2 = delai max s]
    local i ms
    for i in $(seq 1 "${2:-20}"); do
        ms="$(_ep_vty "$1" "show ms 1")"
        printf '%s' "$ms" | grep -q 'C3 camped normally' && printf '%s' "$ms" | grep -q 'MM idle, normal service' && return 0
    done
    return 1
}
_ep_sms_recu() {   # $1 = indice, $2 = jeton
    if [ -z "${EP_CONT[$1]}" ]; then grep -qF -- "$2" "$SMS_TXT" 2>/dev/null
    else docker exec "${EP_CONT[$1]}" grep -qF -- "$2" /root/.osmocom/bb/sms.txt 2>/dev/null; fi
}
# IMSI du mobile qui ecoute sur ce port : sa ligne de commande donne la conf (-c).
_ep_imsi() {   # $1 = conteneur ("" = hote), $2 = port
    local cfg
    if [ -z "$1" ]; then
        cfg="$(ss -ltnp 2>/dev/null | grep -E "127.0.0.1:$2 " | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
        cfg="$(tr '\0' ' ' < "/proc/${cfg:-0}/cmdline" 2>/dev/null | sed -n 's/.* -c \([^ ]*\).*/\1/p')"
        [ -f "$cfg" ] && sed -n 's/^ *imsi \([0-9]\{15\}\).*/\1/p' "$cfg" | head -1
    else
        docker exec "$1" bash -c "pid=\$(ss -ltnp 2>/dev/null | grep -E '127.0.0.1:$2 ' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
            cfg=\$(tr '\\0' ' ' < /proc/\${pid:-0}/cmdline 2>/dev/null | sed -n 's/.* -c \\([^ ]*\\).*/\\1/p')
            [ -f \"\$cfg\" ] && sed -n 's/^ *imsi \\([0-9]\\{15\\}\\).*/\\1/p' \"\$cfg\" | head -1" 2>/dev/null
    fi
}
_ep_ajoute() {   # $1 = etiquette, $2 = conteneur, $3 = port
    local imsi msisdn n="${#EP_NOM[@]}"
    imsi="$(_ep_imsi "$2" "$3")"
    if [ -z "$2" ]; then msisdn="$(vty "$MSC_VTY" "show subscriber imsi ${imsi:-0}" | sed -n 's/^ *MSISDN: *\([0-9]*\).*/\1/p' | head -1)"
    else msisdn="$(vty_in "$2" "$MSC_VTY" "show subscriber imsi ${imsi:-0}" | sed -n 's/^ *MSISDN: *\([0-9]*\).*/\1/p' | head -1)"; fi
    if [ -z "$msisdn" ]; then say "point $1 ignore : pas de MSISDN (IMSI ${imsi:-?})"; return; fi
    EP_NOM[$n]="$1"; EP_CONT[$n]="$2"; EP_PORT[$n]="$3"; EP_MSISDN[$n]="$msisdn"
    say "point $1 : MSISDN $msisdn (VTY ${2:-hote}:$3)"
}
_ep_sms() {   # $1 = source, $2 = destination ; rend 0 si le texte est arrive
    local tok="lien-$STAMP-$1-$2" k
    _ep_en_service "$1" || return 2
    _ep_vty "$1" "sms 1 ${EP_MSISDN[$2]} $tok" >> "$OUT/liens-vty.txt"
    for k in $(seq 1 "$SMS_MAX"); do _ep_sms_recu "$2" "$tok" && return 0; sleep 1; done
    return 1
}
# Appel : on decroche cote destination des que sa RR sort d'idle. Rend 0 et
# ecrit l'etat atteint dans $LIEN_CC ; ACTIVE = voix etablie, CALL_DELIVERED /
# CONNECT_REQUEST = la destination sonne (comme 97-multi.sh).
_ep_appel() {   # $1 = source, $2 = destination
    local k out cc="" ok=1
    LIEN_CC=""
    _ep_en_service "$1" || { LIEN_CC="source hors service"; return 1; }
    _ep_en_service "$2" || { LIEN_CC="destination hors service"; return 1; }
    for k in 1 2; do
        out="$(_ep_vty "$1" "call 1 ${EP_MSISDN[$2]}")"; printf '%s\n' "$out" >> "$OUT/liens-vty.txt"
        printf '%s' "$out" | grep -q 'rejected\|No service\|released' || break
        _ep_en_service "$1" 20 || break
    done
    for k in $(seq 1 "$CALL_MAX"); do
        _ep_vty "$2" "show ms 1" | grep -q "radio resource layer state: idle" || _ep_vty "$2" "call 1 answer" >> "$OUT/liens-vty.txt"
        cc="$(_ep_vty "$1" "show ms 1" | sed -n 's/^ *call control state: //p' | sed -n 1p)"
        case "$cc" in ACTIVE) ok=0; break ;; CALL_DELIVERED|CONNECT_REQUEST) ok=0 ;; esac
        sleep 1
    done
    LIEN_CC="${cc:-aucune}"
    [ "$LIEN_CC" = ACTIVE ] && sleep 2
    _ep_vty "$1" "call 1 hangup" >> "$OUT/liens-vty.txt"; sleep 3
    return $ok
}

mod_run() {
    if [ "$MULTI" != 1 ]; then verdict liens SAUTE "sans --multi"; return; fi
    local -a EP_NOM=() EP_CONT=() EP_PORT=() EP_MSISDN=()
    local c p ko="" n_sms=0 ok_sms=0 n_call=0 ok_call=0 i j mat="$OUT/liens-matrice.txt" ss7_ko=""
    : > "$OUT/liens-vty.txt"; : > "$mat"
    # ── les points ──
    _ep_ajoute "op1-ms1" "" "$MOB_VTY"
    port_ouvert "$MS2_VTY" && _ep_ajoute "op1-ms2" "" "$MS2_VTY"
    for c in $(docker ps --format '{{.Names}}' | grep -E '^osmo-operator-[0-9]+$' | sort -V); do
        for p in 4248 4347; do
            [ -n "$(vty_in "$c" "$p" "show ms 1" | grep -a 'is up')" ] && _ep_ajoute "${c#osmo-operator-}-ms:$p" "$c" "$p"
        done
    done
    # nom lisible : « op2-ms:4248 »
    for i in "${!EP_NOM[@]}"; do case "${EP_NOM[$i]}" in op*) ;; *) EP_NOM[$i]="op${EP_NOM[$i]}" ;; esac; done
    if [ "${#EP_NOM[@]}" -lt 2 ]; then verdict liens ECHEC "moins de 2 mobiles joignables (${#EP_NOM[@]})"; return; fi
    # ── le SS7 de chaque operateur : l'ASP vers le hub doit etre ACTIVE ──
    local asp
    asp="$(vty 4239 "show cs7 instance 0 asp" | grep -a 'asp-to-inter' | sed -n 1p)"
    printf '%s' "$asp" | grep -q ASP_ACTIVE || ss7_ko="$ss7_ko op1"
    for c in $(docker ps --format '{{.Names}}' | grep -E '^osmo-operator-[0-9]+$' | sort -V); do
        asp="$(vty_in "$c" 4239 "show cs7 instance 0 asp" | grep -a 'asp-to-inter' | sed -n 1p)"
        printf '%s' "$asp" | grep -q ASP_ACTIVE || ss7_ko="$ss7_ko ${c#osmo-}"
    done
    if [ -n "$ss7_ko" ]; then printf 'SS7 asp-to-inter : HS :%s\n' "$ss7_ko" >> "$mat"; else echo 'SS7 asp-to-inter : tous ACTIVE' >> "$mat"; fi
    [ -z "$ss7_ko" ] || ko="$ko asp-inter($ss7_ko)"
    # ── les liens ──
    for i in "${!EP_NOM[@]}"; do
        for j in "${!EP_NOM[@]}"; do
            [ "$i" = "$j" ] && continue
            local r_sms r_call="-"
            n_sms=$((n_sms+1))
            if _ep_sms "$i" "$j"; then r_sms=OK; ok_sms=$((ok_sms+1)); else r_sms=ECHEC; ko="$ko sms(${EP_NOM[$i]}>${EP_NOM[$j]})"; fi
            if [ "${LIENS_SMS_ONLY:-0}" != 1 ] && { [ "${LIENS_FULL:-0}" = 1 ] || [ "$i" -lt "$j" ]; }; then
                n_call=$((n_call+1))
                if _ep_appel "$i" "$j"; then r_call="OK($LIEN_CC)"; ok_call=$((ok_call+1)); else r_call="ECHEC($LIEN_CC)"; ko="$ko appel(${EP_NOM[$i]}>${EP_NOM[$j]}:$LIEN_CC)"; fi
            fi
            printf '%-14s -> %-14s %-8s sms=%-6s appel=%s\n' "${EP_NOM[$i]}" "${EP_NOM[$j]}" "${EP_MSISDN[$j]}" "$r_sms" "$r_call" >> "$mat"
            say "${EP_NOM[$i]} -> ${EP_NOM[$j]} : sms $r_sms, appel $r_call"
        done
    done
    local res="${#EP_NOM[@]} mobiles, sms $ok_sms/$n_sms, appels $ok_call/$n_call"
    [ -z "$ko" ] && verdict liens OK "$res (liens-matrice.txt)" || verdict liens ECHEC "$res :$(printf '%s' "$ko" | cut -c1-110) (liens-matrice.txt)"
}
