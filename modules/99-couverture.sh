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
#     ATTENDU ABSENT  rien dans le journal, et c'est le comportement attendu :
#                 garde (ligne sans motif de preuve) qui n'a pas joue, note
#                 « attendu absent », ou marqueur @absent_si=journal:motif@ verifie
#                 (ex. GAPK a 0 parce que la ROM vocode : lignes [vsp])
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
# (la note peut porter « @absent_si=journal:motif@ » : si ce motif est dans ce
#  journal, une ligne sans preuve ni symptome est ATTENDU ABSENT, pas NON OBSERVE)
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
TCH/F descendant : qualite (B_BFI);ROM TI;dsp;\[a_dd\].*BFI=0;bfi=[1-9];B_BFI juste depuis qosmo a19dde59 (MVKD/MVDK sous RPT) : restent les trames vraiment mauvaises (c214) et les vols FACCH (8084), masquees par layer1.highram_patched
FACCH montant;firmware -> montant.c;dsp;\[montant\] FACCH UL;FACCH montante ECARTEE;
SACCH montant en TCH;firmware -> montant.c;dsp;\[montant\] SACCH UL;Radio link lost signal\|LOS during dedicated;README : correctif MVKD/MVDK, point ouvert n°2
garde MVKD/MVDK;qosmo c54x_exec.c;qemu;;\[garde-3d89\];une ligne = la garde a joue
parole montante;ROM : bursts TCH bruts (PONT_UL_RAW_TCH=1), sinon hote montant.c -> pont tch_fr_encode;pont;TCH ul rom F=[0-9]* S=[0-9]* P=[1-9]\|hote F=[0-9]* S=[0-9]* P=[1-9];;[2026-10-18] preuve = compteur P (trames de parole) des STATS du pont, chemin ROM ou hote ; l ancien motif « [montant] parole UL » n existe que sur le chemin hote
vocodage;GAPK du mobile (FR) sur les trames TI de la ROM (io-tch-format ti);mobile;format/ti-fr;;[2026-10-15] preuve = chaine GAPK preparee dans le journal du mobile (avant : 3 lignes fixes de la conf) ; attendu absent quand la ROM vocode elle-meme (lignes [vsp]) @absent_si=dsp:\[vsp\] fn=[0-9]* sur 1000 trames : rint=[1-9]@
saut de frequence;pont : NON GERE;pont;;saut de frequence : TCH non arme;hors de ce montage
marge temps reel DSP;c54x_exe [chrono];dsp;\[chrono\];pire trame [0-9]\{3,\}\.\|DSP >4.62 ms [1-9];README : 4.3-4.6 ms de travail pour 4.62 ms ; [2026-10-18] symptome = trames DSP hors budget 4.62 ms, ou blocage >= 100 ms (l1_sync « GO envoye quand meme »)
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
descendant : IMMEDIATE ASSIGNMENT;ROM : reference identique a last_rach (RACH de la ROM a son fn) sinon retouche hote (qosmo calypso_trx.c);qemu;identique a last_rach;-> [0-9]*/[0-9]*/[0-9]* (last_rach;[2026-10-15] motifs des deux chemins (avant : seul l hote etait compte)
descendant : FACCH/F;ROM (a_fd);dsp;\[a_fd\];;
descendant : TCH/F parole;ROM (a_dd, Viterbi, lu tel quel par le firmware);dsp;\[a_dd\];;B_BFI juste (qosmo a19dde59), trames B_BFI masquees par layer1.highram_patched ; trames c200 identiques a la reference (2023/2025, 2026-10-03)
descendant : A5;ROM + coprocesseur A5 modelise (calypso_a5.c);dsp;\[a5\] .*A5/;;le pont ne dechiffre pas (PONT_DSP_DECHIFFRE=0)
montant : RACH;ROM : access-burst du script TSP (calypso_tx_rom, PONT_UL_RAW=1) emis tel quel;pont;=AIR rom rach=;;[2026-10-15] compteurs AIR du pont (bursts remis au TRX) ; le rach= du chemin hote tombe dans le puits
montant : SDCCH/SACCH codage canal;ROM : bursts finaux (calypso_tx_rom, PONT_UL_RAW=1) emis tels quels;pont;=AIR rom rach=[0-9]* xcch=;;[2026-10-15] compteurs AIR ; xCCH hote/rom_ko = ombre 0x3f8a, jamais emise
montant : A5;ROM : bursts NB marques chiffres par le coprocesseur A5 (calypso_a5.c -> tx_tsp_publier bit 7);pont;=A5 ul rom=;;[2026-10-15] hote = A5 du TCH (A5 ul hote_tch=, lignes TCH ci-dessous) ; sous PONT_UL_RAW=1 aucun xCCH chiffre par l hote
montant : FACCH/F;ROM avec PONT_UL_RAW_TCH=1 + CALYPSO_C54X_BCTC_NORM=1 (sinon hote : montant.c a_fu -> pont TchScheduler);pont;=TCH ul rom F=;=TCH ul rom F=[0-9]* S=[0-9]* P=[0-9]* jete F=[0-9]* S=[0-9]* P=[0-9]* hote F=;F = stealing flag leve (bits 60/87) ; bursts ROM ecartes : TCH ul ... jete F=
montant : SACCH en TCH;ROM avec PONT_UL_RAW_TCH=1 (sinon hote : pont gsm.xcch_encode);pont;=TCH ul rom F=[0-9]* S=;=TCH ul rom F=[0-9]* S=[0-9]* P=[0-9]* jete F=[0-9]* S=[0-9]* P=[0-9]* hote F=[0-9]* S=;S = fn%26 12/25 ; bursts ROM ecartes : TCH ul ... jete S=
montant : TCH/F parole;ROM avec PONT_UL_RAW_TCH=1 + CALYPSO_C54X_BCTC_NORM=1 + CALYPSO_NORM_TC=0 (sinon hote : montant.c TI -> FR -> pont tch_fr_encode);pont;=TCH ul rom F=[0-9]* S=[0-9]* P=;=TCH ul rom F=[0-9]* S=[0-9]* P=[0-9]* jete F=[0-9]* S=[0-9]* P=[0-9]* hote F=[0-9]* S=[0-9]* P=;P = ni SACCH ni stealing flag ; [2026-10-15] marqueur de trame de parole PROM0 0x90a0 (BC apres NORM) : sans BCTC_NORM la ROM n emet pas la parole
vocodage : port voix ROM (VSP);ROM : codec FR de la ROM, PCM par le port serie SP0 (IT 20, ISR 0xc14a) -- calypso_vsp.c, CALYPSO_VSP=1 + BANC_VOCODEUR=rom (mobile en l1phy);dsp;\[vsp\] fn=[0-9]* sur 1000 trames : rint=[1-9];;[2026-10-15] une ligne [vsp] par 1000 trames avec des IT voix servies ; la ligne GAPK ci-dessous doit alors rester a 0
vocodage;hote : GAPK du mobile (trames TI de la ROM);mobile;;chain 'source/alsa -> codec/fr;[2026-10-15] une ligne par session TCH parole (chaine de capture GAPK) ; 0 sans appel ; attendu absent quand la ROM vocode (lignes [vsp]) @absent_si=dsp:\[vsp\] fn=[0-9]* sur 1000 trames : rint=[1-9]@
GPRS descendant : PDTCH CS-1;ROM (tache ALLC, a_cd lu par le firmware -> l1gprs_fw, L1CTL 0x23) - aucun decodeur PDTCH cote hote;modem;Attach success\|Adding address .* to dev tun_modem;;[2026-10-15] journal du modem du barreau data (data-modem.log) ; NON OBSERVE sans le test data. L IMM ASS du CCCH peut etre retouche par qosmo (MONTANT_REQREF)
GPRS montant : PDTCH CS-1;ROM : bursts NB de la ROM pendant que le pont croit le PDCH actif (calypso_tx_rom, PONT_UL_RAW=1);pont;=AIR rom rach=[0-9]* xcch=[0-9]* pdch=;;TS6/TS7 = PDCH de la BTS 0 ; compteur borne par dedicated.pdch() (efface au DCCH_RELEASED)
T
}

# Dernier compteur cumulatif d une ligne STATS du pont : $1 = motif qui finit
# juste avant le nombre (ex. « AIR rom rach= »), $2 = journal. Vide si absent.
val_stats() { grep -a "STATS fn=" "$2" 2>/dev/null | tail -1 | grep -o -- "$1[0-9]*" | grep -o '[0-9]*$'; }

# Une ligne sans preuve ni symptome est-elle une absence ATTENDUE ?
# $1 motif preuve, $2 motif symptome, $3 note, $4 absent_si (« journal:motif »).
# JLOG est celui de mod_run (portee dynamique de bash).
absence_attendue() {
    local aj am asrc
    if [ -n "$4" ]; then
        aj="${4%%:*}"; am="${4#*:}"; asrc="${JLOG[$aj]:-}"
        [ -n "$asrc" ] && [ "$(grep -ac -- "$am" "$asrc" 2>/dev/null)" -gt 0 ]
        return
    fi
    [ -z "$1" ] && [ -n "$2" ] && return 0          # garde : elle n'a pas joue
    case "$3" in *"attendu absent"*) return 0 ;; esac
    return 1
}

# Extrait « @absent_si=journal:motif@ » de la note (variables note / absent_si
# de mod_run) : un marqueur dans la note plutot qu'un 7e champ « ; », parce que
# des notes contiennent deja des « ; » (lus jusqu'ici comme reste du 6e champ).
marqueur_absent() {
    absent_si=""
    case "$note" in *"@absent_si="*)
        absent_si="${note#*@absent_si=}"; absent_si="${absent_si%%@*}"
        note="${note%%@absent_si=*}${note#*@absent_si=*@}"; note="${note% }" ;;
    esac
}

mod_run() {
    local rap="$OUT/couverture.txt" f j src n_p n_s v ligne absent_si n_att=0 n_catt=0
    local fonction qui journal preuve symptome note
    local n_gere=0 n_deg=0 n_non=0 n_obs=0
    declare -A JLOG
    for j in dsp qemu osmocon mobile pont; do JLOG[$j]="$(log_de $j)"; done
    JLOG[cfg]="$MOB_CFG"
    # [2026-10-15] journal du modem GPRS, seulement si le barreau data a tourne
    [ -s "$OUT/data-modem.log" ] && JLOG[modem]="$OUT/data-modem.log"
    {
        echo "couverture couche 1 — mode $MODE — $(date '+%F %T')"
        echo "journaux lus :"
        for j in dsp qemu osmocon mobile pont cfg modem; do
            src="${JLOG[$j]:-}"
            printf '  %-8s %s\n' "$j" "${src:-(absent)}$([ -n "$src" ] && printf '  %s lignes' "$(wc -l < "$src")")"
        done
        echo
        printf '  %-38s %-14s %5s %5s  %s\n' FONCTION VERDICT preuv sympt "QUI (note)"
        while IFS=';' read -r fonction qui journal preuve symptome note; do
            marqueur_absent
            [ -n "$fonction" ] || continue
            case "$journal" in dsp|qemu|osmocon|mobile|pont|cfg|modem) ;;
                *) echo "  !! ligne de table mal formee (champ journal « $journal », un ';' de trop ?) : ${fonction:0:50}" ;; esac
            src="${JLOG[$journal]:-}"; n_p=0; n_s=0
            if [ -n "$src" ]; then
                [ -n "$preuve" ]   && n_p="$(grep -ac -- "$preuve" "$src" 2>/dev/null)"
                [ -n "$symptome" ] && n_s="$(grep -ac -- "$symptome" "$src" 2>/dev/null)"
            fi
            : "${n_p:=0}"; : "${n_s:=0}"
            if   [ -z "$preuve" ] && [ "$n_s" = 0 ] && case "$qui" in *"NON GERE"*) true;; *) false;; esac; then v="NON GERE"
            elif [ "$n_p" -gt 0 ] && [ "$n_s" = 0 ]; then v=GERE; n_gere=$((n_gere+1))
            elif [ "$n_p" -gt 0 ]; then v=DEGRADE; n_deg=$((n_deg+1))
            elif [ "$n_s" -gt 0 ]; then v="NON GERE"; n_non=$((n_non+1))
            elif [ -n "$src" ] && absence_attendue "$preuve" "$symptome" "$note" "$absent_si"; then
                v="ATTENDU ABSENT"; n_att=$((n_att+1))
            elif [ -z "$src" ]; then v="NON OBSERVE"; n_obs=$((n_obs+1)); note="${note:-journal $journal absent}"
            else v="NON OBSERVE"; n_obs=$((n_obs+1)); fi
            [ "$v" = "NON GERE" ] && [ "$n_p" = 0 ] && [ "$n_s" = 0 ] && n_non=$((n_non+1))
            printf '  %-38s %-14s %5s %5s  %s%s\n' "$fonction" "$v" "$n_p" "$n_s" "$qui" "${note:+ — $note}"
        done < <(tableau_$MODE)
        echo
        # Les compteurs bruts qui resument un run, tels que les programmes les
        # ecrivent : la derniere ligne STATS du pont, le dernier [a_dd], [chrono],
        # le bilan montant de c54x_exe.
        echo "derniers compteurs :"
        [ -n "${JLOG[pont]}" ] && grep -a "STATS fn=" "${JLOG[pont]}" | tail -1 | sed 's/^/  pont  /'
        # fifo_drop (pont/record.py) : trames I/Q que la prise optionnelle du
        # visualiseur FFT n'a pas pu livrer (FIFO sans lecteur). Le dire, sinon
        # « 78356/78416 » se lit comme une perte radio.
        [ -n "${JLOG[pont]}" ] && grep -a "STATS fn=" "${JLOG[pont]}" | tail -1 | grep -q "fifo_drop=[1-9]" && \
            echo "  note  fifo_drop = trames I/Q non livrees a la prise du visualiseur FFT (/tmp/iq_fft*.fifo, aucun lecteur) : sans effet sur la chaine radio"
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
        echo "bilan : $n_gere gere, $n_deg degrade, $n_non non gere, $n_att attendu absent, $n_obs non observe"
        echo
        # Chemin ROM / hote, traitement par traitement (voir chemin_$MODE).
        local n_rom=0 n_hote=0 n_mixte=0 n_cobs=0 trait chemin p_rom p_hote r h
        echo "chemin ROM / hote du traitement du signal (mode $MODE) :"
        printf '  %-44s %-14s %5s %5s  %s\n' TRAITEMENT CHEMIN rom hote "ATTENDU (note)"
        while IFS=';' read -r trait chemin journal p_rom p_hote note; do
            marqueur_absent
            [ -n "$trait" ] || continue
            case "$journal" in dsp|qemu|osmocon|mobile|pont|cfg|modem) ;;
                *) echo "  !! ligne de table mal formee (champ journal « $journal », un ';' de trop ?) : ${trait:0:50}" ;; esac
            src="${JLOG[$journal]:-}"; r=0; h=0
            if [ -n "$src" ]; then
                # « =motif » : valeur du compteur sur la DERNIERE ligne STATS du pont
                # (cumulative), pas un nombre de lignes du journal.
                case "$p_rom"  in =*) r="$(val_stats "${p_rom#=}" "$src")" ;;  ?*) r="$(grep -ac -- "$p_rom" "$src" 2>/dev/null)" ;; esac
                case "$p_hote" in =*) h="$(val_stats "${p_hote#=}" "$src")" ;; ?*) h="$(grep -ac -- "$p_hote" "$src" 2>/dev/null)" ;; esac
            fi
            : "${r:=0}"; : "${h:=0}"
            if   [ "$r" -gt 0 ] && [ "$h" -gt 0 ]; then v=MIXTE; n_mixte=$((n_mixte+1))
            elif [ "$r" -gt 0 ]; then v=ROM; n_rom=$((n_rom+1))
            elif [ "$h" -gt 0 ]; then v=HOTE; n_hote=$((n_hote+1))
            elif [ -n "$absent_si" ] && [ -n "$src" ] && absence_attendue "" "" "" "$absent_si"; then
                v="ATTENDU ABSENT"; n_catt=$((n_catt+1))
            else v="NON OBSERVE"; n_cobs=$((n_cobs+1)); fi
            printf '  %-44s %-14s %5s %5s  %s%s\n' "$trait" "$v" "$r" "$h" "$chemin" "${note:+ — $note}"
        done < <(chemin_$MODE)
        [ -n "${JLOG[qemu]:-}" ] && grep -a '^\[pdtch\] ' "${JLOG[qemu]}" | grep -v 'perdu' | tail -1 | sed 's/^/  dernier compteur PDTCH (tap QEMU) : /'
        [ -n "${JLOG[pont]}" ] && grep -a "STATS fn=" "${JLOG[pont]}" | tail -1 | grep -o "xCCH ul [^|]*" | sed 's/^/  dernier compteur pont : /'
        [ -n "${JLOG[pont]}" ] && grep -a "STATS fn=" "${JLOG[pont]}" | tail -1 | grep -oE "(AIR|TCH ul|A5 ul) [^|]*" | sed 's/^/  dernier compteur pont : /'
        # « … non observe » d'abord : dsp-rom-max.sh lit ce prefixe tel quel
        echo "chemin : $n_rom ROM, $n_hote hote, $n_mixte mixte, $n_cobs non observe, $n_catt attendu absent"
        echo "$n_rom $n_hote $n_mixte $n_cobs" > "$OUT/.chemin"
    } > "$rap"     # pas de « | tee » : le sous-shell perdait les compteurs (verdict 0/0/0/0)
    cat "$rap"
    local c; read -r c_rom c_hote c_mixte c_obs < "$OUT/.chemin" 2>/dev/null; rm -f "$OUT/.chemin"
    verdict couverture OK "$n_gere gere, $n_deg degrade, $n_non non gere, $n_att attendu absent, $n_obs non observe ; chemin ${c_rom:-?} ROM ${c_hote:-?} hote ${c_mixte:-?} mixte -> couverture.txt"
}
