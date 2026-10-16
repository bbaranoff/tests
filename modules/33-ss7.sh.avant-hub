#!/bin/bash
# SS7 du noeud : checks/ss7_check.sh --quick (STP local, ASP/AS, usagers SCCP MSC+BSC) + diag-stp-operator si /etc/osmo-role
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "STP, M3UA, SCCP"; }
# Le verdict vient des scripts du depot : ss7_check.sh rend le nombre
# d'echecs ; diag-stp-operator.sh rend 0 et conclut en derniere section, on y
# lit « DOWN ». En mono-operateur sans WAN, seul ss7_check a un sens.
mod_run() {
    local ko="" n
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
