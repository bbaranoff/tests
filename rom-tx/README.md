# rom-tx — codage canal montant par la ROM DSP Calypso

Vérification que la mask-ROM TI du DSP Calypso (sous `c54x_exe`) fait elle-même le
codage canal montant GSM 05.03, en vue de remplacer la reconstruction sur l'hôte
(`c54x_exe/src/montant.c`) par la lecture de la sortie de la ROM.

## Méthode

Injection de blocs L2 contrôlés dans `a_cu` (NDB 0x264) du DSP vivant, via les sondes
inertes de `c54x_exe/src/pont.c` (variables d'environnement, lancées par `banc-max.sh --dsp`) :

- `PONT_TX_SONDE=N` — journalise ce que la ROM écrit quand l'ARM pose une tâche montante.
- `PONT_TX_INJECT=<fichier>` — réécrit `a_cu` avec un bloc de test (23 octets hexa/ligne) APRÈS
  que montant.c a publié le vrai bloc : le lien réel n'est pas touché, la ROM encode le bloc de test.
- `PONT_TX_OMBRE=1` — compare, sur chaque bloc SDCCH réel, la sortie ROM `data[0x4280]` aux bits
  de `gsm0503_xcch_encode` via la carte `src/carte_tx.h` (générée par `carte.py`).

`enc.c` = encodeur de référence (libosmocoding `gsm0503_xcch_encode`). `carte.py` reconstruit la
carte position_sortie → bit codé à partir de `inj_*.txt` (un bloc nul + 184 vecteurs à un bit).

## Résultats (2026-10-03)

- **3 bugs du cœur C54x corrigés** dans `qosmo/.../c54x_exec.c` (AND/OR/XOR src,SHIFT décalage
  logique 40 bits ; LD/SUB/ADD Smem,16 et LDM respectant SXM). Avant : décalages arithmétiques et
  sign-extend systématiques → le « +32 à chaque mot » sur le codage.
- **Étage convolutif (données) = 100 % identique au standard** sur 184 vecteurs, et **mode ombre
  180/180 blocs SDCCH réels parfaits** sur les ~384 positions mappées de `0x4280`.
- **Point dur résolu (2026-10-03, après-midi)** : les 56 bits « manquants » ÉTAIENT matérialisés
  dans `0x4280`, mais faux. La sortie ROM est auto-cohérente (0 violation sur les bits impairs du code
  convolutif) ; c'est la parité FIRE en entrée du codeur qui avait ses **24 bits hauts à 0**.
  La routine FIRE (PROM0 `0x9013`, appelée en `0x8bbf` avec B = 0x0004820009) rend la bonne parité
  dans A ; le rangement `0x8bc6 f1b0` = `OR A,-16,B` était capté par un faux décodage « F0Bx/F1Bx =
  RSBX/SSBX » du cœur (les vrais sont F4B0/F5B0) → B restait 0. **4ᵉ bug du cœur**, corrigé dans
  `c54x_exec.c` (gate `CALYPSO_F0BX_SBIT=1` = ancien comportement). Harnais hors banc : le codé
  natural-order de la zone parité devient identique au codeur de référence.
- **Banc dsp avec la correction (c54x_exe.f0bx, 2026-10-03 16:50)** : échelle camp→voix 25/25,
  ombre 352/352. Sur 456 bits : 192/352 parfaits, le reste n'a que 1-2 bits faux, toujours burst 0
  bits 112-113. Ce n'est pas un bug : la **sérialisation TX** de la ROM (PROM0 `0x8900`-`0x891b`)
  copie à chaque trame les 8 mots du burst courant du tampon circulaire `0x4280` (BK=32) vers
  **`data[0x3f8a..0x3f91]`** (`mvdd *ar2+%,*ar3+`), puis remet à 0 le mot 7 du burst dans `0x4280`
  (`stl b,*ar2+%`). La capture `reel.txt` passe après le départ du burst 0.
  **`0x3f8a` est le burst émis** : 114 bits + hl/hu (2 bits bas du mot 7 = 1,1). Vérifié par trace
  (bloc `ff`×23) : les 4 bursts dans `0x3f8a` = `gsm0503_xcch_encode` bit à bit.

- **Branché (2026-10-03 17:11)** : c54x_exe publie les bursts `0x3f8a` (+ flux A5) dans
  `/dev/shm/calypso_xcch_ul_rom`, le pont DSP les émet (`xCCH ul rom=134 hote=1`, banc 25/25).
  Voir c54x_exe `README.md` et osmo-operator `pont/README.md`.
- ⚠ `carte.py` : `enc` ne sort que 456 des 464 bits de `gsm0503_xcch_encode` (4 × 116, SF en 57/58)
  → les 8 derniers « sans équivalent » de g3 sont un artefact de troncature.

## Fichiers

- `enc.c` — compiler : `gcc -o enc enc.c $(pkg-config --cflags --libs libosmocoding libosmocore)`
- `carte.py` — carte injection → `src/carte_tx.h`
- `etage_conv.py` — vérifie l'étage convolutif intermédiaire contre 05.03
- `inj_*.txt`, `blocs-injectes.txt` — données d'injection (une mesure)
- `avant*/`, `multi/`, `full/`, `rf/` — captures intermédiaires (grosses, régénérables)
