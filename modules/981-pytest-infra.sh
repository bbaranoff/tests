#!/bin/bash
# pytest infra : demons, VTY, BTS, services, audio
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "pytest -m banc_infra (mode $MODE)"; }
mod_run() { pytest_famille infra "banc_infra"; }
