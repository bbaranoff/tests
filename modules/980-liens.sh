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

# ── BTS#1 : le side-car qui porte op1-ms2 ───────────────────────────────────
# [2026-10-04] Il est mort EN COURS de campagne (« PC clock skew too high » a
# 00:00:17), entre les paires d'op1-ms1 - toutes OK - et celles d'op1-ms2 -
# toutes « source hors service ». qosmo (59-sidecar-bts.sh) ne le surveille
# qu'au demarrage : personne ne le relancait, et la matrice accusait le mobile.
# Avant chaque paire qui touche op1-ms2 : s'il est mort, on le relance par le
# runner qosmo - meme module, memes essais, meme priorite temps reel - et on
# attend que MS#2 se recale. La relance est ecrite dans la matrice et dans le
# verdict : on mesure les liens, on ne cache pas la panne.
#   BTS1_RELANCES_MAX=2   relances au plus par campagne (0 = jamais)
#   BTS1_RECALE_MAX=120   secondes laissees a MS#2 pour revenir en service
QOSMO_RUN="${QOSMO_RUN:-/opt/GSM/qosmo/run.sh}"
_qosmo_vivant() {   # $1 = module qosmo (son pid dans RUN_DIR), $2 = motif de sa ligne de commande
    local pid; pid="$(cat "$(dirname "$LOGDIR")/$1.pid" 2>/dev/null)"
    tr '\0' ' ' 2>/dev/null < "/proc/${pid:-0}/cmdline" | grep -q -- "$2"
}
# Mort = la chaine du side-car tourne (son fake_trx) mais plus son BTS. Sans
# fake_trx, ce montage n'a pas de side-car : rien a relancer.
_bts1_mort() { _qosmo_vivant sidecar-faketrx fake_trx && ! _qosmo_vivant sidecar-bts osmo-bts-trx; }
_bts1_assure() {   # $1 = indice du point op1-ms2 ; rend 1 si MS#2 reste sans cellule ($BTS1_HS dit pourquoi)
    [ -n "$BTS1_HS" ] && return 1     # deja tente sans succes : on n'insiste pas a chaque paire
    _bts1_mort || return 0
    local raison t0 bon=0 need="${SERVICE_STABLE:-4}"
    # « reason: PC clock skew too high (bts_shutdown_fsm.c:268) », en couleur
    raison="$(sed 's/\x1b\[[0-9;]*m//g' "$LOGDIR/sidecar-bts.log" 2>/dev/null \
        | sed -n 's/.*Shutting down BTS.*reason: //p' | sed 's/ *([^()]*\.c:[0-9]*) *$//' | tail -1)"
    raison="${raison:-cause inconnue}"
    if [ "$BTS1_RELANCES" -ge "${BTS1_RELANCES_MAX:-2}" ]; then
        BTS1_HS="BTS#1 mort ($raison), relances epuisees"; return 1
    fi
    BTS1_RELANCES=$((BTS1_RELANCES + 1)); BTS1_RAISONS="${BTS1_RAISONS:+$BTS1_RAISONS ; }$raison"
    # le module vide sidecar-bts.log en relancant : la mort est gardee d'abord
    tail -n 40 "$LOGDIR/sidecar-bts.log" > "$OUT/liens-bts1-mort-$BTS1_RELANCES.log" 2>/dev/null
    say "BTS#1 mort ($raison) : relance $BTS1_RELANCES/${BTS1_RELANCES_MAX:-2} par qosmo"
    t0=$SECONDS
    # --only : faketrx et bsc sont cites pour que le runner tienne les
    # dependances du BTS#1 pour satisfaites ; leurs propres dependances n'etant
    # pas dans la liste, il les saute sans jamais les relancer (verifie en
    # --dry-run). --force : la mort est constatee ici, sur la ligne de commande,
    # pas sur un pid que le systeme aurait pu recycler.
    ( cd "$(dirname "$QOSMO_RUN")" && NO_COLOR=1 CALYPSO_NO_ATTACH=1 \
        RUN_DIR="$(dirname "$LOGDIR")" LOG_DIR="$LOGDIR" \
        "$QOSMO_RUN" --only sidecar-faketrx,bsc,sidecar-bts --force --no-attach ) >> "$OUT/liens-bts1.log" 2>&1
    if ! _qosmo_vivant sidecar-bts osmo-bts-trx; then
        BTS1_HS="BTS#1 mort ($raison), relance echouee"
    else
        while [ $((SECONDS - t0)) -lt "${BTS1_RECALE_MAX:-120}" ]; do
            if _ep_en_service "$1" 1; then bon=$((bon + 1)); [ "$bon" -ge "$need" ] && break
            else bon=0; sleep 1; fi
        done
        [ "$bon" -ge "$need" ] || BTS1_HS="BTS#1 relance, MS#2 hors service apres ${BTS1_RECALE_MAX:-120}s"
    fi
    if [ -n "$BTS1_HS" ]; then
        say "$BTS1_HS (liens-bts1.log)"
        printf 'BTS#1 : %s\n' "$BTS1_HS" >> "$OUT/liens-matrice.txt"
        return 1
    fi
    say "BTS#1 relance : MS#2 de nouveau en service apres $((SECONDS - t0))s"
    printf 'BTS#1 : mort (%s), relance %s, MS#2 en service apres %ss\n' "$raison" "$BTS1_RELANCES" "$((SECONDS - t0))" >> "$OUT/liens-matrice.txt"
    return 0
}

mod_run() {
    if [ "$MULTI" != 1 ]; then verdict liens SAUTE "sans --multi"; return; fi
    local -a EP_NOM=() EP_CONT=() EP_PORT=() EP_MSISDN=()
    local c p ko="" n_sms=0 ok_sms=0 n_call=0 ok_call=0 i j mat="$OUT/liens-matrice.txt" ss7_ko="" ms2=""
    local BTS1_RELANCES=0 BTS1_RAISONS="" BTS1_HS=""
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
    for i in "${!EP_NOM[@]}"; do [ "${EP_NOM[$i]}" = op1-ms2 ] && ms2="$i"; done
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
            local r_sms r_call="-" bts1=""
            if [ -n "$ms2" ] && { [ "$i" = "$ms2" ] || [ "$j" = "$ms2" ]; }; then
                _bts1_assure "$ms2" || bts1="$BTS1_HS"
            fi
            n_sms=$((n_sms+1))
            if _ep_sms "$i" "$j"; then r_sms=OK; ok_sms=$((ok_sms+1)); else r_sms=ECHEC; ko="$ko sms(${EP_NOM[$i]}>${EP_NOM[$j]})"; fi
            if [ "${LIENS_SMS_ONLY:-0}" != 1 ] && { [ "${LIENS_FULL:-0}" = 1 ] || [ "$i" -lt "$j" ]; }; then
                n_call=$((n_call+1))
                if _ep_appel "$i" "$j"; then r_call="OK($LIEN_CC)"; ok_call=$((ok_call+1)); else r_call="ECHEC($LIEN_CC)"; ko="$ko appel(${EP_NOM[$i]}>${EP_NOM[$j]}:$LIEN_CC)"; fi
            fi
            printf '%-14s -> %-14s %-8s sms=%-6s appel=%s%s\n' "${EP_NOM[$i]}" "${EP_NOM[$j]}" "${EP_MSISDN[$j]}" "$r_sms" "$r_call" "${bts1:+  [$bts1]}" >> "$mat"
            say "${EP_NOM[$i]} -> ${EP_NOM[$j]} : sms $r_sms, appel $r_call${bts1:+ [$bts1]}"
        done
    done
    local res="${#EP_NOM[@]} mobiles, sms $ok_sms/$n_sms, appels $ok_call/$n_call"
    [ "$BTS1_RELANCES" -gt 0 ] && res="$res, BTS#1 relance ${BTS1_RELANCES}x ($BTS1_RAISONS)"
    [ -z "$ko" ] && verdict liens OK "$res (liens-matrice.txt)" || verdict liens ECHEC "$res :$(printf '%s' "$ko" | cut -c1-110) (liens-matrice.txt)"
}
