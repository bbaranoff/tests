#!/bin/bash
# les tests deja ecrits du depot, joues tels quels : checks/global_check.sh --quick, scripts/call-diag.sh, scripts/audio-diag.sh
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "global_check, call-diag, audio-diag"; }
# On ne reimplemente rien : chaque verdict vient du script d'origine.
#   global_check.sh rend le NOMBRE d'echecs (--op=1 : sans lui il inventorie
#   aussi les op 2 et 3 de osmo-multi.conf, conteneurs eteints -> 12 DOWN) ; call-diag et audio-diag rendent
#   toujours 0, leur verdict est le nombre de lignes « ✗ » (format de leur fail()) sur la
#   sortie sans couleur — pas le caractere seul, que leurs listes de process
#   (pgrep -fa) peuvent recopier depuis n'importe quelle ligne de commande.
mod_run() {
    local ko="" n
    ( cd "$REPO" && NO_COLOR=1 timeout --foreground 300 ./checks/global_check.sh --quick --native --op=1 ) > "$OUT/existant-global_check.txt" 2>&1
    n=$?; [ "$n" = 0 ] || ko="$ko global_check($n echecs)"
    for s in call-diag audio-diag; do
        ( cd "$REPO" && timeout --foreground 120 bash "scripts/$s.sh" ) 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/existant-$s.txt"
        n="$(grep -c '^  ✗ ' "$OUT/existant-$s.txt")"
        [ "$n" = 0 ] || ko="$ko $s($n ✗)"
    done
    [ -z "$ko" ] && verdict checks-existants OK "global_check, call-diag, audio-diag sans echec" \
                 || verdict checks-existants ECHEC "$ko (existant-*.txt)"
}
