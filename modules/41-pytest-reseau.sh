#!/bin/bash
# pytest reseau : VLR, HLR, compteurs MSC, STP/SCCP
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "pytest -m banc_reseau (mode $MODE)"; }
mod_run() { pytest_famille reseau "banc_reseau"; }
