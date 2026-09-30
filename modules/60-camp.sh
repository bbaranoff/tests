#!/bin/bash
# « C3 camped normally » cote mobile, attente jusqu'a --boot-max
MOD_CHAINE=1
MOD_RELANCE_PILE=1
mod_titre() { echo "max ${BOOT_MAX}s"; }
mod_run() {
    local i ms camp=0 cell etat
    for i in $(seq 1 "$BOOT_MAX"); do
        ms="$(show_ms)"
        printf '%s' "$ms" | grep -q "C3 camped normally" && { camp=1; break; }
    done
    printf '%s\n' "$ms" > "$OUT/show-ms-camp.txt"
    cell="$(printf '%s' "$ms" | grep -o 'ARFCN=[^ ]* CGI=[^ ]*' | head -1)"
    if [ "$camp" = 1 ]; then verdict camp OK "apres ${i}s, $cell"
    else
        etat="$(printf '%s' "$ms" | sed -n 's/^ *cell selection state: //p' | head -1)"
        verdict camp ECHEC "pas de C3 apres ${BOOT_MAX}s (etat : ${etat:-inconnu})"
    fi
}
