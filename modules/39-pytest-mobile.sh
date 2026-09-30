#!/bin/bash
# pytest mobile : osmocon, mobile, camp, LU, chiffrement
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "pytest -m banc_mobile (mode $MODE)"; }
mod_run() { pytest_famille mobile "banc_mobile"; }
