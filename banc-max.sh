#!/bin/bash
# =============================================================================
#  /opt/GSM/tests/banc-max.sh — JUSQU'OU MONTE LE BANC ? L'ECHELLE DES ELEMENTS
# =============================================================================
#  Le banc empile une douzaine d'elements qui se conditionnent : sans coeur pas
#  de BTS, sans couche 1 pas de mobile, sans camp pas d'attache, sans attache
#  ni SMS ni appel. Quand « ca ne marche pas », la question utile est JUSQU'OU :
#  le dernier barreau atteint designe le premier element en faute.
#
#  Ce lanceur grimpe l'echelle barreau par barreau — un module par barreau,
#  dans modules/NN-nom.sh, joues dans l'ordre des numeros — et rend le plus
#  haut atteint, jusqu'aux SMS (MO, MT), a l'appel voix, et a l'inter-operateur.
#
#  DEUX COUCHES 1, QUI NE MONTENT PAS A LA MEME HAUTEUR :
#     --grgsm   gr-gsm dans qosmo : QEMU + osmocon + pont.py, mobile VTY 4247.
#               La pile complete, censee aller jusqu'a l'appel.
#     --dsp     c54x_exe (mask-ROM TI hors QEMU) + QEMU + osmocon, mobile VTY
#               4347. Le DSP detecte FB/SB, decode les BCCH, l'A5 y est
#               modelise, la parole montante est convertie TI -> FR ; d'apres
#               c54x_exe/README.md (bilan du 2026-09-23) il monte jusqu'a
#               l'appel, avec des points ouverts (B_BFI sur la parole, SACCH
#               en TCH, SDCCH/8, fenetre SB). Le barreau « couverture » dit
#               ce que le journal du run confirme ou non de tout cela.
#  Sans option, le mode est celui dont la VTY mobile ecoute (4247 ou 4347).
#
#  --campagne : les deux modes a la suite, chacun redemarre et pousse jusqu'a
#  l'appel (--restart --continue), puis un rapport compare les deux echelles
#  et les deux couvertures : /root/banc-max-campagne-<date>/rapport.txt.
#
#  TOUT SE FAIT EN « NO ATTACH » : la pile est lancee detachee
#  (CALYPSO_NO_ATTACH=1 / OSMO_NO_ATTACH=1), jamais dans un tmux interactif.
#
#  IL NE CORRIGE RIEN. Chaque verdict vient d'une lecture faite au moment du
#  test, les compteurs MSC en DELTA, jamais en cumul.
#
#  Usage :
#     banc-max.sh                       PAR DEFAUT : la campagne, grgsm puis dsp
#                                       (chacun redemarre, jusqu'a la voix) + PDF
#     banc-max.sh --grgsm|--dsp         un seul mode, sur la pile en cours
#     banc-max.sh --grgsm|--dsp         force la couche 1
#     banc-max.sh --dsp --restart       (re)demarre la pile dans ce mode
#     banc-max.sh --multi               ajoute l'inter-operateur (start-multi)
#     banc-max.sh --legacy              joue aussi l'ancienne suite pytest (qemu/tests)
#     banc-max.sh --campagne [--multi]  grgsm puis dsp, jusqu'a l'appel, + rapport
#     banc-max.sh --continue            ne s'arrete pas au premier echec
#     banc-max.sh --essais 3            rejoue un barreau en echec (defaut 2)
#     banc-max.sh --relances 1          relance la pile si mobile/camp echouent
#                                       (avec --restart ; defaut 1)
#     banc-max.sh --only=camp,attache   ne jouer que ces barreaux
#     banc-max.sh --skip=ms2            tout sauf ceux-la
#     banc-max.sh --list                les barreaux, dans l'ordre
#     banc-max.sh --dest 600            numero appele (defaut 600, echo test)
#     banc-max.sh --boot-max 240        attente maximale du camp (s)
#     banc-max.sh --stop-after          arrete la pile a la fin
#
#  Sortie : tableau, un barreau par ligne, puis « ELEMENT MAX : N/M ». Tout ce
#  qui a ete lu (VTY, compteurs, sms.txt, journaux) est dans
#  /root/banc-max-<date>/. Code de retour : nombre de barreaux en ECHEC.
# -----------------------------------------------------------------------------
set -uo pipefail
TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS/modules/_lib.sh"

# ── Ctrl-C ARRETE, il ne passe pas au barreau suivant ────────────────────────
# Sans piege, le SIGINT ne tue que la commande en cours (nc, pytest, le mode
# lance par la campagne) et la boucle continue comme si le barreau avait rendu
# son verdict. Ici : on note l'interruption, on tue ce qui reste sous nous, on
# ecrit le tableau tel quel, et on sort en 130 — la campagne, qui nous appelle,
# a le meme piege et s'arrete aussi.
INTERROMPU=0
# Tout l'arbre, pas seulement les enfants directs : `timeout` et les sous-shells
# creent des petits-enfants (nc, pytest, global_check...) que « pkill -P $$ »
# ne voit pas. On descend l'arbre par pgrep -P avant de tuer, feuilles d'abord.
tuer_arbre() {
    local pid="$1" e
    for e in $(pgrep -P "$pid" 2>/dev/null); do tuer_arbre "$e"; done
    [ "$pid" != "$$" ] && kill -TERM "$pid" 2>/dev/null
}
_stop() {
    [ "$INTERROMPU" = 1 ] && { tuer_arbre $$; exit 130; }
    INTERROMPU=1
    printf '\n  %sinterrompu (Ctrl-C)%s\n' "${R:-}" "${Z:-}" >&2
    tuer_arbre $$
    [ "${#NOMS[@]}" -gt 0 ] && [ -n "${OUT:-}" ] && lib_verdict >/dev/null 2>&1
    exit 130
}
trap _stop INT TERM

ONLY=""; SKIP=""; CAMPAGNE=0; ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --campagne)   CAMPAGNE=1 ;;
        --grgsm)      MODE=grgsm ;;
        --dsp)        MODE=dsp ;;
        --restart)    RESTART=1 ;;
        --multi)      MULTI=1 ;;
        --legacy)     LEGACY=1 ;;
        --continue)   CONTINUE=1 ;;
        --stop-after) STOP_AFTER=1 ;;
        --only=*)     ONLY="${1#*=}" ;;
        --skip=*)     SKIP="${1#*=}" ;;
        --list)       for m in "$TESTS"/modules/[0-9]*.sh; do
                          printf '  %-12s %s\n' "$(mod_nom "$m")" "$(sed -n '2s/^# *//p' "$m")"
                      done; exit 0 ;;
        --essais)     ESSAIS="${2:?}"; shift ;;
        --relances)   RELANCES="${2:?}"; shift ;;
        --dest)       DEST="${2:?}"; shift ;;
        --boot-max)   BOOT_MAX="${2:?}"; shift ;;
        --call-s)     CALL_S="${2:?}"; shift ;;
        -h|--help)    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
    shift
done

# Sans mode, sans --only et sans --restart : c'est la campagne complete, les
# deux couches 1 l'une apres l'autre. Un mode explicite joue ce mode seul.
if [ "$CAMPAGNE" = 0 ] && [ -z "$MODE" ] && [ -z "$ONLY" ] && [ "$RESTART" = 0 ]; then CAMPAGNE=1; fi
if [ "$CAMPAGNE" = 1 ]; then . "$TESTS/modules/_campagne.sh"; campagne_run; exit $?; fi
lib_init
say "mode ${B}$MODE${Z}  VTY mobile $MOB_VTY  conf $MOB_CFG  journal $OUT"

# Les barreaux, dans l'ordre des fichiers. Chaque module declare :
#   MOD_CHAINE=1   il suppose le barreau precedent (saute si la chaine est rompue)
#   mod_run()      pose son verdict par `verdict <nom> OK|ECHEC|SAUTE "detail"`
for m in "$TESTS"/modules/[0-9]*.sh; do
    nom="$(mod_nom "$m")"
    NOMS+=("$nom"); VERD[$nom]="NON-TESTE"; DET[$nom]=""
done
for m in "$TESTS"/modules/[0-9]*.sh; do
    nom="$(mod_nom "$m")"
    if [ -n "$ONLY" ] && ! liste_contient "$ONLY" "$nom"; then VERD[$nom]="SAUTE"; DET[$nom]="hors --only"; continue; fi
    if liste_contient "$SKIP" "$nom"; then VERD[$nom]="SAUTE"; DET[$nom]="--skip"; continue; fi
    MOD_CHAINE=0; MOD_OPTIONNEL=0; MOD_RELANCE_PILE=0
    unset -f mod_run mod_titre 2>/dev/null
    . "$m"
    head_ "$nom  $(mod_titre 2>/dev/null)"
    if [ "$MOD_CHAINE" = 1 ] && [ "$CHAINE_OK" = 0 ] && [ "$CONTINUE" = 0 ]; then
        verdict "$nom" SAUTE "barreau precedent en echec"; continue
    fi
    # « PARFOIS CA FOIRE » : le defaut du banc est intermittent (banc-repro.sh
    # existe pour ca). Un barreau enchaine en echec est rejoue jusqu'a --essais
    # fois avant verdict ; le detail garde le numero de l'essai. Et si c'est le
    # mobile ou le camp qui manquent alors qu'on a lance la pile nous-memes,
    # on la relance une fois (--relances) : un QEMU qui n'a pas synchronise ne
    # se rattrape pas en attendant plus.
    essai=1
    while :; do
        mod_run
        [ "${VERD[$nom]}" = ECHEC ] || break
        if [ "$MOD_RELANCE_PILE" = 1 ] && [ "$RESTART" = 1 ] && [ "$RELANCES_FAITES" -lt "$RELANCES" ]; then
            RELANCES_FAITES=$((RELANCES_FAITES+1))
            say "-> relance de la pile ($RELANCES_FAITES/$RELANCES)"
            ( unset -f mod_run; . "$TESTS/modules/00-demarrage.sh"; mod_run ) | sed 's/^/     /'
            essai=1; continue
        fi
        [ "$MOD_CHAINE" = 1 ] && [ "$essai" -lt "$ESSAIS" ] || break
        essai=$((essai+1)); say "-> nouvel essai $essai/$ESSAIS"; sleep 3
    done
    [ "$essai" -gt 1 ] && DET[$nom]="${DET[$nom]} (essai $essai/$ESSAIS)"
    # Un barreau optionnel (ms2, multi) ne rompt pas la chaine : son absence
    # n'empeche pas les suivants, son echec est un fait a part.
    if [ "${VERD[$nom]}" = ECHEC ] && [ "$MOD_OPTIONNEL" = 0 ]; then CHAINE_OK=0; fi
done

lib_collecte
lib_verdict
exit "$ECHECS"
