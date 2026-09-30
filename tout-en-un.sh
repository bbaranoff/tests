#!/bin/bash
# tout-en-un.sh — concatene tous les fichiers .log .sh .md .mmd .py .txt d'un ou
# plusieurs dossiers dans un seul .txt, un en-tete par fichier.
#   ./tout-en-un.sh [dossier...]        (defaut : /opt/GSM/tests et le dernier /root/banc-max-*)
#   SORTIE=/chemin/fichier.txt          (defaut : /root/tout-en-un-<date>.txt)
#   EXT="log sh md"                     (defaut : log sh md mmd py txt)
set -u
EXT="${EXT:-log sh md mmd py txt}"
SORTIE="${SORTIE:-/root/tout-en-un-$(date +%Y%m%d-%H%M%S).txt}"
if [ $# -eq 0 ]; then
    set -- /opt/GSM/tests "$(ls -td /root/banc-max-* 2>/dev/null | head -1)"
fi
args=(); for e in $EXT; do args+=( -o -iname "*.$e" ); done
{
    echo "# tout-en-un — $(date '+%F %T') — dossiers : $*"
    echo "# extensions : $EXT"
    echo
    n=0
    for d in "$@"; do
        [ -d "$d" ] || { echo "# (absent) $d"; continue; }
        while IFS= read -r -d '' f; do
            n=$((n+1))
            printf '\n\n===== %s (%s octets) =====\n' "$f" "$(stat -c %s "$f")"
            sed 's/\x1b\[[0-9;]*[mK]//g' "$f" | tr -d '\r'
        done < <(find "$d" \( -name .git -o -name __pycache__ -o -name .pytest_cache -o -name node_modules \) -prune -o -type f \( -false "${args[@]}" \) -print0 | sort -z)
    done
    printf '\n# %d fichiers\n' "$n"
} > "$SORTIE"
echo "$SORTIE : $(wc -l < "$SORTIE") lignes, $(du -h "$SORTIE" | cut -f1), $(grep -c '^===== ' "$SORTIE") fichiers"
