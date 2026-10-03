#!/bin/bash
# « sms 1 100102 ... » depuis la VTY du mobile : le mobile confirme « SMS to 100102 successful », le reseau remet (MT delivered / sms.txt)
MOD_CHAINE=1
mod_titre() { echo "mobile -> reseau -> 100102"; }
# POURQUOI 100102 ET PAS LE COMPTEUR « SMS MO submitted » DU MSC. Le banc est
# en SMS-over-GSUP : le SUBMIT du mobile part au HLR/proto-SMSC par GSUP et ne
# passe pas par la file SMS du MSC, dont le compteur MO reste a 0 quoi qu'il
# arrive (verifie le 2026-09-29 : « SMS to 100101 successful » cote mobile,
# « SMS MO 0 submitted, SMS MT 1 delivered » cote MSC). La preuve MO est donc
# la reponse du reseau au mobile (RP-ACK -> « % SMS to <n> successful »), et
# l'on vise l'AUTRE abonne du banc, 100102 (MS#2), pour ne pas se remettre le
# message a soi-meme. La remise a 100102 (MT delivered +1, ou sa ligne dans
# sms.txt si MS#2 tourne ici) est notee, pas exigee : sans MS#2 attache, le
# SMS attend au SMSC et le MO n'en est pas moins reussi.
mod_run() {
    local dest="${SMS_DEST:-100102}" out mt_avant mt lignes_avant ok=0 i remis=""
    [ "$MSISDN" = "$dest" ] && dest=100101
    mt_avant="$(msc_ctr "SMS MT" 1)"; : "${mt_avant:=0}"
    lignes_avant="$(cat "$SMS_TXT" 2>/dev/null | wc -l)"
    # [2026-10-03] Jusqu'a 3 envois dans le module : un « LOS during RACH request »
    # (mobile qui perd la cellule au moment du RACH, mode dsp) rend « SMS rejected » ;
    # on attend alors une VRAIE resynchronisation (service stable) et on renvoie, au
    # lieu de laisser le second essai du barreau retomber dans le meme trou.
    local essai
    for essai in 1 2 3; do
        attendre_service 40
        # La reponse arrive en asynchrone sur la VTY : on garde la session ouverte.
        out="$( { printf 'enable\nsms 1 %s banc-max MO %s\n' "$dest" "$STAMP"; sleep 8; } | timeout --foreground 12 nc 127.0.0.1 "$MOB_VTY" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
        printf '%s\n' "$out" >> "$OUT/sms-mo-vty.txt"   # >> : garder la trace de chaque essai
        printf '%s' "$out" | grep -q "SMS to $dest successful" && { ok=1; break; }
        say "SMS MO rejete (essai $essai/3) : $(printf '%s' "$out" | grep -o '% SMS[^%]*' | head -1 | tr -s ' \n' ' ')"
        sleep 3
    done
    for i in $(seq 1 10); do
        mt="$(msc_ctr "SMS MT" 1)"
        [ -n "$mt" ] && [ "$mt" -gt "$mt_avant" ] 2>/dev/null && { remis="MT delivered $mt_avant->$mt"; break; }
        tail -n +$((lignes_avant + 1)) "$SMS_TXT" 2>/dev/null | grep -q "banc-max MO $STAMP" && { remis="recu dans sms.txt"; break; }
    done
    if [ "$ok" = 1 ]; then verdict sms-mo OK "SMS to $dest successful (RP-ACK)${remis:+, $remis}"
    else verdict sms-mo ECHEC "pas de « SMS to $dest successful » : $(printf '%s' "$out" | grep -o '% SMS[^%]*\|% .*fail[^%]*' | head -1 | tr -s ' ')${remis:+ ; $remis}"; fi
}
