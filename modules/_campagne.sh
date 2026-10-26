#!/bin/bash
# _campagne.sh — plusieurs modes a la suite, jusqu'a l'appel, et un rapport
# qui les met cote a cote. Charge par banc-max.sh --campagne, --full, --all.
# [2026-10-26] N modes : la liste est MODES_CAMPAGNE (banc-max.sh : « grgsm dsp »
# par defaut, les cinq couches 1 avec --all). Les liens <mode>/ du dossier de
# campagne pointent vers les runs ; rapport.py les lit tous.
campagne_run() {
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    local dir="/root/banc-max-campagne-$stamp"; mkdir -p "$dir"
    local extra=() a mode rc
    local modes="${MODES_CAMPAGNE:-grgsm dsp}"
    # --full, --all et les noms de modes sont « deplies » par la campagne elle-meme :
    # on les retire des extras pour ne pas les repasser a chaque mode (sinon le fils
    # re-declencherait la campagne -> recursion infinie, ou verrait deux modes).
    # --4g, --multi, --ms2, --data, --legacy, --stop-after... restent et sont joues dans chaque mode.
    for a in "${ARGS[@]}"; do
        case "$a" in
            --campagne|--full|--all|--grgsm|--dsp|--bts|--bts-classique|--bts-classic|--ms-magnetite|--restart|--continue) ;;
            *) extra+=("$a") ;;
        esac
    done
    head_ "CAMPAGNE $stamp : $(echo $modes | sed 's/ /, puis /g'), jusqu'a l'appel"
    for mode in $modes; do
        say "── mode $mode ──"
        QMD_WORKER=0 "$TESTS/banc-max.sh" "--$mode" --restart --continue "${extra[@]}" 2>&1 | tee "$dir/$mode.log"
        rc=${PIPESTATUS[0]}
        [ "$rc" = 130 ] && { say "campagne interrompue pendant le mode $mode"; return 130; }
        local out; out="$(grep -o '/root/banc-max-[0-9-]*' "$dir/$mode.log" | tail -1)"
        [ -n "$out" ] && ln -sfn "$out" "$dir/$mode"
        echo "$rc" > "$dir/$mode.rc"
    done
    # Le rapport : les echelles en colonnes (une par mode), puis les couvertures.
    {
        echo "=== CAMPAGNE $stamp — echelle des elements : $modes ==="
        echo
        printf '  %-16s' barreau; for mode in $modes; do printf ' %-14s' "$mode"; done; echo
        # Jointure par NOM de barreau : les runs peuvent ne pas avoir la meme liste
        # (un module ajoute entre deux), le rang ne suffit pas.
        local nom v fichiers=()
        for mode in $modes; do fichiers+=("$dir/$mode/verdict.txt"); done
        for nom in $(sed -n 's/^ *[0-9]* \([a-z0-9-]*\) .*/\1/p' "${fichiers[@]}" 2>/dev/null | awk '!seen[$0]++'); do
            printf '  %-16s' "$nom"
            for mode in $modes; do
                v="$(sed -n "s/^ *[0-9]* $nom *\([A-Z-]*\).*/\1/p" "$dir/$mode/verdict.txt" 2>/dev/null | head -1)"
                printf ' %-14s' "${v:--}"
            done
            echo
        done
        echo
        for mode in $modes; do
            printf '  %-14s %s\n' "$mode" "$(grep -h "ELEMENT MAX" "$dir/$mode/verdict.txt" 2>/dev/null | sed 's/^ *//')"
        done
        echo
        for mode in $modes; do
            echo "=== couverture couche 1 — $mode ==="
            cat "$dir/$mode/couverture.txt" 2>/dev/null || echo "  (pas de rapport de couverture)"
            echo
        done
        echo "journaux : $dir/{$(echo $modes | tr ' ' ',')}/ (liens vers les runs)"
    } | sed 's/\x1b\[[0-9;]*m//g' | tee "$dir/rapport.txt"
    say "rapport : $dir/rapport.txt"
    # Le PDF : meme contenu, mis en page, plus les extraits de preuve.
    if "$TESTS/rapport.py" "$dir" > "$dir/rapport-pdf.log" 2>&1; then say "PDF     : $dir/rapport.pdf"
    else say "PDF non produit (voir $dir/rapport-pdf.log)"; fi
    # Le dossier en ligne : la campagne et ses runs (liens resolus, os.walk ne les
    # suit pas), rien des bancs precedents.
    local runs=("$dir"); for mode in $modes; do [ -L "$dir/$mode" ] && runs+=("$(readlink -f "$dir/$mode")"); done
    qmd_worker_maj "${runs[@]}"
    # Code de retour : 0 seulement si CHAQUE mode a rendu 0.
    local ok=0
    for mode in $modes; do [ "$(cat "$dir/$mode.rc" 2>/dev/null)" = 0 ] || ok=1; done
    return $ok
}
