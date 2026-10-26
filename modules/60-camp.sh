#!/bin/bash
# « C3 camped normally » cote mobile, attente jusqu'a --boot-max ; en Magnetite : l'IMSI au VLR (pas de VTY)
MOD_CHAINE=1
MOD_RELANCE_PILE=1
mod_titre() { echo "max ${BOOT_MAX}s"; }
mod_run() {
    local i ms camp=0 cell etat
    if [ "$MOB_CLAVIER" = 1 ]; then
        # [2026-10-26] Magnetite : pas de « show ms ». Un telephone campe fait sa mise a jour de
        # localisation : on attend que son IMSI apparaisse au cache d'abonnes du MSC. C'est une
        # preuve plus forte que C3 (elle inclut RACH, IMM ASS, SDCCH, A5), lue cote reseau.
        local c
        for i in $(seq 1 "$BOOT_MAX"); do
            c="$(vty "$MSC_VTY" "show subscriber cache")"
            [ -n "$IMSI" ] && printf '%s' "$c" | grep -q "IMSI: $IMSI" && { camp=1; break; }
            sleep 1
        done
        printf '%s\n' "$c" > "$OUT/msc-subscriber-cache-camp.txt"
        cell="$(printf '%s' "$c" | grep -B2 "IMSI: $IMSI" | sed -n 's/^ *LAC \/ cell ID: *//p' | head -1)"
        if [ "$camp" = 1 ]; then verdict camp OK "Magnetite : IMSI $IMSI au VLR apres ${i}s (LAC / cellule ${cell:-?}), camp deduit de la LU (pas de VTY mobile)"
        else verdict camp ECHEC "Magnetite : IMSI ${IMSI:-?} absent du VLR apres ${BOOT_MAX}s ($(grep -c 'RA_R\|IAS_R' "$MOB_RUNDIR/rvinterf.log" 2>/dev/null || echo 0) RACH / IMM ASS dans rvinterf.log)"; fi
        return
    fi
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
