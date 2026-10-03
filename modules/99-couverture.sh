#!/bin/bash
# couverture couche 1 : ce que ce montage prend en charge, ce qu'il ne prend pas, et ce que le journal en prouve
MOD_CHAINE=0; MOD_OPTIONNEL=1
mod_titre() { echo "qui fait quoi en $MODE, et par quel chemin (ROM ou hote), d'apres les journaux"; }
#
# UNE LIGNE PAR FONCTION DE LA COUCHE 1 (et des couches qu'elle porte). Pour
# chaque fonction on dit QUI la fait dans ce montage, et on compte dans le
# journal designe les lignes qui la PROUVENT (preuve) ou qui la CONTREDISENT
# (symptome). Les motifs sont les chaines ecrites par les programmes eux-memes
# (c54x_exe/src/montant.c, pont/*.py, qosmo calypso_l1_grgsm.c, osmocom-bb
# mobile) — pas des paraphrases.
#
#   verdict par ligne :
#     GERE        au moins une preuve, aucun symptome
#     DEGRADE     preuve(s) ET symptome(s)
#     NON GERE    la fonction est hors de ce montage (dit par la doc), ou un
#                 symptome sans aucune preuve
#     NON OBSERVE rien dans le journal : pas exerce par ce run, ou pas journalise
#
# [2026-10-03] « Kc lache » n'est PAS un symptome en soi : le pont lache la cle a
# chaque fin de session dedie (« canal libere par le mobile ») et a chaque
# IMMEDIATE ASSIGNMENT (la session suivante demarre en clair, jusqu'au prochain
# CIPHERING MODE COMMAND) - une fois par session, comme les « chiffrement
# descendant confirme » (20 contre 23 sur un run grgsm). Compter tous les lachers
# comme des symptomes classait « DEGRADE » un chiffrement qui marchait. Seul le
# repli « CHANNEL RELEASE sans liberation du mobile » (pont/uplink.py) signale
# un canal reste ouvert et une cle gardee : c'est lui qu'on cherche.
# Format d'une ligne du tableau :  fonction;qui;journal;motif preuve;motif symptome;note
# (separateur « ; » : les motifs grep contiennent des alternances « \| », qu'un
# separateur « | » coupait en deux champs — SMS, SDCCH descendant, SACCH en TCH
# et retour BSP etaient lus de travers jusqu'au 2026-09-29)
tableau_grgsm() { cat <<'T'
FB (FCCH) detection;gr-gsm dans QEMU;qemu;synchro gr-gsm : ARFCN=;;
SB (SCH) decodage, BSIC;gr-gsm dans QEMU;qemu;synchro gr-gsm : ARFCN=.*BSIC=;;
backend L1 annonce;qosmo (GSMTAP 4730, SCH 4731);qemu;backend gr-gsm;;
BCCH SI1/2/4 decodes;pont -> GSMTAP -> mobile;mobile;New SYSTEM INFORMATION [124];;
SACCH SI5/6 (canal dedie);pont -> mobile;mobile;New SYSTEM INFORMATION [56];;
RACH montant;firmware -> pont (side-band calypso_rach);pont;rach=[1-9];LOS during RACH request;compte dans STATS
IMMEDIATE ASSIGNMENT;pont (AGCH);pont;IMMEDIATE ASSIGNMENT;IMMEDIATE ASSIGNMENT REJECT;
SDCCH descendant;pont (decodage, GSMTAP);pont;SDCCH8\|CCCH+SDCCH4;SDCCH DL : anneau plein;
SDCCH montant;pont (bloc L2 du firmware);pont;bloc montant du mobile sur le SDCCH;SDCCH montant : aucun canal dedie;
authentification;MSC <-> SIM emulee (QEMU);mobile;AUTHENTICATION REQUEST;;
chiffrement A5 : Kc publie;firmware -> qosmo (calypso_kc_l1);qemu;chiffrement A5/;;
chiffrement A5 : dechiffrement DL;pont (le DSP n'existe pas ici);pont;chiffrement descendant confirme par la BTS;Kc lache (CHANNEL RELEASE sans liberation;
CIPHERING MODE COMPLETE;mobile;mobile;CIPHERING MODE COMPLETE;;
LOCATION UPDATING ACCEPT;mobile <-> MSC;mobile;LOCATION UPDATING ACCEPT;LOCATION UPDATING REJECT;
TMSI attribue;mobile;mobile;got TMSI;;
SMS (SM-CP/RP);mobile <-> MSC;mobile;MMSMS_EST_REQ\|MMSMS_DATA_REQ;MNSMS-ERROR-IND\|SMS to .* failed;DMM : connexion MM pour le SMS
appel : SETUP / PROCEEDING;mobile <-> MSC;mobile;received CALL PROCEEDING;;
appel : ALERTING / CONNECT;mobile <-> MSC;mobile;received CONNECT;;
ASSIGNMENT COMMAND (TCH);pont (arme le TCH);pont;ASSIGNMENT COMMAND : TCH;ASSIGNMENT FAILURE sur le SDCCH;
ASSIGNMENT COMPLETE;mobile -> pont;mobile;ASSIGNMENT COMPLETE (cause;ASSIGNMENT FAILURE;le pont ne suffixe pas sa ligne FACCH (uplink.py:275), preuve lue chez le mobile
TCH ouvert cote QEMU;qosmo (calypso_tch_dl);qemu;canal TCH : TN=;TCH DL : .* trames sautees;
TCH/F descendant : decodage canal;pont (libosmocoding);pont;TCH dl=[1-9];;compteur STATS
TCH/F descendant : CRC;pont;pont;;TCH dl=.*crc=[1-9];echecs CRC normaux tant que le RTP ne coule pas
FACCH descendant;pont;pont;CHANNEL RELEASE (FACCH);;
FACCH montant;firmware -> pont;pont;FACCH montante;FACCH montante ECARTEE;
SACCH montant en TCH;firmware -> pont;pont;SACCH ul=[1-9];Radio link lost signal\|LOS during dedicated;
parole montante;firmware -> pont (bursts UL);pont;UL bursts=[1-9];;compteur STATS
vocodage;GAPK sur l'hote, trames RTP (io-tch-format rtp);cfg;io-tch-format rtp;;le mobile code/decode lui-meme
saut de frequence;pont : NON GERE;pont;;saut de frequence : TCH non arme;hors de ce montage
CHANNEL RELEASE;pont;pont;CHANNEL RELEASE;CHANNEL RELEASE sans liberation du mobile;
liberation radio cote mobile;mobile;mobile;new state dedicated -> release pending\|Returning to IDLE mode;;DRR (DSUM n'est pas journalise)
T
}
tableau_dsp() { cat <<'T'
API RAM partagee ARM <-> DSP;qosmo + c54x_exe;qemu;pont DSP : API RAM partagee;;
tache FB postee par l'ARM;firmware (layer1);dsp;tache FB postee par l'ARM;;
FB (FCCH) detection;ROM TI dans c54x_exe (d_fb_det);dsp;\[jalon\] fn=[0-9]* d_fb_det=1;;
tache SB postee par l'ARM;firmware;dsp;tache SB postee par l'ARM;;fenetre SB rarement armee (README)
SB (SCH) decodage, BSIC;ROM TI (a_sch);dsp;SB PLAUSIBLE;a_sch *: jamais ecrit;
BCCH SI1/2/4 decodes;ROM TI (decodage canal) -> firmware -> mobile;mobile;New SYSTEM INFORMATION [124];;
SACCH SI5/6 (canal dedie);ROM TI -> mobile;mobile;New SYSTEM INFORMATION [56];;
RACH montant;firmware -> DSP (d_rach) -> montant.c -> pont;dsp;\[montant\] RACH ra=;LOS during RACH request;
IMMEDIATE ASSIGNMENT;pont (AGCH) -> DSP;pont;IMMEDIATE ASSIGNMENT;IMMEDIATE ASSIGNMENT REJECT;
canal dedie SDCCH : BSP;ROM TI suit la tache du firmware;dsp;\[montant\] canal dedie .*SDCCH;;
SDCCH descendant;ROM TI (decodage canal);pont;SDCCH8\|CCCH+SDCCH4;;README : blocs jetes sur SDCCH/8 (suspect)
SDCCH montant;firmware -> montant.c (a_cu);dsp;\[montant\] SDCCH UL;;
authentification;MSC <-> SIM emulee (QEMU);mobile;AUTHENTICATION REQUEST;;
chiffrement A5 : Kc vers le DSP;firmware -> API RAM (a_kc);dsp;\[a5-arm\];;
chiffrement A5 : coprocesseur;calypso_a5.c dans c54x_exe;dsp;\[montant\] chiffrement A5/;;CALYPSO_A5=0 le coupe
chiffrement A5 : confirme par la BTS;pont;pont;chiffrement descendant confirme par la BTS;Kc lache (CHANNEL RELEASE sans liberation;
CIPHERING MODE COMPLETE;mobile;mobile;CIPHERING MODE COMPLETE;;
LOCATION UPDATING ACCEPT;mobile <-> MSC;mobile;LOCATION UPDATING ACCEPT;LOCATION UPDATING REJECT;
TMSI attribue;mobile;mobile;got TMSI;;
SMS (SM-CP/RP);mobile <-> MSC;mobile;MMSMS_EST_REQ\|MMSMS_DATA_REQ;MNSMS-ERROR-IND\|SMS to .* failed;DMM : connexion MM pour le SMS
appel : SETUP / PROCEEDING;mobile <-> MSC;mobile;received CALL PROCEEDING;;
appel : ALERTING / CONNECT;mobile <-> MSC;mobile;received CONNECT;;
ASSIGNMENT COMMAND (TCH);pont annonce au DSP;pont;ASSIGNMENT COMMAND : TCH;ASSIGNMENT FAILURE sur le SDCCH;
bascule BSP -> TCH;ROM TI suit la tache TCHT/TCHA du firmware;dsp;\[montant\] TCH : le firmware poste la tache;;
ASSIGNMENT COMPLETE;mobile -> pont;mobile;ASSIGNMENT COMPLETE (cause;ASSIGNMENT FAILURE;le pont ne suffixe pas sa ligne FACCH (uplink.py:275), preuve lue chez le mobile
TCH/F descendant : decodage canal;ROM TI (Viterbi);dsp;\[a_dd\];;
TCH/F descendant : qualite (B_BFI);ROM TI;dsp;;bfi=[1-9];README : B_BFI sur toute la parole, point ouvert n°1
FACCH montant;firmware -> montant.c;dsp;\[montant\] FACCH UL;FACCH montante ECARTEE;
SACCH montant en TCH;firmware -> montant.c;dsp;\[montant\] SACCH UL;Radio link lost signal\|LOS during dedicated;README : correctif MVKD/MVDK, point ouvert n°2
garde MVKD/MVDK;qosmo c54x_exec.c;qemu;;\[garde-3d89\];une ligne = la garde a joue
parole montante;firmware -> montant.c (anneau calypso_tch_ul);dsp;\[montant\] parole UL;;
vocodage;ROM TI, trames TI converties TI -> FR sur l'hote (io-tch-format ti);cfg;io-tch-format ti;;
saut de frequence;pont : NON GERE;pont;;saut de frequence : TCH non arme;hors de ce montage
marge temps reel DSP;c54x_exe [chrono];dsp;\[chrono\];;README : 4.3-4.6 ms de travail pour 4.62 ms
CHANNEL RELEASE;pont;pont;CHANNEL RELEASE;CHANNEL RELEASE sans liberation du mobile;
retour BSP sur le SDCCH;ROM TI (tache ALLC);dsp;BSP rendu au SDCCH\|revenu sur le SDCCH;;attendu absent : seul un ASSIGNMENT FAILURE (retour a l'ancien canal, 04.08 3.4.3.3) y mene, un appel normal finit par CHANNEL RELEASE
liberation radio cote mobile;mobile;mobile;new state dedicated -> release pending\|Returning to IDLE mode;;DRR (DSUM n'est pas journalise)
T
}
# ── CHEMIN ROM / HOTE ───────────────────────────────────────────────────────
# [2026-10-03] Le tableau ci-dessus dit QUI fait une fonction ; celui-ci tranche, traitement par
# traitement, si le TRAITEMENT DU SIGNAL (codage/decodage canal, chiffrement) est fait par la ROM TI
# du DSP ou reconstruit par l'hote (pont.py, c54x_exe, qosmo) — et le prouve par le journal du run.
# Format :  traitement;chemin attendu;journal;motif preuve ROM;motif preuve HOTE;note
#   verdict : ROM (preuve ROM seule), HOTE (preuve hote seule), MIXTE (les deux dans le run),
#             NON OBSERVE (aucune). Une ligne sans motif ROM est un chemin hote PAR CONSTRUCTION
#             (la ROM n'y est pas branchee) : la preuve hote dit seulement qu'il a servi.
# Sources du descendant : rapport du 2026-10-03 (pont/dsp/downlink.py : en dsp le decodage du pont
# ne sert qu'aux STATS, rien n'est livre a QEMU ; le firmware lit a_cd/a_fd/a_dd de la ROM).
chemin_grgsm() { cat <<'T'
FB/SB : detection, BSIC;hote : gr-gsm dans QEMU;qemu;;synchro gr-gsm : ARFCN=;
descendant : decodage canal (BCCH/CCCH/SDCCH/SACCH);hote : pont (libosmocoding) -> GSMTAP;pont;;STATS fn=.*blocs=[1-9];
descendant : TCH/F parole;hote : pont (libosmocoding);pont;;TCH dl=[1-9];
descendant : A5;hote : pont;pont;;A5 dl=[1-9];
montant : RACH;hote : pont (gsm.rach_burst);pont;;rach=[1-9];
montant : SDCCH/SACCH codage canal;hote : pont (gsm.xcch_encode);pont;;xCCH ul rom=0 hote=[1-9]\|SDCCH4\|SDCCH8;
montant : FACCH / SACCH en TCH / parole;hote : pont (TchScheduler);pont;;FACCH ul=[1-9]\|TCH dl=.* bursts=[1-9];
montant : A5;hote : pont;pont;;A5 dl=[0-9]* ul=[1-9];
T
}
chemin_dsp() { cat <<'T'
FB : detection;ROM (d_fb_det);dsp;d_fb_det=1;;
SB/SCH : decodage, BSIC;ROM (a_sch) sinon SB en conserve;dsp;CRC_OK;\[can-sb\];conserve = hacks CAN_* (pont.c)
descendant : BCCH/CCCH/SDCCH/SACCH;ROM (a_cd lu par le firmware);dsp;\[a_cd\];;SACCH/8 souvent FIRE KO (rapport 2026-10-03)
descendant : IMMEDIATE ASSIGNMENT;ROM + retouche hote de la reference (qosmo calypso_trx.c);qemu;;IMM ASS ra=.*reference;l'hote reecrit la reference de requete lue dans a_cd
descendant : FACCH/F;ROM (a_fd);dsp;\[a_fd\];;
descendant : TCH/F parole;ROM (a_dd, Viterbi, lu tel quel par le firmware);dsp;\[a_dd\];;B_BFI pose a tort sur toute la parole (le firmware l'ignore) ; bit-exactitude mesuree le 2026-09-30, a re-mesurer
descendant : A5;ROM + coprocesseur A5 modelise (calypso_a5.c);dsp;\[a5\] .*A5/;;le pont ne dechiffre pas (PONT_DSP_DECHIFFRE=0)
montant : RACH;hote : montant.c lit d_rach, pont code (gsm.rach_burst);pont;;rach=[1-9];calypso_bsp_tx_rach_burst = code mort
montant : SDCCH/SACCH codage canal;ROM (bursts 0x3f8a, rom-ul) sinon hote;pont;xCCH ul rom=[1-9];xCCH ul rom=[0-9]* hote=[1-9];MIXTE = des blocs repartis codes par l'hote (bursts ROM absents ou sans CRC)
montant : A5;hote : le pont defait le XOR de la ROM et rechiffre au fn de l'air;pont;;A5 dl=[0-9]* ul=[1-9];la ROM chiffre a l'heure du DSP, pas au fn emis
montant : FACCH/F;hote : montant.c (a_cu) -> pont (TchScheduler);pont;;FACCH ul=[1-9];
montant : SACCH en TCH;hote : pont (gsm.xcch_encode);pont;;SACCH ul=[1-9];
montant : TCH/F parole;hote : montant.c (TI -> FR) -> pont (tch_fr_encode);pont;;TCH dl=.* bursts=[1-9];
vocodage;hote : GAPK du mobile (trames TI de la ROM);cfg;;io-tch-format ti;
T
}

mod_run() {
    local rap="$OUT/couverture.txt" f j src n_p n_s v ligne
    local fonction qui journal preuve symptome note
    local n_gere=0 n_deg=0 n_non=0 n_obs=0
    declare -A JLOG
    for j in dsp qemu osmocon mobile pont; do JLOG[$j]="$(log_de $j)"; done
    JLOG[cfg]="$MOB_CFG"
    {
        echo "couverture couche 1 — mode $MODE — $(date '+%F %T')"
        echo "journaux lus :"
        for j in dsp qemu osmocon mobile pont cfg; do
            src="${JLOG[$j]}"
            printf '  %-8s %s\n' "$j" "${src:-(absent)}$([ -n "$src" ] && printf '  %s lignes' "$(wc -l < "$src")")"
        done
        echo
        printf '  %-38s %-12s %5s %5s  %s\n' FONCTION VERDICT preuv sympt "QUI (note)"
        while IFS=';' read -r fonction qui journal preuve symptome note; do
            [ -n "$fonction" ] || continue
            src="${JLOG[$journal]}"; n_p=0; n_s=0
            if [ -n "$src" ]; then
                [ -n "$preuve" ]   && n_p="$(grep -ac -- "$preuve" "$src" 2>/dev/null)"
                [ -n "$symptome" ] && n_s="$(grep -ac -- "$symptome" "$src" 2>/dev/null)"
            fi
            : "${n_p:=0}"; : "${n_s:=0}"
            if   [ -z "$preuve" ] && [ "$n_s" = 0 ] && case "$qui" in *"NON GERE"*) true;; *) false;; esac; then v="NON GERE"
            elif [ "$n_p" -gt 0 ] && [ "$n_s" = 0 ]; then v=GERE; n_gere=$((n_gere+1))
            elif [ "$n_p" -gt 0 ]; then v=DEGRADE; n_deg=$((n_deg+1))
            elif [ "$n_s" -gt 0 ]; then v="NON GERE"; n_non=$((n_non+1))
            elif [ -z "$src" ]; then v="NON OBSERVE"; n_obs=$((n_obs+1)); note="${note:-journal $journal absent}"
            else v="NON OBSERVE"; n_obs=$((n_obs+1)); fi
            [ "$v" = "NON GERE" ] && [ "$n_p" = 0 ] && [ "$n_s" = 0 ] && n_non=$((n_non+1))
            printf '  %-38s %-12s %5s %5s  %s%s\n' "$fonction" "$v" "$n_p" "$n_s" "$qui" "${note:+ — $note}"
        done < <(tableau_$MODE)
        echo
        # Les compteurs bruts qui resument un run, tels que les programmes les
        # ecrivent : la derniere ligne STATS du pont, le dernier [a_dd], [chrono],
        # le bilan montant de c54x_exe.
        echo "derniers compteurs :"
        [ -n "${JLOG[pont]}" ] && grep -a "STATS fn=" "${JLOG[pont]}" | tail -1 | sed 's/^/  pont  /'
        if [ "$MODE" = dsp ] && [ -n "${JLOG[dsp]}" ]; then
            grep -a "\[a_dd\]" "${JLOG[dsp]}"  | tail -1 | sed 's/^ */  dsp   /'
            grep -a "\[chrono\]" "${JLOG[dsp]}" | tail -1 | sed 's/^ */  dsp   /'
            grep -a "montant publie" "${JLOG[dsp]}" | tail -1 | sed 's/^ */  dsp   /'
            grep -a "d_fb_det leve\|a_sch change" "${JLOG[dsp]}" | tail -2 | sed 's/^ */  dsp   /'
        fi
        if [ -n "${JLOG[mobile]}" ]; then
            printf '  mobile LU ACCEPT=%s  CIPHER COMPLETE=%s  CALL PROCEEDING=%s  CONNECT=%s  LOS=%s\n' \
                "$(grep -ac 'LOCATION UPDATING ACCEPT' "${JLOG[mobile]}")" \
                "$(grep -ac 'CIPHERING MODE COMPLETE' "${JLOG[mobile]}")" \
                "$(grep -ac 'received CALL PROCEEDING' "${JLOG[mobile]}")" \
                "$(grep -a 'received CONNECT' "${JLOG[mobile]}" | grep -vc ACKNOWLEDGE)" \
                "$(grep -ac 'Radio link lost signal\|LOS during' "${JLOG[mobile]}")"
        fi
        echo
        echo "bilan : $n_gere gere, $n_deg degrade, $n_non non gere, $n_obs non observe"
        echo
        # Chemin ROM / hote, traitement par traitement (voir chemin_$MODE).
        local n_rom=0 n_hote=0 n_mixte=0 n_cobs=0 trait chemin p_rom p_hote r h
        echo "chemin ROM / hote du traitement du signal (mode $MODE) :"
        printf '  %-44s %-11s %5s %5s  %s\n' TRAITEMENT CHEMIN rom hote "ATTENDU (note)"
        while IFS=';' read -r trait chemin journal p_rom p_hote note; do
            [ -n "$trait" ] || continue
            src="${JLOG[$journal]}"; r=0; h=0
            if [ -n "$src" ]; then
                [ -n "$p_rom" ]  && r="$(grep -ac -- "$p_rom" "$src" 2>/dev/null)"
                [ -n "$p_hote" ] && h="$(grep -ac -- "$p_hote" "$src" 2>/dev/null)"
            fi
            : "${r:=0}"; : "${h:=0}"
            if   [ "$r" -gt 0 ] && [ "$h" -gt 0 ]; then v=MIXTE; n_mixte=$((n_mixte+1))
            elif [ "$r" -gt 0 ]; then v=ROM; n_rom=$((n_rom+1))
            elif [ "$h" -gt 0 ]; then v=HOTE; n_hote=$((n_hote+1))
            else v="NON OBSERVE"; n_cobs=$((n_cobs+1)); fi
            printf '  %-44s %-11s %5s %5s  %s%s\n' "$trait" "$v" "$r" "$h" "$chemin" "${note:+ — $note}"
        done < <(chemin_$MODE)
        [ -n "${JLOG[pont]}" ] && grep -a "STATS fn=" "${JLOG[pont]}" | tail -1 | grep -o "xCCH ul [^|]*" | sed 's/^/  dernier compteur pont : /'
        echo "chemin : $n_rom ROM, $n_hote hote, $n_mixte mixte, $n_cobs non observe"
        echo "$n_rom $n_hote $n_mixte $n_cobs" > "$OUT/.chemin"
    } > "$rap"     # pas de « | tee » : le sous-shell perdait les compteurs (verdict 0/0/0/0)
    cat "$rap"
    local c; read -r c_rom c_hote c_mixte c_obs < "$OUT/.chemin" 2>/dev/null; rm -f "$OUT/.chemin"
    verdict couverture OK "$n_gere gere, $n_deg degrade, $n_non non gere, $n_obs non observe ; chemin ${c_rom:-?} ROM ${c_hote:-?} hote ${c_mixte:-?} mixte -> couverture.txt"
}
