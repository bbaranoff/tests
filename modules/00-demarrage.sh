#!/bin/bash
# (re)demarrage detache de la pile dans le mode choisi — seulement avec --restart
mod_titre() { echo "pile $MODE, no attach$([ "$MULTI" = 1 ] && echo ' + multi-operateur (start-multi.sh)')"; }
# LA CHAINE CALYPSO DOIT ETRE MORTE AVANT DE CHANGER DE MODE. Les deux montages
# tiennent les memes ports (5700-5702), les memes sockets (/tmp/osmocom_l2,
# /tmp/calypso_dsp.sock) et le meme nom de mobile : un QEMU ou un c54x_exe
# survivant fait echouer le demarrage suivant sur un etat qu'on croit propre
# (start-direct.sh, note du 2026-09-22). On arrete donc les DEUX montages, on
# attend que leurs processus aient disparu, et on tue ce qui reste.
CHAINE_RE='qemu-system-arm|osmocon|c54x_exe --arm|pont/pont|pont_dsp|trxcon|fake_trx|(^|/)mobile( |$)'
arret_complet() {
    # Les conteneurs op2/op3 et le hub ne sont touches QUE si --multi est passe :
    # sans lui, ce lanceur ne connait pas le multi-operateur.
    [ "$MULTI" = 1 ] && ( cd "$REPO" && OSMO_NO_ATTACH=1 ./start-multi.sh --stop ) >"$OUT/stop-multi.log" 2>&1
    ( cd "$REPO" && CALYPSO_NO_ATTACH=1 ./start-direct.sh --stop ) >"$OUT/stop.log" 2>&1
    [ -x /opt/GSM/c54x_exe/run.sh ] && ( cd /opt/GSM/c54x_exe && MODE=dsp ./run.sh --stop ) >>"$OUT/stop.log" 2>&1
    local i restes
    for i in $(seq 1 20); do
        restes="$(pgrep -fa -- "$CHAINE_RE" | grep -v pgrep | awk '{print $2}' | xargs -n1 basename 2>/dev/null | sort -u | tr '\n' ' ')"
        [ -z "$restes" ] && break
        sleep 1
    done
    if [ -n "$restes" ]; then
        say "restes apres l'arret : $restes-> TERM puis KILL"
        pkill -TERM -f -- "$CHAINE_RE" 2>/dev/null; sleep 3
        pkill -KILL -f -- "$CHAINE_RE" 2>/dev/null; sleep 1
        restes="$(pgrep -fa -- "$CHAINE_RE" | grep -v pgrep | tr '\n' ';')"
        [ -n "$restes" ] && say "ENCORE LA : $restes"
    fi
    printf 'restes apres arret : %s\n' "${restes:-aucun}" >> "$OUT/stop.log"
}
mod_run() {
    if [ "$RESTART" != 1 ]; then verdict demarrage SAUTE "pile en cours reutilisee (pas de --restart)"; return; fi
    say "arret complet des deux montages (grgsm et dsp)"
    arret_complet
    sleep 2
    # --multi : le natif prend son identite (point code, OPERATOR_ID) AVANT de
    # demarrer. Sinon start-multi.sh le realignait apres coup, l'arretait et le
    # relancait par le bureau : une pile montee pour rien.
    if [ "$MULTI" = 1 ]; then
        say "start-multi.sh --align : identite du natif avant son demarrage"
        ( cd "$REPO" && ./start-multi.sh --align ) >"$OUT/align-multi.log" 2>&1
    fi
    say "start-direct.sh $START_OPT, detache (CALYPSO_NO_ATTACH=1)"
    ( cd "$REPO" && CALYPSO_NO_ATTACH=1 setsid ./start-direct.sh "$START_OPT" ) >"$OUT/start.log" 2>&1 &
    # On attend que le coeur ecoute avant de mesurer : sinon « coeur » tomberait
    # sur un demon qui n'a simplement pas encore lu sa conf.
    local i
    for i in $(seq 1 120); do port_ouvert "$MSC_VTY" && port_ouvert 4242 && break; sleep 1; done
    if ! port_ouvert "$MSC_VTY"; then
        verdict demarrage ECHEC "le MSC n'ecoute toujours pas apres 120 s (voir start.log)"; return
    fi
    say "coeur joignable apres ${i}s ; 20 s de plus pour la couche 1"; sleep 20
    if [ "$MULTI" != 1 ]; then
        verdict demarrage OK "arret complet, puis start-direct.sh $START_OPT : coeur en ${i}s"; return
    fi
    # ── --multi : les conteneurs op2/op3 et le hub inter-STP, SEULEMENT ici ──
    # start-multi.sh raccorde l'op 1 natif (deja debout) et lance le reste par
    # start.sh (OSMO_NO_ATTACH=1 : pas de tmux). Chaque conteneur monte sa
    # propre pile ; on attend le MSC de l'op 2, sinon les barreaux SS7 et
    # inter-op mesureraient notre impatience.
    local hub="${MULTI_HUB_NAME:-osmo-inter-stp}" op2=osmo-operator-2 j
    say "start-multi.sh, detache (OSMO_NO_ATTACH=1)"
    ( cd "$REPO" && OSMO_KEEP_NATIF=1 OSMO_NO_ATTACH=1 OSMO_NONINTERACTIVE=1 ./start-multi.sh $([ "$REBUILD" = 1 ] && echo --rebuild) ) > "$OUT/start-multi.log" 2>&1
    for j in $(seq 1 180); do
        docker exec "$op2" bash -c 'echo >/dev/tcp/127.0.0.1/4254' 2>/dev/null && break; sleep 1
    done
    docker ps --format '{{.Names}} {{.Status}}' > "$OUT/multi-docker-ps.txt" 2>/dev/null
    if docker ps --format '{{.Names}}' | grep -qx "$hub" && docker exec "$op2" bash -c 'echo >/dev/tcp/127.0.0.1/4254' 2>/dev/null; then
        say "MSC op2 joignable apres ${j}s ; 30 s pour le raccordement SS7"; sleep 30
        verdict demarrage OK "start-direct.sh $START_OPT (coeur en ${i}s) + start-multi.sh : hub $hub, op2 en ${j}s"
    else
        verdict demarrage ECHEC "start-multi.sh : hub ou $op2 absent apres 180 s (start-multi.log, multi-docker-ps.txt)"
    fi
}
