#!/bin/bash
# sms-rafale.sh N [dest] : N SMS MO depuis le mobile du mode en cours, UN PAR UN, en attendant a chaque fois
# « On Network, normal service » (C3 camped + MM idle, normal service, stable) avant d'envoyer, et en
# renvoyant le meme SMS si le reseau le rejette ou si le mobile perd le service pendant l'envoi.
# Chaque SMS ouvre un SDCCH : autant de blocs montants (a_cu) pour la sonde/l'injection du processus DSP
# (PONT_TX_INJECT). SERVICE_STABLE (defaut 3) = nombre de lectures consecutives en service.
N="${1:-20}"; DEST="${2:-100102}"; STABLE="${SERVICE_STABLE:-3}"
if   (echo >/dev/tcp/127.0.0.1/4347) 2>/dev/null; then PORT=4347
elif (echo >/dev/tcp/127.0.0.1/4247) 2>/dev/null; then PORT=4247
else echo "aucune VTY mobile (4347/4247)" >&2; exit 1; fi
vty() { { printf 'enable\n%s\n' "$1"; sleep "${2:-1}"; } | timeout 12 nc -N 127.0.0.1 "$PORT" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'; }
attendre_service() {   # rend 0 des que le mobile est en service STABLE, 1 apres 60 s
    local i bon=0 ms
    for i in $(seq 1 60); do
        ms="$(vty 'show ms 1')"
        if printf '%s' "$ms" | grep -q 'C3 camped normally' && printf '%s' "$ms" | grep -q 'MM idle, normal service'; then
            bon=$((bon + 1)); [ "$bon" -ge "$STABLE" ] && return 0
        else bon=0; fi
    done
    return 1
}
for i in $(seq 1 "$N"); do
    ok=0
    for essai in 1 2 3 4; do
        attendre_service || echo "  (service pas stable apres 60 s, on tente quand meme)"
        sleep 2   # laisser le mobile finir de se poser avant le RACH
        out="$(vty "sms 1 $DEST rafale-$i" 7)"
        if printf '%s' "$out" | grep -q "SMS to $DEST successful"; then ok=1; break; fi
        echo "  SMS $i essai $essai : $(printf '%s' "$out" | grep -o '% SMS[^%]*\|% No service\|% Searching[^%]*' | head -1 | tr -s ' \n' ' ')"
        sleep 2
    done
    echo "SMS $i/$N $([ "$ok" = 1 ] && echo envoye || echo ABANDONNE) (VTY $PORT)"
    sleep 3
done
