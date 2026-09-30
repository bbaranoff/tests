#!/bin/bash
# MM « normal service » cote mobile ET l'IMSI dans le cache d'abonnes du MSC
MOD_CHAINE=1
mod_titre() { echo "mise a jour de localisation, max ${ATTACH_MAX}s"; }
mod_run() {
    local i mm cache att=0
    for i in $(seq 1 "$ATTACH_MAX"); do
        mm="$(show_ms | sed -n 's/^ *mobility management layer state: //p')"
        cache="$(vty "$MSC_VTY" "show subscriber cache")"
        if printf '%s' "$mm" | grep -q "normal service" && [ -n "$IMSI" ] && printf '%s' "$cache" | grep -q "$IMSI"; then att=1; break; fi
    done
    printf '%s\n' "$cache" > "$OUT/msc-subscriber-cache.txt"
    # Le MSISDN vient de la fiche PAR IMSI : dans le cache, « MSISDN: » precede
    # « IMSI: », un grep -A depuis l'IMSI tombait sur l'abonne suivant.
    MSISDN="$(vty "$MSC_VTY" "show subscriber imsi $IMSI" | sed -n 's/^ *MSISDN: *\([0-9]*\).*/\1/p' | head -1)"
    if [ "$att" = 1 ]; then verdict attache OK "MM « $mm », IMSI $IMSI au VLR, MSISDN ${MSISDN:-?}"
    else verdict attache ECHEC "MM « ${mm:-?} », IMSI $IMSI $(printf '%s' "$cache" | grep -q "$IMSI" && echo au VLR || echo absent du VLR)"; fi
}
