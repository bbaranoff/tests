#!/bin/bash
# process `mobile` et sa VTY (4247) qui decrit MS 1 ; en Magnetite : QEMU du telephone + son clavier (pas de VTY)
MOD_RELANCE_PILE=1
mod_titre() { [ "$MOB_CLAVIER" = 1 ] && echo "Magnetite, clavier $MOB_KEYS_SOCK (pas de VTY)" || echo "VTY $MOB_VTY"; }
mod_run() {
    if [ "$MOB_CLAVIER" = 1 ]; then
        # [2026-10-26] Magnetite : pas de process mobile ni de VTY, la pile L23 est dans le firmware.
        # Le telephone existe quand SON QEMU tourne ($MOB_RUNDIR/qemu.pid) et que son clavier ecoute.
        # En mode bts l'instance 2 n'est lancee qu'une fois le firmware trx en mode BTS (jusqu'a
        # 150 s + 10 s, 14-demarrage.sh) : on attend jusqu'a --boot-max au lieu d'echouer tout de suite.
        local i pid=""
        for i in $(seq 1 "$BOOT_MAX"); do
            pid="$(cat "$MOB_RUNDIR/qemu.pid" 2>/dev/null)"
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -S "$MOB_KEYS_SOCK" ] && break
            pid=""; sleep 1
        done
        if [ -z "$pid" ]; then
            verdict mobile ECHEC "Magnetite absent apres ${BOOT_MAX}s : $MOB_RUNDIR/qemu.pid ($(cat "$MOB_RUNDIR/qemu.pid" 2>/dev/null || echo aucun)) ou clavier $MOB_KEYS_SOCK muet"
            return
        fi
        cp "$MOB_RUNDIR/rvinterf.log" "$OUT/rvinterf-initial.log" 2>/dev/null
        if vivant rvinterf; then verdict mobile OK "Magnetite : QEMU pid $pid, clavier $MOB_KEYS_SOCK, rvinterf (traces L1 TI) apres ${i}s, IMSI ${IMSI:-?} (SIM emulee = MS#1)"
        else verdict mobile OK "Magnetite : QEMU pid $pid, clavier $MOB_KEYS_SOCK apres ${i}s ; rvinterf absent (pas de traces L1), IMSI ${IMSI:-?}"; fi
        return
    fi
    if ! vivant "mobile"; then verdict mobile ECHEC "process mobile absent"; return; fi
    if ! port_ouvert "$MOB_VTY"; then verdict mobile ECHEC "process present mais VTY $MOB_VTY muette"; return; fi
    local ms; ms="$(show_ms)"; printf '%s\n' "$ms" > "$OUT/show-ms-initial.txt"
    if printf '%s' "$ms" | grep -q "MS '1' is"; then verdict mobile OK "VTY $MOB_VTY repond, IMSI ${IMSI:-?}"
    else verdict mobile ECHEC "VTY $MOB_VTY ne decrit pas MS 1"; fi
}
