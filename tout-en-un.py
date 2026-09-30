#!/usr/bin/env python3
"""tout-en-un.py — rassemble les .log .sh .md .mmd .py .txt d'un ou plusieurs
dossiers dans UN fichier Markdown, raccourci SANS PERTE :

  * fichiers identiques (meme contenu) : une seule copie, les autres renvoient
    a la premiere ;
  * lignes consecutives identiques : « ligne  ×N » ;
  * lignes consecutives qui ne different que par des nombres (horodatage,
    compteur, fn...) : un gabarit ou les nombres constants restent en place et
    les nombres variables deviennent ⟨1⟩ ⟨2⟩..., suivi de la liste ordonnee des
    valeurs. On reconstruit chaque ligne en remettant les valeurs dans l'ordre.
  * codes couleur ANSI et retours chariot retires (seule perte, volontaire).

    ./tout-en-un.py [dossier...]      defaut : /opt/GSM/tests et le dernier /root/banc-max-*
    SORTIE=/chemin.md  EXT="log sh md mmd py txt"  SEUIL=3 (taille mini d'un groupe)
"""
import glob
import hashlib
import os
import re
import sys
import time

EXT = os.environ.get("EXT", "log sh md mmd py txt").split()
SEUIL = int(os.environ.get("SEUIL", "3"))
SORTIE = os.environ.get("SORTIE") or "/root/tout-en-un-%s.md" % time.strftime("%Y%m%d-%H%M%S")
IGNORES = {".git", "__pycache__", ".pytest_cache", "node_modules"}
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
NUM = re.compile(r"\d+")
LANG = {"sh": "bash", "py": "python", "md": "markdown", "mmd": "mermaid", "txt": "text", "log": "text"}


def dossiers_par_defaut():
    runs = sorted(glob.glob("/root/banc-max-*"), key=os.path.getmtime)
    runs = [r for r in runs if os.path.isdir(r)]
    return ["/opt/GSM/tests"] + ([runs[-1]] if runs else [])


def fichiers(dossier):
    for racine, dirs, noms in os.walk(dossier):
        dirs[:] = sorted(d for d in dirs if d not in IGNORES)
        for n in sorted(noms):
            if n.startswith("tout-en-un-"):      # nos propres sorties
                continue
            if n.rsplit(".", 1)[-1].lower() in EXT and "." in n:
                yield os.path.join(racine, n)


def compacter(lignes):
    """Rend (lignes de sortie, nb de groupes compactes)."""
    out, groupes, i, n = [], 0, 0, len(lignes)
    while i < n:
        cle = NUM.sub("\0", lignes[i])
        j = i + 1
        while j < n and NUM.sub("\0", lignes[j]) == cle:
            j += 1
        taille = j - i
        if taille < SEUIL:
            out.extend(lignes[i:j])
            i = j
            continue
        groupes += 1
        if "\0" not in cle:                      # repetition exacte
            out.append("%s  ×%d" % (lignes[i], taille))
            i = j
            continue
        valeurs = [NUM.findall(l) for l in lignes[i:j]]
        nb = len(valeurs[0])
        varie = [len({v[k] for v in valeurs}) > 1 for k in range(nb)]
        # gabarit : nombres constants remis en place, variables numerotes ⟨k⟩
        morceaux, k, idx = cle.split("\0"), 0, 0
        gab = morceaux[0]
        for m in morceaux[1:]:
            if varie[k]:
                idx += 1
                gab += "⟨%d⟩" % idx
            else:
                gab += valeurs[0][k]
            gab += m
            k += 1
        out.append("%s  ×%d" % (gab, taille))
        if idx:
            tuples = [",".join(v[k] for k in range(nb) if varie[k]) for v in valeurs]
            # lignes de valeurs de ~100 colonnes
            ligne, courant = [], "    ⟨⟩ ="
            for t in tuples:
                if len(courant) + len(t) + 3 > 110:
                    ligne.append(courant)
                    courant = "       "
                courant += " (" + t + ")"
            ligne.append(courant)
            out.extend(ligne)
        i = j
    return out, groupes


def main():
    dossiers = sys.argv[1:] or dossiers_par_defaut()
    vus, sections, table = {}, [], []
    total_in = total_out = 0
    for d in dossiers:
        if not os.path.isdir(d):
            table.append("| (absent) %s | | | | |" % d)
            continue
        for f in fichiers(d):
            try:
                brut = open(f, "rb").read()
            except OSError as e:
                table.append("| %s | | | | illisible : %s |" % (f, e))
                continue
            texte = ANSI.sub("", brut.decode("utf-8", "replace")).replace("\r", "")
            lignes = texte.split("\n")
            if lignes and lignes[-1] == "":
                lignes.pop()
            h = hashlib.sha1(texte.encode()).hexdigest()
            total_in += len(brut)
            if h in vus:
                table.append("| %s | %d | %d | – | identique à %s |" % (f, len(brut), len(lignes), vus[h]))
                continue
            vus[h] = f
            compact, groupes = compacter(lignes)
            total_out += sum(len(l) + 1 for l in compact)
            note = "%d groupes compactés" % groupes if groupes else ""
            table.append("| %s | %d | %d | %d | %s |" % (f, len(brut), len(lignes), len(compact), note))
            ext = f.rsplit(".", 1)[-1].lower()
            cloture = "````" if ext == "md" else "```"
            sections.append("### %s\n\n%d octets, %d lignes → %d lignes%s\n\n%s%s\n%s\n%s\n"
                            % (f, len(brut), len(lignes), len(compact), (" (%s)" % note) if note else "",
                               cloture, LANG.get(ext, "text"), "\n".join(compact), cloture))
    with open(SORTIE, "w") as o:
        o.write("# tout-en-un — %s\n\n" % time.strftime("%F %T"))
        o.write("Dossiers : %s  \nExtensions : %s  \n" % (", ".join(dossiers), " ".join(EXT)))
        o.write("Entree : %d Ko, sortie : %d Ko. Compactage sans perte : fichiers identiques cites une fois ; "
                "lignes consecutives identiques « ×N » ; lignes ne differant que par des nombres : gabarit "
                "avec ⟨k⟩ puis la liste ordonnee des valeurs (k-uplets) ; seuls les codes couleur sont retires.\n\n"
                % (total_in // 1024, total_out // 1024))
        o.write("## Fichiers\n\n| fichier | octets | lignes | lignes compactées | note |\n|---|---|---|---|---|\n")
        o.write("\n".join(table) + "\n\n## Contenu\n\n")
        o.write("\n".join(sections))
    print("%s : %d fichiers (%d uniques), %d Ko -> %d Ko" % (SORTIE, len(table), len(vus), total_in // 1024,
                                                            os.path.getsize(SORTIE) // 1024))


if __name__ == "__main__":
    main()
