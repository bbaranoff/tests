#!/bin/bash
# pytest couche1 : couche 1 du mode, lue dans ses journaux (grgsm ou dsp)
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "pytest -m banc_couche1 (mode $MODE)"; }
mod_run() { pytest_famille couche1 "banc_couche1"; }
