#!/bin/bash
# data : GPRS sur le Calypso (QEMU + firmware layer1 GPRS + ROM TI) - attach, PDP, ping par le tunnel
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "bascule du Calypso au modem GPRS, attach, contexte PDP, ping du GGSN et d'Internet par tun_modem"; }
# [2026-10-15] LE CHEMIN PROUVE : modem osmocom-bb (IMSI du mobile) -> L1CTL ->
# firmware layer1.highram.gprs (PDCH CS-1, l1gprs_fw.c) -> c54x_exe + ROM TI
# (blocs PDTCH par les taches DDL/DUL) -> pont_dsp.py (bursts ROM, PONT_UL_RAW)
# -> osmo-bts-trx -> PCU -> SGSN -> GGSN -> apn0. Le mobile est arrete le temps
# du barreau (un seul client de couche 1) puis rendu : la voix reste testable.
# Seulement en DSP, avec le firmware GPRS (FIRMWARE_ELF=...gprs.elf).
# Releves (/root/banc-max-<date>/) : data-mode.txt, data-modem.log, data-ping.txt
DATA_PDP_MAX="${DATA_PDP_MAX:-300}"
# Borne du barreau > ses propres attentes (bascule + PDP_MAX + pings + retour du
# mobile). Avec les 240 s par defaut, banc-max tuait le barreau avant qu'il rende
# le mobile : le Calypso restait au modem et la suite (ms2, pytest) echouait.
MOD_TIMEOUT=$((DATA_PDP_MAX + 240))
mod_run() {
    local mode=/opt/GSM/osmo-operator/scripts/calypso-mode.sh
    # [2026-10-15] seulement sur demande explicite : --data (ou --only=...data...)
    if [ "${DATA:-0}" != 1 ] && ! liste_contient "${ONLY:-}" data; then verdict data SAUTE "sans --data"; return; fi
    [ "$MODE" = dsp ] || { verdict data SAUTE "GPRS sur le Calypso : mode dsp seulement (ici $MODE)"; return; }
    [ -x "$mode" ] || [ -r "$mode" ] || { verdict data ECHEC "$mode absent"; return; }
    command -v modem >/dev/null 2>&1 || { verdict data ECHEC "binaire modem (osmocom-bb) absent"; return; }
    local qpid fw
    qpid="$(pgrep -f 'qemu-system-arm -M calypso' | head -1)"
    fw="$(tr '\0' ' ' < "/proc/${qpid:-0}/cmdline" 2>/dev/null | grep -o '[^ ]*layer1[^ ]*\.elf' | head -1)"
    case "$fw" in *gprs*) ;; *) verdict data SAUTE "firmware sans GPRS (${fw:-?}) : FIRMWARE_ELF=/opt/GSM/firmware/board/compal_e88/layer1.highram.gprs.elf"; return ;; esac

    local t0 rc pdp ggsn net
    t0="$(date '+%Y-%m-%d %H:%M:%S')"
    say "bascule du Calypso au modem GPRS (attente du PDP, ${DATA_PDP_MAX} s max)"
    timeout "$((DATA_PDP_MAX + 30))" bash "$mode" data --wait > "$OUT/data-mode.txt" 2>&1; rc=$?
    journalctl -u osmo-modem-gprs --since "$t0" -o cat --no-pager 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/data-modem.log"
    pdp="$(ip netns exec msgprs ip -4 -o addr show dev tun_modem 2>/dev/null | awk '{print $4}')"
    if [ "$rc" -ne 0 ] || [ -z "$pdp" ]; then
        local att; att="$(grep -c 'Attach success' "$OUT/data-modem.log")"
        bash "$mode" voix --wait >> "$OUT/data-mode.txt" 2>&1
        # [2026-10-15] compteur PDTCH du tap QEMU (calypso_dcch_tap.c) : pertes ROM ou autre cause ?
        local pdtch; pdtch="$(grep -a '^\[pdtch\] ' "$(log_de qemu)" 2>/dev/null | grep -v 'perdu' | tail -1 | sed 's/^\[pdtch\] [^:]*: //')"
        verdict data ECHEC "pas de PDP en ${DATA_PDP_MAX} s (attach reussis : $att ; T3190 $(grep -c T3190 "$OUT/data-modem.log"), T3168 $(grep -c T3168 "$OUT/data-modem.log"))${pdtch:+ ; PDTCH $pdtch} - mobile rendu"
        return
    fi
    ggsn="$(ip -4 -o addr show apn0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    ip netns exec msgprs ip route replace default dev tun_modem 2>/dev/null
    # NAT du pool vers la sortie (aussi posee par start-direct.sh) : sans --restart
    # la pile peut dater d'avant, et Internet tombait a 0/5. Idempotent.
    local pool; pool="$(awk '/ip prefix dynamic/{print $4; exit}' /etc/osmocom/osmo-ggsn.cfg 2>/dev/null)"
    if [ -n "$pool" ]; then
        sysctl -qw net.ipv4.ip_forward=1 2>/dev/null
        iptables -w -t nat -C POSTROUTING -s "$pool" ! -o apn0 -j MASQUERADE 2>/dev/null \
            || iptables -w -t nat -A POSTROUTING -s "$pool" ! -o apn0 -j MASQUERADE 2>/dev/null
    fi
    { echo "== GGSN $ggsn"; ip netns exec msgprs ping -c5 -i3 -W20 "$ggsn" 2>&1
      echo "== Internet 8.8.8.8"; ip netns exec msgprs ping -c5 -i3 -W20 8.8.8.8 2>&1; } > "$OUT/data-ping.txt"
    local g i rtt
    g="$(awk '/^== GGSN/{f=1} /^== Internet/{f=0} f&&/received/{print $4}' "$OUT/data-ping.txt")"
    i="$(awk '/^== Internet/{f=1} f&&/received/{print $4}' "$OUT/data-ping.txt")"
    rtt="$(grep 'rtt' "$OUT/data-ping.txt" | tail -1 | awk -F'/' '{printf "%.1f s", $5/1000}')"
    # journal du modem recapture APRES les pings (la capture du haut s'arrete au PDP) :
    # la couverture (99-couverture.sh, JLOG[modem]) y lit le GPRS descendant.
    journalctl -u osmo-modem-gprs --since "$t0" -o cat --no-pager 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/data-modem.log"
    bash "$mode" voix --wait >> "$OUT/data-mode.txt" 2>&1
    if [ "${g:-0}" -gt 0 ]; then
        net="$([ "${i:-0}" -gt 0 ] && echo "Internet ${i}/5" || echo "Internet 0/5 (NAT du pool vers la sortie ?)")"
        verdict data OK "PDP $pdp, GGSN ${g}/5, $net, aller-retour moyen ${rtt:-?} - mobile rendu"
    else
        verdict data ECHEC "PDP $pdp mais aucun ping du GGSN (0/5) - mobile rendu"
    fi
}
