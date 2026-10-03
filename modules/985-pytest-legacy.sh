#!/bin/bash
# pytest legacy : l'ancienne suite (qemu/tests, banc en conteneur) — seulement avec --legacy
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "ancienne suite qemu/tests (--legacy)"; }
mod_run() {
    if [ "${LEGACY:-0}" != 1 ]; then verdict pytest-legacy SAUTE "sans --legacy (suite ecrite pour l'ancien banc en conteneur)"; return; fi
    pytest_famille legacy "not banc_actif" legacy
}
