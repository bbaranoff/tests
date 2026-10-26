#!/bin/bash
# _lib.sh — ce que tous les barreaux partagent : le mode, la VTY, les
# compteurs, le tableau. Charge par banc-max.sh, jamais lance seul.
REPO="${OSMO_REPO:-/opt/GSM/osmo-operator}"
MODE="${MODE:-}"; RESTART=0; MULTI=0; LEGACY=0; CONTINUE=0; STOP_AFTER=0; REBUILD=0; LTE=0; MS2=0; DATA=0
# [2026-10-26] Magnetite (modes bts, bts-classique, ms-magnetite) : le telephone est le vrai firmware TI,
# sans VTY mobile. MOB_CLAVIER=1 bascule les barreaux sur le clavier (socket de calypso_armio.c) et sur
# les preuves cote reseau (VLR, compteurs MSC). START_OPT est un tableau : ces montages passent
# plusieurs options a start-native.sh. APPEL_ACK_AVANT : reference de cc_state() (voir appeler).
MOB_CLAVIER=0; MOB_KEYS_SOCK=""; MOB_RUNDIR=""; START_OPT=(); APPEL_ACK_AVANT=""
ESSAIS=2; RELANCES=1; RELANCES_FAITES=0
DEST=600; BOOT_MAX=180; ATTACH_MAX=60; SMS_MAX=30; CALL_MAX=25; CALL_S=6
MS2_VTY=4248; MSC_VTY=4254
# Journaux du montage grgsm : qosmo ecrit sous /run/user/<uid>/osmo-nitb/logs,
# et l'uid est celui de la SESSION (1001 sur ce poste), pas root. On prend le
# plus recent des dossiers qui existent.
LOGDIR="$(ls -dt /run/user/*/osmo-nitb/logs 2>/dev/null | head -1)"; : "${LOGDIR:=/run/user/0/osmo-nitb/logs}"
DSPDIR=/tmp/c54x-pont                 # journaux du montage dsp (c54x_exe/run.sh)
PONT_LOG=/dev/shm/pont.log            # le pont, dans les deux montages
SMS_TXT=/root/.osmocom/bb/sms.txt
NOMS=(); declare -A VERD DET; CHAINE_OK=1; ECHECS=0
IMSI=""; MSISDN=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; B=$'\e[1m'; Z=$'\e[0m'
else G=""; R=""; Y=""; D=""; B=""; Z=""; fi
say()   { printf '  %s\n' "$*"; }
head_() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z"; }
mod_nom() { basename "$1" .sh | sed 's/^[0-9]*-//'; }
liste_contient() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }

# ── VTY : une commande, une reponse ─────────────────────────────────────────
# `enable` puis la commande, une seconde de silence pour que nc lise la
# reponse avant de fermer (sans elle, la commande part et rien ne revient).
# Couleurs et \r retires : les verdicts sont des grep.
# [2026-09-30] nc -N : netcat OpenBSD ne ferme pas la connexion a la fin de son
# entree, il attend que le serveur ferme -- la VTY ne ferme jamais -- et chaque
# lecture durait les 6 s du timeout (mesure : 6,0 s sans -N, 1,0 s avec, meme
# reponse complete). Toutes les boucles du banc (attente de service, boucle
# d'appel, sondes) en etaient six fois plus lentes : c'etait le « ca hang ».
vty() {   # $1 = port, $2 = commande
    { printf 'enable\n%s\n' "$2"; sleep 1; } | timeout --foreground 6 nc -N 127.0.0.1 "$1" 2>/dev/null \
        | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
}
# Lancer un appel et reessayer aussitot si la VTY le rejette sur-le-champ (mobile
# en resélection : « Call has been rejected », « No service ») : au plus $3 essais
# espaces d'une attente de service. Ecrit la sortie VTY dans $2. Rend 0 si la
# commande est partie sans rejet immediat.
appeler() {   # $1 = destination, $2 = fichier de sortie VTY, [$3 = essais, defaut 3]
    local k out
    # [2026-10-26] La reference de cc_state() en Magnetite : le connect-ack du MSC d'avant l'appel.
    APPEL_ACK_AVANT="$(msc_ctr "MO Calls" 2)"; : "${APPEL_ACK_AVANT:=0}"
    if [ "$MOB_CLAVIER" = 1 ]; then
        # Magnetite : pas de VTY. On compose au clavier du C139 (les chiffres puis la verte) et la
        # preuve que l'appel est parti est le compteur « MO Calls setup » du MSC, lu en delta.
        local setup_avant
        for k in $(seq 1 "${3:-3}"); do
            attendre_service 20
            setup_avant="$(msc_ctr "MO Calls" 1)"; : "${setup_avant:=0}"
            clavier_composer "$1" >> "$2"
            attend_ctr "MO Calls" 1 "$setup_avant" 8 >/dev/null && return 0
            say "appel au clavier : aucun SETUP vu par le MSC (essai $k) ; raccrochage, nouvel essai"
            raccrocher >> "$2"; sleep 2
        done
        return 1
    fi
    for k in $(seq 1 "${3:-3}"); do
        attendre_service 20
        out="$( { printf 'enable\ncall 1 %s\n' "$1"; sleep 2; } | timeout --foreground 6 nc -N 127.0.0.1 "$MOB_VTY" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
        printf '%s\n' "$out" >> "$2"
        printf '%s' "$out" | grep -q 'rejected\|No service\|released' || return 0
        say "appel rejete sur-le-champ (essai $k) : $(printf '%s' "$out" | grep -o '% Call[^%]*\|% No service' | head -1 | tr -d '\n')"
        sleep 2
    done
    return 1
}
# La meme chose DANS un conteneur (operateurs 2, 3, hub) : nc n'y est pas
# forcement, /dev/tcp de bash y est toujours.
vty_in() {   # $1 = conteneur, $2 = port, $3 = commande
    docker exec "$1" bash -c "exec 9<>/dev/tcp/127.0.0.1/$2 || exit 1
        { printf 'enable\n%s\n' '$3'; sleep 1; } >&9; timeout --foreground 4 cat <&9" 2>/dev/null \
        | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
}
port_ouvert() { timeout --foreground 2 bash -c "echo >/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
vivant()      { pgrep -f -- "$1" >/dev/null 2>&1; }

# ── Le clavier du telephone emule (Magnetite, pas de VTY) ───────────────────
# qosmo calypso_armio.c ecoute un socket Unix datagramme (CALYPSO_KEYS_SOCK : /tmp/calypso_keys.sock
# en instance 1, /tmp/calypso_keys2.sock en instance 2) : « press T », « release T », « tap T [ms] ».
# Touches : 0-9 star hash ok (la verte, a gauche) power (la rouge, a droite : appui court = fin
# d'appel, appui long = extinction) menu lsb rsb up down left right. Le meme socket que la fenetre
# tools/osmo-c123-gtk.py --modele c139. Chaque appui est journalise sur la sortie (a rediriger).
clavier() {   # $1 = touche, [$2 = duree ms, defaut 120]
    local sock="$MOB_KEYS_SOCK"
    [ -S "$sock" ] || { say "clavier : socket $sock absent"; return 1; }
    printf 'tap %s %s\n' "$1" "${2:-120}" | socat - "UNIX-SENDTO:$sock" 2>/dev/null || return 1
    printf '%s tap %s %s\n' "$(date +%T)" "$1" "${2:-120}"
    sleep "${MAGNETITE_TOUCHE_PAUSE:-0.25}"
}
clavier_sequence() {   # $1 = touches separees par des espaces (ex. "menu down ok 1 0 0 1 0 2 ok")
    local t; for t in $1; do clavier "$t" || return 1; done
}
clavier_composer() {   # $1 = numero : les chiffres, puis la touche verte (MAGNETITE_TOUCHE_ENVOI, defaut ok)
    local c
    for c in $(printf '%s' "$1" | sed 's/./& /g'); do
        case "$c" in '*') c=star ;; '#') c=hash ;; esac
        clavier "$c" || return 1
    done
    clavier "${MAGNETITE_TOUCHE_ENVOI:-ok}"
}
raccrocher() {   # Magnetite : touche rouge, appui court ; sinon la VTY du mobile
    if [ "$MOB_CLAVIER" = 1 ]; then clavier "${MAGNETITE_TOUCHE_FIN:-power}" "${MAGNETITE_FIN_MS:-150}"; return; fi
    vty "$MOB_VTY" "call 1 hangup"
}

# Compteur MSC : la valeur d'un champ de « show statistics », lue a l'instant.
#   msc_ctr "SMS MO" 1     -> submitted      msc_ctr "MO Calls" 2 -> connect ack
msc_ctr() {   # $1 motif de ligne, $2 rang du nombre, [$3 conteneur]
    local out
    if [ -n "${3:-}" ]; then out="$(vty_in "$3" "$MSC_VTY" "show statistics")"
    else out="$(vty "$MSC_VTY" "show statistics")"; fi
    printf '%s\n' "$out" | grep -a "^$1" | grep -ao '[0-9]\+' | sed -n "${2}p"
}
attend_ctr() {   # $1 motif, $2 rang, $3 valeur avant, $4 delai, [$5 conteneur]
    local i v
    for i in $(seq 1 "$4"); do
        v="$(msc_ctr "$1" "$2" "${5:-}")"
        [ -n "$v" ] && [ "$v" -gt "$3" ] 2>/dev/null && { echo "$v"; return 0; }
    done
    echo "${v:-?}"; return 1
}
show_ms() { [ "$MOB_CLAVIER" = 1 ] && return 0; vty "$MOB_VTY" "show ms 1"; }
# cc_state : l'etat CC du mobile. En Magnetite (pas de VTY) l'appel est ACTIVE quand le MSC compte
# un « MO Calls connect ack » de plus que la reference prise par appeler() : la verite vient du reseau.
cc_state() {
    if [ "$MOB_CLAVIER" = 1 ]; then
        local a; a="$(msc_ctr "MO Calls" 2)"
        [ -n "$a" ] && [ -n "$APPEL_ACK_AVANT" ] && [ "$a" -gt "$APPEL_ACK_AVANT" ] 2>/dev/null && echo ACTIVE
        return 0
    fi
    show_ms | sed -n 's/^ *call control state: //p' | head -1
}
# Attendre que le mobile soit campe ET en service (C3 + « MM idle, normal
# service »), au plus $1 s (defaut 20). POURQUOI : apres chaque liberation de
# canal, le mobile refait une synchro FB+SB ; quand elle echoue (mode dsp : une
# fois sur deux le 2026-09-30), il passe 3 a 10 s sans cellule, et tout RACH
# lance pendant ce trou meurt en « LOS during RACH request ». C'est ce qui
# faisait passer l'USSD, le SMS ou l'appel une fois sur deux : le barreau
# tirait pendant la resynchro. On attend le service, on ne mesure pas notre
# impatience. Rend 0 si en service, 1 sinon (le barreau decide).
attendre_service() {   # [$1 = delai max en s]
    # [2026-10-03] « EN SERVICE » NE SUFFIT PAS : STABLE. En mode dsp le mobile peut
    # apparaitre campe et en service pendant une trame puis perdre la cellule (la
    # fenetre SB n'est armee que rarement : « FBSB RESP: result=255 », « no cell
    # available ») ; un RACH tire dans ce trou meurt en « LOS during RACH request »
    # et le SMS est « rejected ». On exige donc SERVICE_STABLE lectures consecutives
    # (defaut 4, ~1 s chacune) en service avant de rendre la main ; une rechute
    # remet le compteur a zero. Le delai max ($1) borne le tout.
    local ms bon=0 need="${SERVICE_STABLE:-4}" debut=$SECONDS max="${1:-20}" depuis=0
    if [ "$MOB_CLAVIER" = 1 ]; then
        # [2026-10-26] Magnetite : pas de « show ms ». « En service » se lit au VLR : l'IMSI est dans
        # le cache d'abonnes du MSC et n'est pas detachee. Pas de notion de stabilite ici.
        local c
        while [ $((SECONDS - debut)) -lt "$max" ]; do
            c="$(vty "$MSC_VTY" "show subscriber cache")"
            [ -n "$IMSI" ] && printf '%s' "$c" | grep -A3 "IMSI: $IMSI" | grep -q 'IMSI detached: *false' && return 0
        done
        say "Magnetite : IMSI ${IMSI:-?} toujours pas attache au VLR apres ${max}s (pas de VTY mobile, la preuve est au MSC)"
        return 1
    fi
    while [ $((SECONDS - debut)) -lt "$max" ]; do
        ms="$(show_ms)"
        if printf '%s' "$ms" | grep -q 'C3 camped normally' && printf '%s' "$ms" | grep -q 'MM idle, normal service'; then
            [ "$bon" = 0 ] && depuis=$((SECONDS - debut))
            bon=$((bon + 1))
            if [ "$bon" -ge "$need" ]; then
                [ $((SECONDS - debut)) -gt 2 ] && say "mobile en service stable apres $((SECONDS - debut))s d'attente"
                return 0
            fi
        else
            [ "$bon" -gt 0 ] && say "mobile : service perdu apres ${bon} lecture(s) - on attend la resynchronisation"
            bon=0
        fi
    done
    say "mobile toujours pas en service stable apres ${max}s : $(printf '%s' "$ms" | sed -n 's/^ *mobility management layer state: //p' | head -1)"
    return 1
}

verdict() {   # $1 barreau, $2 OK|ECHEC|SAUTE, $3 detail
    VERD[$1]="$2"; DET[$1]="${3:-}"
    local c="$G"; [ "$2" = ECHEC ] && c="$R"; [ "$2" = SAUTE ] && c="$D"
    printf '  %-9s %s%-6s%s %s\n' "$1" "$c" "$2" "$Z" "${3:-}"
}

# ── Le mode ─────────────────────────────────────────────────────────────────
# Les deux montages different par la VTY du mobile, le fichier de conf qu'il
# ouvre (donc l'IMSI presentee) et les process de couche 1. Tout le reste de
# l'echelle est commun : meme coeur, meme BTS, meme MSC.
lib_init() {
    STAMP="$(date +%Y%m%d-%H%M%S)"; OUT="/root/banc-max-$STAMP"
    mkdir -p "$OUT" || { echo "impossible de creer $OUT" >&2; exit 1; }
    if [ -z "$MODE" ] && [ "$RESTART" = 0 ]; then
        # [2026-10-15] les deux couches 1 ont la VTY mobile sur 4247 : le mode se lit
        # au processus (c54x_exe --arm = DSP), plus au port.
        if   port_ouvert 4247 && pgrep -f 'c54x_exe[^ ]* --arm' >/dev/null; then MODE=dsp
        elif port_ouvert 4247; then MODE=grgsm
        else
            say "aucune VTY mobile n'ecoute sur 4247 : mode inconnu"
            say "-> --grgsm ou --dsp, avec --restart pour lancer la pile"; exit 2
        fi
    fi
    [ -z "$MODE" ] && MODE=grgsm
    case "$MODE" in
        grgsm) MOB_VTY=4247; MOB_CFG=/root/.osmocom/bb/mobile.cfg; START_OPT=(--grgsm)
               L1_REQ=(qemu-system-arm osmocon); L1_INFO=("pont/pont.py" grgsm_exe fake_trx trxcon) ;;
        dsp)   MOB_VTY=4247; MOB_CFG=/opt/GSM/c54x_exe/mobile_pont.cfg; START_OPT=(--dsp)
               L1_REQ=("c54x_exe[^ ]* --arm" qemu-system-arm osmocon); L1_INFO=(pont_dsp.py)
               # [2026-10-18] Par defaut le vocodeur est celui de la ROM : mobile en
               # « io-handler l1phy » (c54x_exe/run.sh genere mobile_pont_rom.cfg) et
               # port voix modelise. start-native.sh, lance par 00-demarrage, en herite.
               # BANC_VOCODEUR=hote ./banc-max.sh --dsp : retour a gapk sur l'hote.
               export BANC_VOCODEUR="${BANC_VOCODEUR:-rom}"
               [ "$BANC_VOCODEUR" = rom ] && export CALYPSO_VSP="${CALYPSO_VSP:-1}" ;;
        bts|bts-classique|ms-magnetite)
               # [2026-10-26] LES TROIS MONTAGES MAGNETITE. Le telephone est le vrai firmware TI
               # (FreeCalypso Magnetite, C139) en flash dans qosmo : pile L23 et interface DANS le
               # firmware, donc ni osmocon ni process mobile ni VTY. Les barreaux le pilotent au
               # clavier (MOB_CLAVIER, socket de calypso_armio.c) et lisent les preuves au reseau.
               #   bts            --bts --ms-magnetite        : le Calypso de QEMU est le TRX de la BTS#0
               #                  (instance 1, /tmp/c54x-pont), Magnetite est l'INSTANCE 2 par l'air
               #                  (pont/air.py) : /tmp/c54x-pont2, clavier /tmp/calypso_keys2.sock.
               #   bts-classique  --bts-classic --ms-magnetite : BTS osmo-bts-trx <-> pont_dsp.py,
               #                  Magnetite en instance 1 sur le pont.
               #   ms-magnetite   --ms-magnetite seul          : pareil, c'est le montage par defaut
               #                  de start-native (BTS classique) nomme par le mobile.
               # L'IMSI : la SIM emulee de qosmo lit CALYPSO_SIM_CFG = mobile.cfg (09-mobile-cfg-tmux.sh),
               # Magnetite presente donc l'IMSI de MS#1 (verifie au VLR le 26/10 : 001010001000001).
               MOB_VTY=0; MOB_CLAVIER=1; MOB_CFG=/root/.osmocom/bb/mobile.cfg
               case "$MODE" in
                   bts)           START_OPT=(--bts --ms-magnetite); MOB_RUNDIR=/tmp/c54x-pont2; MOB_KEYS_SOCK=/tmp/calypso_keys2.sock
                                  L1_REQ=(qemu-system-arm "c54x_exe[^ ]* --arm" transceiver); L1_INFO=(rvinterf "pont/air.py") ;;
                   bts-classique) START_OPT=(--bts-classic --ms-magnetite); MOB_RUNDIR=/tmp/c54x-pont; MOB_KEYS_SOCK=/tmp/calypso_keys.sock
                                  L1_REQ=(qemu-system-arm "c54x_exe[^ ]* --arm"); L1_INFO=(rvinterf pont_dsp.py) ;;
                   ms-magnetite)  START_OPT=(--ms-magnetite); MOB_RUNDIR=/tmp/c54x-pont; MOB_KEYS_SOCK=/tmp/calypso_keys.sock
                                  L1_REQ=(qemu-system-arm "c54x_exe[^ ]* --arm"); L1_INFO=(rvinterf pont_dsp.py) ;;
               esac
               # --gapk PAR DEFAUT avec Magnetite (demande du 26/10) : le vocodeur est sur l'hote,
               # la voix du C139 est codee par le pont (PONT_VOIX_HOTE=1, pont/voix_hote.py).
               # MAGNETITE_GAPK=0 pour revenir au vocodeur de la ROM.
               if [ "${MAGNETITE_GAPK:-1}" != 0 ]; then
                   START_OPT+=(--gapk); export BANC_VOCODEUR=hote CALYPSO_VSP=0
               fi
               DSPDIR="$MOB_RUNDIR" ;;
    esac
    IMSI="$(sed -n 's/^ *imsi \([0-9]\{15\}\).*/\1/p' "$MOB_CFG" 2>/dev/null | head -1)"
}
# Le journal d'un process, pour ce mode : le plus recent des deux dossiers,
# parce que run.sh (dsp) et qosmo (grgsm) n'ecrivent pas au meme endroit et
# qu'un dossier peut garder le journal d'un run precedent.
log_de() {   # $1 = dsp|qemu|osmocon|mobile|pont
    local c best=""
    [ "$1" = pont ] && { echo "$PONT_LOG"; return; }
    for c in "$DSPDIR/$1.log" "$LOGDIR/$1.log"; do
        [ -s "$c" ] || continue
        [ -z "$best" ] || [ "$c" -nt "$best" ] && best="$c"
    done
    echo "$best"
}

lib_collecte() {
    vty "$MSC_VTY" "show statistics" > "$OUT/msc-statistics.txt"
    show_ms > "$OUT/show-ms-final.txt"
    local f src
    for f in mobile qemu osmocon dsp pont rvinterf; do src="$(log_de $f)"; [ -n "$src" ] && cp "$src" "$OUT/$f.log" 2>/dev/null; done
    # [2026-10-26] mode bts : l'instance 1 (/tmp/c54x-pont) est le TRX de la BTS, ses journaux a part.
    if [ "$MODE" = bts ]; then
        for f in osmocon dsp qemu transceiver; do [ -s "/tmp/c54x-pont/$f.log" ] && cp "/tmp/c54x-pont/$f.log" "$OUT/trx-$f.log" 2>/dev/null; done
    fi
    if [ "$STOP_AFTER" = 1 ]; then
        say "arret de la pile (--stop-after)"
        ( cd "$REPO" && CALYPSO_NO_ATTACH=1 ./start-native.sh --stop ) >"$OUT/stop-after.log" 2>&1
    fi
}

lib_verdict() {
    head_ "ECHELLE — mode $MODE$([ "$MULTI" = 1 ] && echo ' + multi-operateur')"
    local n=0 max=0 nom v c ok=0 sau=0 sautes=""
    ECHECS=0
    {
        for nom in "${NOMS[@]}"; do
            n=$((n+1)); v="${VERD[$nom]}"
            [ "$v" = OK ] && { max=$n; ok=$((ok+1)); }
            [ "$v" = ECHEC ] && ECHECS=$((ECHECS+1))
            { [ "$v" = SAUTE ] || [ "$v" = NON-TESTE ]; } && { sau=$((sau+1)); sautes="$sautes $nom"; }
            c="$G"; [ "$v" = ECHEC ] && c="$R"; { [ "$v" = SAUTE ] || [ "$v" = NON-TESTE ]; } && c="$D"
            printf '  %2d %-16s %s%-9s%s %s\n' "$n" "$nom" "$c" "$v" "$Z" "${DET[$nom]}"
        done
        # ELEMENT MAX = le plus haut barreau OK. Il ne dit pas que tout ce qui est
        # en dessous a tourne : les barreaux sautes ne sont pas des reussites, on
        # donne donc executes / sautes sur la meme ligne (lue telle quelle par
        # tout-en-un.py ; rapport.py ne lit que le debut, inchange).
        printf '\n  %sELEMENT MAX : %d/%d%s  (%s)  mode %s  echecs %d  —  executes %d/%d OK, %d saute(s)%s\n' \
            "$B" "$max" "${#NOMS[@]}" "$Z" "${NOMS[$((max>0 ? max-1 : 0))]}" "$MODE" "$ECHECS" \
            "$ok" "$((ok+ECHECS))" "$sau" "${sautes:+ :$sautes}"
    } | tee "$OUT/verdict.txt"
    say "details dans $OUT"
}

# ── pytest : une famille = un barreau ───────────────────────────────────────
# La suite /opt/GSM/tests/pytest est marquee par famille (banc_infra, banc_couche1,
# banc_mobile, banc_reseau, banc_actif) et par mode (grgsm, dsp, commun) : le
# conftest saute l'autre mode, on choisit la famille par -m. La cale
# pytest/bin/docker et les liens /tmp/*.log servent a l'ancienne suite (legacy/),
# qui lisait un conteneur ; les nouveaux tests lisent le banc par banc.py.
pytest_famille() {   # $1 = famille (infra...), $2 = expression -m, [$3 = repertoire de tests]
    local fam="$1" expr="$2" rep="${3:-.}" py=/root/.env/bin/python3 res mon lien cible
    # pytest peut manquer au venv /root/.env : on retombe sur le python systeme
    # (python3-pytest) avant de SAUTER. Les sondes tournent depuis / : dans
    # tests/ le dossier pytest/ (sans __init__) fait dire « 'pytest' is a package
    # and cannot be directly executed » quand le vrai module est absent, ce qui
    # cache la vraie cause.
    local cand
    for cand in "$py" /usr/bin/python3; do
        ( cd / && "$cand" -m pytest --version ) >/dev/null 2>&1 && { py="$cand"; break; }
        py=""
    done
    [ -n "$py" ] || { verdict "pytest-$fam" SAUTE "pytest absent du venv /root/.env et de /usr/bin/python3 (apt install python3-pytest)"; return; }
    mon="$(ls -t /run/user/*/osmo-nitb/qemu-monitor.sock 2>/dev/null | head -1)"
    for lien in "/root/qemu.log:$(log_de qemu)" "/tmp/qemu.log:$(log_de qemu)" "/tmp/bridge.log:$(log_de pont)" \
                "/tmp/mobile.log:$(log_de mobile)" "/tmp/osmocon.log:$(log_de osmocon)" "/tmp/bts.log:$LOGDIR/bts.log" \
                "/tmp/qemu-calypso-mon.sock:$mon"; do
        cible="${lien#*:}"; lien="${lien%%:*}"
        [ -n "$cible" ] && [ -e "$cible" ] || continue
        if [ ! -e "$lien" ] || [ -L "$lien" ]; then ln -sfn "$cible" "$lien"; fi   # jamais un vrai fichier
    done
    mkdir -p "$OUT/pytest/$fam"
    ( cd "$TESTS/pytest" && \
      PATH="$TESTS/pytest/bin:$PATH" CALYPSO_CONTAINER=local CALYPSO_MODE="$MODE" CALYPSO_MODE_TAG="$MODE" \
      CALYPSO_QEMU_LOG="$(log_de qemu)" CALYPSO_MOBILE_LOG="$(log_de mobile)" CALYPSO_OSMOCON_LOG="$(log_de osmocon)" \
      CALYPSO_MON_SOCK="${mon:-/tmp/qemu-calypso-mon.sock}" CALYPSO_MOBILE_VTY="$MOB_VTY" CALYPSO_HOST_ROOT=/root \
      CALYPSO_TEST_OUT="$OUT/pytest/$fam" CALYPSO_SKIP_DIAG_BUNDLE=1 QEMU_TREE=/opt/GSM/qosmo \
      timeout --foreground 900 $py -m pytest -q -ra -p no:cacheprovider --color=no --continue-on-collection-errors -m "$expr" "$rep" ) \
      2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/existant-pytest-$fam.txt"
    res="$(grep -oE '[0-9]+ (passed|failed|errors?|skipped|xfailed|xpassed)' "$OUT/existant-pytest-$fam.txt" | tr '\n' ' ')"
    [ -f "$OUT/pytest/$fam/test_results.md" ] && res="$res-> pytest/$fam/test_results.md"
    if grep -qE '(^| )[1-9][0-9]* (failed|errors?)' "$OUT/existant-pytest-$fam.txt"; then
        verdict "pytest-$fam" ECHEC "$res: $(grep -E '^FAILED' "$OUT/existant-pytest-$fam.txt" | sed 's/^FAILED [^:]*::/ /' | cut -c1-70 | head -3 | tr '\n' ';')"
    elif grep -qE '[0-9]+ passed' "$OUT/existant-pytest-$fam.txt"; then verdict "pytest-$fam" OK "$res"
    elif grep -qE '[0-9]+ (skipped|deselected)' "$OUT/existant-pytest-$fam.txt"; then verdict "pytest-$fam" SAUTE "$res"
    else verdict "pytest-$fam" ECHEC "pytest n'a rien rendu (existant-pytest-$fam.txt)"; fi
}

# Le dossier en ligne (qmd-worker, tests.pl4y.store) refait avec CE banc seul :
# build.mjs (lance par wrangler deploy) prend les runs de BANC, et non plus le
# dernier /root/banc-max-* par date. Un echec du deploiement ne change pas le
# verdict du banc. QMD_WORKER=0 pour ne pas deployer.
qmd_worker_maj() {   # $@ = repertoires du banc (run, ou campagne + ses deux modes)
    [ "${QMD_WORKER:-1}" = 0 ] && return 0
    local w="$TESTS/qmd-worker" log="$1/qmd-worker.log"
    [ -d "$w/node_modules" ] || { say "qmd-worker : pas de node_modules, dossier en ligne non mis a jour"; return 0; }
    say "qmd-worker : dossier en ligne refait avec $*"
    if ( cd "$w" && BANC="$*" timeout 600 npx --no-install wrangler deploy ) > "$log" 2>&1; then
        say "qmd-worker : deploye ($(grep -oE 'https?://[^ ]+' "$log" | tail -1))"
    else
        say "${R:-}qmd-worker : deploiement en echec (voir $log)${Z:-}"
    fi
}
