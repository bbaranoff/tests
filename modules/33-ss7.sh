#!/bin/bash
# SS7 du noeud : checks/ss7_check.sh --quick (STP local, ASP/AS, usagers SCCP MSC+BSC) + diag-stp-operator si /etc/osmo-role
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "STP, M3UA, SCCP"; }
# Le verdict vient des scripts du depot : ss7_check.sh rend le nombre
# d'echecs ; diag-stp-operator.sh rend 0 et conclut en derniere section, on y
# lit « DOWN ». En mono-operateur sans WAN, seul ss7_check a un sens.
# [2026-10-15] LE HUB, S'IL MANQUE ET QU'IL EST A NOUS. Le STP local a un ASP
# « asp-to-inter » vers un inter-STP ; sur un banc autonome personne ne le
# lance, et le barreau echouait sur « aucune association SCTP vers <hub>:2908 ».
# Detection : l'adresse du hub = remote-ip de asp-to-inter dans osmo-stp.cfg,
# le noeud = routing-key de as-inter / 1000 (rctx = noeud*1000 + op*100 + 50),
# l'operateur = (rctx/100)%10. Le hub n'est lance que si cette adresse est
# portee par CETTE machine et que rien n'ecoute en M3UA (SCTP 2908) : un hub
# distant, ou deja en service, n'est jamais touche. --no-save : la table WAN
# du noeud n'est pas reecrite. SS7_HUB_AUTO=0 coupe ce lancement.
ss7_hub_auto() {
    [ "${SS7_HUB_AUTO:-1}" = 1 ] || return 0
    local cfg=/etc/osmocom/osmo-stp.cfg hub rctx node op
    [ -r "$cfg" ] || return 0
    hub="$(awk '/^ *asp asp-to-inter /{f=1;next} f&&/^ *remote-ip /{print $2; exit} f&&/^ (asp|as) /{exit}' "$cfg")"
    rctx="$(awk '/^ *as as-inter /{f=1;next} f&&/^ *routing-key /{print $2; exit} f&&/^ (asp|as) /{exit}' "$cfg")"
    [ -n "$hub" ] && [[ "$rctx" =~ ^[0-9]+$ ]] || { say "hub SS7 : pas d'asp-to-inter dans $cfg - rien a lancer"; return 0; }
    node=$(( rctx / 1000 )); op=$(( (rctx / 100) % 10 ))
    [ "$node" -ge 1 ] && [ "$node" -le 9 ] && [ "$op" -ge 1 ] || { say "hub SS7 : routing-key $rctx illisible"; return 0; }
    if python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM,132); s.settimeout(2)
s.connect((sys.argv[1],2908))' "$hub" 2>/dev/null; then
        say "hub SS7 $hub:2908 deja en service"; return 0
    fi
    ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qxF "$hub" \
        || { say "hub SS7 $hub muet et distant : pas lance d'ici"; return 0; }
    say "hub SS7 $hub muet et local : start-interstp.sh --ip $hub --ops $op --ips \"$node:$hub\" --no-save"
    ( cd "$REPO" && timeout --foreground 60 ./start-interstp.sh --ip "$hub" --ops "$op" --ips "$node:$hub" --no-save ) \
        > "$OUT/ss7-hub.txt" 2>&1 < /dev/null
    # L'ASP du STP local se reconnecte seul (client SCTP, reessais) : on lui laisse le temps.
    local i; for i in $(seq 1 20); do
        ss --sctp -Hn 2>/dev/null | grep -q ":2908\b" && { say "association SCTP vers le hub etablie en ${i}s"; return 0; }
        sleep 1
    done
    say "hub lance, association SCTP pas encore vue apres 20 s (ss7-hub.txt)"
}

mod_run() {
    local ko="" n
    ss7_hub_auto
    # Sans --multi, osmo-multi.conf ferait inventorier les op 2/3 (conteneurs
    # eteints) : deux « STP VTY inaccessible » qui ne disent rien de ce noeud.
    # OSMO_MULTI_CONF=/dev/null rend l'inventaire a OSMO_OP_IDS (checks/_mode.sh).
    local env_multi=(); [ "$MULTI" = 1 ] || env_multi=(OSMO_MULTI_CONF=/dev/null OSMO_OP_IDS=1)
    ( cd "$REPO" && env "${env_multi[@]}" NO_COLOR=1 timeout --foreground 300 ./checks/ss7_check.sh --quick --native ) 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/existant-ss7_check.txt"
    n=${PIPESTATUS[0]}; [ "$n" = 0 ] || ko="$ko ss7_check($n echecs)"
    if [ -f /etc/osmo-role ]; then
        ( cd "$REPO" && timeout --foreground 120 ./checks/diag-stp-operator.sh --no-color ) > "$OUT/existant-diag-stp-operator.txt" 2>&1
        tail -5 "$OUT/existant-diag-stp-operator.txt" | grep -q "DOWN" && ko="$ko diag-stp-operator(DOWN)"
    fi
    local resume; resume="$(grep -cE '^ *✓' "$OUT/existant-ss7_check.txt") ✓, $(grep -cE '^ *✗' "$OUT/existant-ss7_check.txt") ✗"
    [ -z "$ko" ] && verdict ss7 OK "ss7_check $resume$([ -f /etc/osmo-role ] && echo ', diag-stp-operator')" \
                 || verdict ss7 ECHEC "$ko ($resume, existant-ss7_check.txt)"
}
