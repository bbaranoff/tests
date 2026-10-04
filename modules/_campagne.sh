#!/bin/bash
# _campagne.sh — les deux modes a la suite, jusqu'a l'appel, et un rapport
# qui les met cote a cote. Charge par banc-max.sh --campagne.
campagne_run() {
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local dir="/root/banc-max-campagne-$stamp"; mkdir -p "$dir"
    local extra=() a mode rc
    # --full et les deux couches 1 sont « deplies » par la campagne elle-meme :
    # on les retire des extras pour ne pas les repasser a chaque mode (sinon le
    # fils re-declencherait la campagne -> recursion infinie). --4g, --multi,
    # --stop-after... restent et sont joues dans chaque mode.
    for a in "${ARGS[@]}"; do case "$a" in --campagne|--full|--grgsm|--dsp|--restart|--continue) ;; *) extra+=("$a") ;; esac; done
    head_ "CAMPAGNE $stamp : grgsm puis dsp, jusqu'a l'appel"
    for mode in grgsm dsp; do
        say "── mode $mode ──"
        "$TESTS/banc-max.sh" "--$mode" --restart --continue "${extra[@]}" 2>&1 | tee "$dir/$mode.log"
        rc=${PIPESTATUS[0]}
        [ "$rc" = 130 ] && { say "campagne interrompue pendant le mode $mode"; return 130; }
        local out; out="$(grep -o '/root/banc-max-[0-9-]*' "$dir/$mode.log" | tail -1)"
        [ -n "$out" ] && ln -sfn "$out" "$dir/$mode"
        echo "$rc" > "$dir/$mode.rc"
    done
    # Le rapport : les deux echelles en colonnes, puis les deux couvertures.
    {
        echo "=== CAMPAGNE $stamp — echelle des elements, grgsm et dsp ==="
        echo
        printf '  %-16s %-10s %-10s\n' barreau grgsm dsp
        # Jointure par NOM de barreau : les deux runs peuvent ne pas avoir la
        # meme liste (un module ajoute entre les deux), le rang ne suffit pas.
        local nom v1 v2
        for nom in $(sed -n 's/^ *[0-9]* \([a-z0-9-]*\) .*/\1/p' "$dir/grgsm/verdict.txt" "$dir/dsp/verdict.txt" 2>/dev/null | awk '!seen[$0]++'); do
            v1="$(sed -n "s/^ *[0-9]* $nom *\([A-Z-]*\).*/\1/p" "$dir/grgsm/verdict.txt" 2>/dev/null | head -1)"
            v2="$(sed -n "s/^ *[0-9]* $nom *\([A-Z-]*\).*/\1/p" "$dir/dsp/verdict.txt" 2>/dev/null | head -1)"
            printf '  %-16s %-10s %-10s\n' "$nom" "${v1:--}" "${v2:--}"
        done
        echo
        grep -h "ELEMENT MAX" "$dir/grgsm/verdict.txt" "$dir/dsp/verdict.txt" 2>/dev/null | sed 's/^/ /'
        echo
        for mode in grgsm dsp; do
            echo "=== couverture couche 1 — $mode ==="
            cat "$dir/$mode/couverture.txt" 2>/dev/null || echo "  (pas de rapport de couverture)"
            echo
        done
        echo "journaux : $dir/{grgsm,dsp}/ (liens vers les runs)"
    } | sed 's/\x1b\[[0-9;]*m//g' | tee "$dir/rapport.txt"
    say "rapport : $dir/rapport.txt"
    # Le PDF : meme contenu, mis en page, plus les extraits de preuve.
    if "$TESTS/rapport.py" "$dir" > "$dir/rapport-pdf.log" 2>&1; then say "PDF     : $dir/rapport.pdf"
    else say "PDF non produit (voir $dir/rapport-pdf.log)"; fi
    [ "$(cat "$dir/grgsm.rc" 2>/dev/null)" = 0 ] && [ "$(cat "$dir/dsp.rc" 2>/dev/null)" = 0 ]
}
