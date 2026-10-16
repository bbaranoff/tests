#!/bin/bash
# emulateur : detecteur de bugs d'emulation du DSP C54x (ISA, BC heuristique, codec, temps reel, PDTCH)
MOD_CHAINE=0; MOD_OPTIONNEL=1; MOD_TIMEOUT=420
mod_titre() { echo "suite ISA, rejeu de la capture (BC heuristique), codec voix, marge temps reel, PDTCH"; }
# [2026-10-15] POURQUOI CE BARREAU. Les defauts qui ont bloque la parole et le vocodeur
# n'etaient pas dans le pont ni dans la pile : ils etaient dans l'EMULATEUR du C54x --
# un BC F82x/F83x evalue par une heuristique d'accumulateur au lieu du vrai TC (marqueur
# de trame de parole PROM0 0x90a0, double tampon I/Q 0xb2c7), NORM qui touchait TC, et le
# codec FR qui rend du silence. Ils ne laissent aucune trace dans les journaux du banc :
# les sondes [c54x] de c54x_exe partent sur stderr, que personne ne lit. Ce barreau va
# les chercher, chaque run, par quatre voies independantes, et ecrit emulateur.txt :
#   1. ISA      : tools/isa_test contre la liste des echecs connus (emulateur-isa-reference.txt).
#                 Nouveau FAIL = regression de l'emulateur ; FAIL connu qui passe = progres.
#   2. BC       : rejeu de la capture du run (/dev/shm/calypso_rejeu_tch.bin) avec
#                 CALYPSO_BCTC_SONDE=1 et les drapeaux de la pile vivante : chaque site ou
#                 l'heuristique contredit le vrai TC est un bug d'emulation candidat.
#   3. codec    : lignes [vsp] (CALYPSO_VSP=1) -- micro qui recoit du signal et haut-parleur
#                 a la crete du bruit d'arrondi = decodeur de parole de la ROM silencieux.
#   4. temps reel et PDTCH : [chrono] « DSP >4.62 ms », [pdtch] part de blocs CRC KO.
# Verdict ECHEC si une anomalie d'emulation est trouvee (le detail les liste) ; le barreau
# est optionnel et ne rompt pas la chaine. EMU_REJEU=0 saute le rejeu (~1 min, coeurs E).
EMU_C54X=/opt/GSM/c54x_exe
EMU_REF="$TESTS/modules/emulateur-isa-reference.txt"

emu_isa() {   # -> lignes « ISA ... » ; code 1 si regression
    local f="$OUT/emulateur-isa.txt" ref nouveaux progres total
    # [2026-10-16] la suite tourne avec les drapeaux d'emulation du DSP vivant (CALYPSO_MAC,
    # BCTC_COMBO...) : on juge l'emulateur tel que le banc l'utilise, pas ses valeurs par defaut.
    local pid env_dsp
    pid="$(pgrep -f 'c54x_exe[^ ]* --arm' | head -1)"
    env_dsp="$({ tr '\0' '\n' < "/proc/${pid:-0}/environ"; } 2>/dev/null | grep -E '^CALYPSO_' | tr '\n' ' ')"
    [ -n "$env_dsp" ] || env_dsp="$(grep -E '^CALYPSO_' /etc/default/osmo-banc 2>/dev/null | tr '\n' ' ')"
    ( cd "$EMU_C54X" && make -s isa_test >/dev/null 2>&1 && env $env_dsp ./isa_test tools/isa_tests.txt 2>/dev/null ) > "$f"
    [ -s "$f" ] || { echo "ISA       suite non executable ($EMU_C54X/isa_test)"; return 0; }
    total="$(grep -a "exemples" "$f" | tail -1)"
    ref="$(grep -v '^#' "$EMU_REF" 2>/dev/null | sort -u)"
    nouveaux="$(awk '/^FAIL/{print $2}' "$f" | sort -u | comm -23 - <(printf '%s\n' "$ref"))"
    progres="$(comm -13 <(awk '/^FAIL/{print $2}' "$f" | sort -u) <(printf '%s\n' "$ref"))"
    echo "ISA       $total"
    [ -n "$progres" ] && echo "ISA       progres (FAIL connus qui passent, a retirer de la reference) : $(echo $progres)"
    if [ -n "$nouveaux" ]; then
        echo "ISA       REGRESSION : nouveaux FAIL $(echo $nouveaux)"
        grep -aE "^FAIL +($(echo $nouveaux | tr ' ' '|')) " "$f" | sed 's/^/          /' | cut -c1-160
        return 1
    fi
    return 0
}

emu_bc() {   # rejeu de la capture avec la sonde BC -> lignes « BC ... » ; code 1 si divergences
    [ "${EMU_REJEU:-1}" = 0 ] && { echo "BC        rejeu saute (EMU_REJEU=0)"; return 0; }
    local cap=/dev/shm/calypso_rejeu_tch.bin copie="$OUT/emulateur-rejeu.bin" pid env_dsp sortie
    [ -s "$cap" ] || { echo "BC        pas de capture de rejeu ($cap) : aucun canal dedie dans ce run ?"; return 0; }
    ( cd "$EMU_C54X" && make -s tools/rejeu_banc >/dev/null 2>&1 ) || { echo "BC        tools/rejeu_banc non construit"; return 0; }
    cp "$cap" "$copie" 2>/dev/null || return 0
    # memes drapeaux d'emulation que la pile vivante (CALYPSO_*, MONTANT_*, UL_RAW...)
    pid="$(pgrep -f 'c54x_exe[^ ]* --arm' | head -1)"
    env_dsp="$({ tr '\0' '\n' < "/proc/${pid:-0}/environ"; } 2>/dev/null | grep -E '^(CALYPSO_|MONTANT_)' | grep -v '^CALYPSO_VSP_SHM=' | tr '\n' ' ')"
    sortie="$OUT/emulateur-rejeu.txt"
    env $env_dsp CALYPSO_BCTC_SONDE=1 CALYPSO_VSP_SHM=0 timeout 300 taskset -c 16-31 nice -n 19 \
        "$EMU_C54X/tools/rejeu_banc" "$copie" > "$sortie" 2>&1
    rm -f "$copie"
    local div; div="$(grep -a "^BCTC-SONDE" "$sortie")"
    local plante; plante="$(grep -ac "PLANTAGE\|PAS A L'IDLE" "$sortie")"
    echo "BC        rejeu : $(grep -aE '^(SACCH|PAROLE|TX \()' "$sortie" | tr '\n' ' ' | cut -c1-180)"
    [ "${plante:-0}" -gt 0 ] && echo "BC        DSP hors de son IDLE / plantage au rejeu : $plante ligne(s) (emulateur-rejeu.txt)"
    if [ -n "$div" ]; then
        echo "BC        heuristique ACC contredite par le vrai TC (sites suspects, voir c54x_exec.c BC F82x/F83x) :"
        printf '%s\n' "$div" | sed 's/^BCTC-SONDE /          /'
        return 1
    fi
    echo "BC        aucune divergence heuristique/TC sur les sites executes"
    return 0
}

emu_journaux() {   # -> lignes ; code 1 si anomalie codec
    local dsp qemu r=0 l
    dsp="$(log_de dsp)"; qemu="$(log_de qemu)"
    if [ -n "$dsp" ]; then
        l="$(grep -a '\[chrono\]' "$dsp" | tail -1 | grep -oE 'pire trame [0-9.]+, DSP pire [0-9.]+, trames >5.54 ms [0-9]+/1000, DSP >4.62 ms [0-9]+/1000')"
        [ -n "$l" ] && echo "TEMPS     $l"
        # codec : fenetres [vsp] ou le micro porte du signal mais le haut-parleur reste au bruit d'arrondi
        local vsp; vsp="$(grep -a '\[vsp\] fn=' "$dsp")"
        if [ -n "$vsp" ]; then
            local n_ul n_mut
            n_ul="$(printf '%s\n' "$vsp" | awk '{for(i=1;i<=NF;i++) if($i=="UL") u=$(i+1); if (u+0 > 1000) n++} END{print n+0}')"
            n_mut="$(printf '%s\n' "$vsp" | awk '{for(i=1;i<=NF;i++){ if($i=="UL") u=$(i+1); if($i=="DL") d=$(i+1)}; if (u+0 > 1000 && d+0 < 400) n++} END{print n+0}')"
            echo "CODEC     port voix : $(printf '%s\n' "$vsp" | tail -1 | grep -oE 'rint=[0-9]+.*' | cut -c1-110)"
            if [ "$n_ul" -gt 0 ] && [ "$n_mut" -ge "$n_ul" ]; then
                echo "CODEC     decodeur de parole ROM SILENCIEUX : $n_mut fenetre(s) ou le micro a du signal (crete UL > 1000) et le haut-parleur reste < 400"
                r=1
            elif [ "$n_ul" -gt 0 ]; then
                echo "CODEC     haut-parleur actif quand le micro porte du signal ($((n_ul - n_mut))/$n_ul fenetres)"
            fi
        fi
    fi
    if [ -n "$qemu" ]; then
        l="$(grep -a '^\[pdtch\] ' "$qemu" | grep -v perdu | tail -1)"
        if [ -n "$l" ]; then
            local don ko; don="$(printf '%s' "$l" | grep -oE 'donnees=[0-9]+' | cut -d= -f2)"; ko="$(printf '%s' "$l" | grep -oE 'crc_ko=[0-9]+' | cut -d= -f2)"
            if [ "$((don + ko))" -gt 0 ]; then
                echo "PDTCH     blocs descendants CRC KO : $ko / $((don + ko)) ($((100 * ko / (don + ko))) %) -- sur coax, au-dela de quelques % c'est un chemin, pas du bruit"
            fi
        fi
    fi
    return $r
}

mod_run() {
    [ "$MODE" = dsp ] || { verdict emulateur SAUTE "pas de DSP emule en mode $MODE"; return; }
    local rapport="$OUT/emulateur.txt" pb=()
    {
        echo "detecteur de bugs d'emulation -- $(date '+%F %T')"
        emu_isa      || pb+=("ISA")
        emu_bc       || pb+=("BC")
        emu_journaux || pb+=("codec")
    } > "$rapport" 2>&1
    # les codes de retour sont perdus dans le sous-shell { } > fichier : on relit le rapport
    pb=()
    grep -q "^ISA       REGRESSION" "$rapport" && pb+=("ISA regression")
    grep -q "^BC        heuristique ACC contredite" "$rapport" && pb+=("BC $(grep -c '^          pc=' "$rapport") site(s)")
    grep -q "^CODEC     decodeur de parole ROM SILENCIEUX" "$rapport" && pb+=("codec silencieux")
    sed 's/^/    /' "$rapport"
    if [ "${#pb[@]}" -gt 0 ]; then
        verdict emulateur ECHEC "anomalies : $(IFS=,; echo "${pb[*]}") -> emulateur.txt"
    else
        verdict emulateur OK "$(grep -a '^ISA ' "$rapport" | head -1 | sed 's/^ISA *//') ; aucune divergence BC ; codec non en defaut -> emulateur.txt"
    fi
}
