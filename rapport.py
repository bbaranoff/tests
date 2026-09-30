#!/root/.env/bin/python3
# rapport.py — LE RAPPORT PDF D'UNE CAMPAGNE banc-max (ou d'un run seul).
#
#   rapport.py /root/banc-max-campagne-<date>          -> <dir>/rapport.pdf
#   rapport.py /root/banc-max-<date>                   -> un seul run
#   rapport.py DIR --out fichier.pdf
#
# Il ne mesure rien : il met en page ce que les modules ont ecrit (verdict.txt,
# couverture.txt, existant-*.txt, pytest/test_results.md, voix-analyse.txt,
# ussd-vty.txt, msc-statistics.txt...). Tout chiffre du PDF a son fichier
# source dans le dossier du run, cite en annexe.
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (KeepTogether, PageBreak, Paragraph, SimpleDocTemplate,
                                Spacer, Table, TableStyle)

# ── Police : DejaVu pour les accents, « », ✓ ✗ ; Helvetica sinon ────────────
FONT, FONT_B, FONT_M = "Helvetica", "Helvetica-Bold", "Courier"
_dv = Path("/usr/share/fonts/truetype/dejavu")
if (_dv / "DejaVuSans.ttf").exists():
    pdfmetrics.registerFont(TTFont("DejaVu", str(_dv / "DejaVuSans.ttf")))
    pdfmetrics.registerFont(TTFont("DejaVu-Bold", str(_dv / "DejaVuSans-Bold.ttf")))
    pdfmetrics.registerFont(TTFont("DejaVu-Mono", str(_dv / "DejaVuSansMono.ttf")))
    FONT, FONT_B, FONT_M = "DejaVu", "DejaVu-Bold", "DejaVu-Mono"

ANSI = re.compile(r"\x1b\[[0-9;]*m")
VERT, ROUGE, GRIS, JAUNE = colors.HexColor("#1f7a1f"), colors.HexColor("#a31a1a"), colors.HexColor("#777777"), colors.HexColor("#b07a00")
FOND = {"OK": colors.HexColor("#d9f2d0"), "ECHEC": colors.HexColor("#f7c6c6"), "SAUTE": colors.HexColor("#e6e6e6"),
        "NON-TESTE": colors.HexColor("#e6e6e6"), "GERE": colors.HexColor("#d9f2d0"), "DEGRADE": colors.HexColor("#fde79c"),
        "NON GERE": colors.HexColor("#f7c6c6"), "NON OBSERVE": colors.HexColor("#eeeeee")}

ss = getSampleStyleSheet()
S = {
    "titre": ParagraphStyle("t", parent=ss["Title"], fontName=FONT_B, fontSize=26, leading=32, alignment=TA_CENTER),
    "sous": ParagraphStyle("s", parent=ss["Normal"], fontName=FONT, fontSize=12, leading=16, alignment=TA_CENTER, textColor=GRIS),
    "h1": ParagraphStyle("h1", parent=ss["Heading1"], fontName=FONT_B, fontSize=16, spaceBefore=14, spaceAfter=6),
    "h2": ParagraphStyle("h2", parent=ss["Heading2"], fontName=FONT_B, fontSize=12.5, spaceBefore=10, spaceAfter=4),
    "p": ParagraphStyle("p", parent=ss["Normal"], fontName=FONT, fontSize=9.5, leading=13),
    "petit": ParagraphStyle("pt", parent=ss["Normal"], fontName=FONT, fontSize=8, leading=10.5),
    "mono": ParagraphStyle("m", parent=ss["Normal"], fontName=FONT_M, fontSize=7.2, leading=9),
    "cell": ParagraphStyle("c", parent=ss["Normal"], fontName=FONT, fontSize=8, leading=10),
    "cellb": ParagraphStyle("cb", parent=ss["Normal"], fontName=FONT_B, fontSize=8, leading=10),
    "gros": ParagraphStyle("g", parent=ss["Normal"], fontName=FONT_B, fontSize=30, leading=34, alignment=TA_CENTER),
}


def esc(s):
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def lire(p):
    try:
        return ANSI.sub("", Path(p).read_text(errors="replace"))
    except Exception:
        return ""


# ── Lecture d'un run ────────────────────────────────────────────────────────
def lire_run(d):
    d = Path(d)
    r = {"dir": d, "nom": d.name, "mode": "?", "barreaux": [], "max": None, "echecs": None}
    v = lire(d / "verdict.txt")
    for ln in v.splitlines():
        m = re.match(r"\s*(\d+)\s+([a-z0-9-]+)\s+(OK|ECHEC|SAUTE|NON-TESTE)\s*(.*)", ln)
        if m:
            r["barreaux"].append({"n": int(m.group(1)), "nom": m.group(2), "v": m.group(3), "det": m.group(4).strip()})
    m = re.search(r"ELEMENT MAX : (\d+)/(\d+)\s+\((\S+)\)\s+mode (\S+)\s+echecs (\d+)", v)
    if m:
        r.update(max=int(m.group(1)), total=int(m.group(2)), max_nom=m.group(3), mode=m.group(4), echecs=int(m.group(5)))
    # couverture
    r["couverture"] = []
    c = lire(d / "couverture.txt")
    for ln in c.splitlines():
        m = re.match(r"\s{2}(.{38})\s(GERE|DEGRADE|NON GERE|NON OBSERVE)\s+(\d+)\s+(\d+)\s+(.*)", ln)
        if m:
            r["couverture"].append({"f": m.group(1).strip(), "v": m.group(2), "p": m.group(3), "s": m.group(4), "qui": m.group(5).strip()})
    m = re.search(r"bilan : (.*)", c)
    r["couv_bilan"] = m.group(1) if m else ""
    r["couv_compteurs"] = c[c.find("derniers compteurs"):c.find("bilan :")].strip() if "derniers compteurs" in c else ""
    # divers
    r["stats"] = "\n".join(l for l in lire(d / "msc-statistics.txt").splitlines()
                           if re.match(r"(Location|IMSI|SMS|MO |MT |Dropped|Active)", l))
    r["ussd"] = [l.strip() for l in lire(d / "ussd-vty.txt").splitlines() if "Service response" in l]
    r["voix"] = lire(d / "voix-analyse.txt").strip()
    r["sms_mo"] = [l.strip() for l in lire(d / "sms-mo-vty.txt").splitlines() if l.strip().startswith("%")]
    r["camp"] = "\n".join(l for l in lire(d / "show-ms-camp.txt").splitlines()
                          if re.search(r"cell selection|ARFCN=|radio resource|mobility management|IMSI", l))
    r["existants"] = {}
    for f in sorted(d.glob("existant-*.txt")):
        t = lire(f)
        r["existants"][f.stem.replace("existant-", "")] = {
            "ok": len(re.findall(r"^\s*✓", t, re.M)), "ko": len(re.findall(r"^\s*✗", t, re.M)),
            "lignes_ko": [l.strip() for l in t.splitlines() if re.match(r"^\s*✗", l)][:12],
            "resume": " ".join(re.findall(r"\d+ (?:passed|failed|errors?|skipped|xfailed|xpassed)", t)),
        }
    r["pytest_md"] = lire(d / "pytest" / "test_results.md")
    try:
        r["pytest_json"] = json.loads(lire(d / "pytest" / "results.json") or "null")
    except Exception:
        r["pytest_json"] = None
    r["journaux"] = sorted(p.name for p in d.iterdir() if p.is_file())
    return r


def lire_campagne(d):
    d = Path(d)
    runs = []
    for mode in ("grgsm", "dsp"):
        lien = d / mode
        if lien.exists():
            runs.append(lire_run(lien.resolve()))
    if not runs and (d / "verdict.txt").exists():
        runs.append(lire_run(d))
    return runs


# ── Mise en page ────────────────────────────────────────────────────────────
def cellule(txt, v=None, bold=False):
    p = Paragraph(esc(txt), S["cellb"] if bold else S["cell"])
    return p


def table_verdicts(runs):
    noms = []
    for r in runs:
        for b in r["barreaux"]:
            if b["nom"] not in noms:
                noms.append(b["nom"])
    head = [cellule("#", bold=True), cellule("barreau", bold=True)] + [cellule(r["mode"], bold=True) for r in runs]
    rows = [head]
    style = [("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dddddd")), ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
             ("VALIGN", (0, 0), (-1, -1), "TOP"), ("FONTNAME", (0, 0), (-1, -1), FONT)]
    for i, nom in enumerate(noms, 1):
        row = [cellule(str(i)), cellule(nom, bold=True)]
        for j, r in enumerate(runs):
            b = next((x for x in r["barreaux"] if x["nom"] == nom), None)
            v = b["v"] if b else "-"
            row.append(cellule(v))
            if b:
                style.append(("BACKGROUND", (2 + j, i), (2 + j, i), FOND.get(v, colors.white)))
        rows.append(row)
    w = [10 * mm, 40 * mm] + [(120 * mm) / max(1, len(runs))] * len(runs)
    t = Table(rows, colWidths=w, repeatRows=1)
    t.setStyle(TableStyle(style))
    return t


def table_details(r):
    rows = [[cellule("#", bold=True), cellule("barreau", bold=True), cellule("verdict", bold=True), cellule("preuve / detail", bold=True)]]
    style = [("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dddddd")), ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
             ("VALIGN", (0, 0), (-1, -1), "TOP")]
    for i, b in enumerate(r["barreaux"], 1):
        rows.append([cellule(str(b["n"])), cellule(b["nom"], bold=True), cellule(b["v"]), cellule(b["det"])])
        style.append(("BACKGROUND", (2, i), (2, i), FOND.get(b["v"], colors.white)))
    t = Table(rows, colWidths=[8 * mm, 30 * mm, 20 * mm, 112 * mm], repeatRows=1)
    t.setStyle(TableStyle(style))
    return t


def table_couverture(r):
    rows = [[cellule("fonction", bold=True), cellule("verdict", bold=True), cellule("preuves", bold=True),
             cellule("sympt.", bold=True), cellule("qui la fait (note)", bold=True)]]
    style = [("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dddddd")), ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
             ("VALIGN", (0, 0), (-1, -1), "TOP")]
    for i, c in enumerate(r["couverture"], 1):
        rows.append([cellule(c["f"]), cellule(c["v"]), cellule(c["p"]), cellule(c["s"]), cellule(c["qui"])])
        style.append(("BACKGROUND", (1, i), (1, i), FOND.get(c["v"], colors.white)))
    t = Table(rows, colWidths=[46 * mm, 22 * mm, 13 * mm, 13 * mm, 76 * mm], repeatRows=1)
    t.setStyle(TableStyle(style))
    return t


def bloc_mono(txt, max_lignes=40):
    lignes = txt.splitlines()[:max_lignes]
    return Paragraph("<br/>".join(esc(l) for l in lignes), S["mono"])


def pied(canvas, doc):
    canvas.saveState()
    canvas.setFont(FONT, 7.5)
    canvas.setFillColor(GRIS)
    canvas.drawString(15 * mm, 10 * mm, "banc-max — osmo-operator, banc GSM émulé sans RF — rapport généré par /opt/GSM/tests/rapport.py")
    canvas.drawRightString(A4[0] - 15 * mm, 10 * mm, f"page {doc.page}")
    canvas.restoreState()


def construire(runs, out, titre_dir):
    doc = SimpleDocTemplate(str(out), pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm, topMargin=16 * mm, bottomMargin=16 * mm,
                            title="banc-max — rapport de campagne", author="osmo-operator / tests/banc-max.sh")
    st = []
    # ── Couverture ──
    st.append(Spacer(1, 40 * mm))
    st.append(Paragraph("Jusqu'où monte le banc ?", S["titre"]))
    st.append(Paragraph("Échelle des éléments — coeur, BTS, couche 1, mobile, camp, attache, SMS, USSD, appel, voix", S["sous"]))
    st.append(Spacer(1, 6 * mm))
    st.append(Paragraph(f"Campagne {esc(titre_dir)} — {datetime.now():%d/%m/%Y %H:%M}", S["sous"]))
    st.append(Spacer(1, 14 * mm))
    for r in runs:
        mx = f"{r['max']}/{r.get('total', '?')}" if r["max"] is not None else "?"
        coul = VERT if (r["echecs"] == 0) else (JAUNE if r["max"] and r["max"] >= r.get("total", 0) - 3 else ROUGE)
        st.append(Paragraph(f"<font color='{coul.hexval()}'>{esc(r['mode'])} : {mx}</font>", S["gros"]))
        st.append(Paragraph(f"dernier barreau atteint « {esc(r.get('max_nom', '?'))} », {r['echecs']} échec(s)", S["sous"]))
        st.append(Spacer(1, 6 * mm))
    st.append(Spacer(1, 10 * mm))
    st.append(Paragraph("Deux couches 1 pour le même réseau : <b>grgsm</b> (démodulation gr-gsm dans QEMU, A5 et codage canal sur l'hôte) "
                        "et <b>dsp</b> (mask-ROM TI exécutée par c54x_exe : FB/SB, décodage canal, A5, vocodage TI). "
                        "Chaque barreau est un fait lu au moment du test — compteurs du MSC en delta, réponses de la VTY du mobile, "
                        "journaux des programmes — jamais une supposition. Ce PDF est produit par script ; chaque chiffre a son fichier source, listé en annexe.", S["p"]))
    st.append(PageBreak())

    # ── 1. L'échelle côte à côte ──
    st.append(Paragraph("1. L'échelle, mode par mode", S["h1"]))
    st.append(Paragraph("OK = preuve obtenue ; ECHEC = attendu non observé dans le délai ; SAUTE = barreau précédent en échec, ou hors de ce montage "
                        "(pas de MS#2, pas de multi-opérateur demandé). Le barreau « couverture » est un rapport, jamais un échec.", S["petit"]))
    st.append(Spacer(1, 3 * mm))
    st.append(table_verdicts(runs))

    # ── 2. Détail par mode ──
    for r in runs:
        st.append(PageBreak())
        st.append(Paragraph(f"2. Mode {esc(r['mode'])} — barreau par barreau", S["h1"]))
        st.append(table_details(r))
        if r["camp"]:
            st.append(Paragraph("Le mobile au moment du camp (show ms 1)", S["h2"]))
            st.append(bloc_mono(r["camp"]))
        if r["stats"]:
            st.append(Paragraph("Compteurs du MSC en fin de run (show statistics)", S["h2"]))
            st.append(bloc_mono(r["stats"]))
        if r["sms_mo"]:
            st.append(Paragraph("SMS MO — réponses du réseau au mobile", S["h2"]))
            st.append(bloc_mono("\n".join(r["sms_mo"])))
        if r["ussd"]:
            st.append(Paragraph("USSD — réponses reçues (*#100# own-msisdn, *#101# own-imsi)", S["h2"]))
            st.append(bloc_mono("\n".join(r["ussd"])))
        if r["voix"]:
            st.append(Paragraph("Voix — ton 1 kHz injecté dans gsm_mic, retour de l'écho 600 sur gsm_audio.monitor", S["h2"]))
            st.append(Paragraph(esc(r["voix"]), S["p"]))

        # ── 3. Couverture ──
        if r["couverture"]:
            st.append(PageBreak())
            st.append(Paragraph(f"3. Couverture couche 1 — mode {esc(r['mode'])}", S["h1"]))
            st.append(Paragraph("Qui prend en charge chaque fonction dans ce montage, et ce que les journaux du run en prouvent : "
                                "GERE = au moins une preuve, aucun symptôme ; DEGRADE = preuves et symptômes ; NON GERE = hors du montage ou symptôme seul ; "
                                "NON OBSERVE = rien dans le journal (fonction non exercée par ce run, ou non journalisée). "
                                "Les motifs sont les chaînes écrites par les programmes eux-mêmes (c54x_exe/src/montant.c, pont/*.py, qosmo calypso_l1_grgsm.c, mobile osmocom-bb).", S["petit"]))
            st.append(Spacer(1, 2 * mm))
            st.append(table_couverture(r))
            if r["couv_bilan"]:
                st.append(Spacer(1, 2 * mm))
                st.append(Paragraph(f"<b>Bilan :</b> {esc(r['couv_bilan'])}", S["p"]))
            if r["couv_compteurs"]:
                st.append(Paragraph("Derniers compteurs écrits par les programmes", S["h2"]))
                st.append(bloc_mono(r["couv_compteurs"]))

        # ── 4. Tests existants ──
        if r["existants"]:
            st.append(PageBreak())
            st.append(Paragraph(f"4. Tests déjà écrits, rejoués — mode {esc(r['mode'])}", S["h1"]))
            rows = [[cellule("suite", bold=True), cellule("✓", bold=True), cellule("✗", bold=True), cellule("résumé / premières lignes en échec", bold=True)]]
            for k, e in r["existants"].items():
                det = e["resume"] or "\n".join(e["lignes_ko"])
                rows.append([cellule(k), cellule(str(e["ok"])), cellule(str(e["ko"])), cellule(det)])
            t = Table(rows, colWidths=[35 * mm, 10 * mm, 10 * mm, 115 * mm], repeatRows=1)
            t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#dddddd")), ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
                                   ("VALIGN", (0, 0), (-1, -1), "TOP")]))
            st.append(t)
            if r["pytest_md"]:
                st.append(Paragraph("Suite pytest Calypso — statut global (pytest/test_results.md)", S["h2"]))
                md = r["pytest_md"]
                deb = md.find("## Status global")
                fin = md.find("## Pipeline")
                extrait = md[deb:fin if fin > deb else deb + 1200] if deb >= 0 else md[:1200]
                st.append(bloc_mono(extrait, 30))
                if r["pytest_json"] and isinstance(r["pytest_json"], dict):
                    tests = r["pytest_json"].get("tests") or r["pytest_json"].get("results") or []
                    if isinstance(tests, list) and tests:
                        ko = [t for t in tests if str(t.get("outcome", t.get("status", ""))).lower() in ("failed", "error")]
                        if ko:
                            st.append(Paragraph(f"Tests en échec ({len(ko)})", S["h2"]))
                            st.append(bloc_mono("\n".join(str(t.get("nodeid", t.get("name", "?"))) for t in ko), 40))

    # ── 5. Annexe ──
    st.append(PageBreak())
    st.append(Paragraph("5. Annexe — d'où vient chaque chiffre", S["h1"]))
    st.append(Paragraph("Chaque run laisse un dossier /root/banc-max-&lt;date&gt;/ ; la campagne y pointe par des liens grgsm/ et dsp/. "
                        "verdict.txt = le tableau ; couverture.txt = la couverture ; existant-*.txt = sorties brutes des suites rejouées ; "
                        "show-ms-*.txt, msc-*.txt, *-vty.txt = lectures VTY ; *.log = journaux copiés (mobile, qemu, osmocon, dsp, pont) ; "
                        "voix-*.wav/.raw = le ton injecté et ce qui est revenu.", S["p"]))
    for r in runs:
        st.append(Paragraph(f"{esc(r['mode'])} — {esc(str(r['dir']))}", S["h2"]))
        st.append(Paragraph(esc(", ".join(r["journaux"])), S["petit"]))
    st.append(Spacer(1, 4 * mm))
    st.append(Paragraph("Comment rejouer : <font face='%s'>/opt/GSM/tests/banc-max.sh --campagne</font> (grgsm puis dsp, chacun redémarré, jusqu'à l'appel et la voix), "
                        "puis <font face='%s'>/opt/GSM/tests/rapport.py /root/banc-max-campagne-&lt;date&gt;</font>. Un seul mode : "
                        "<font face='%s'>banc-max.sh --dsp --restart --continue</font>. Un seul barreau : <font face='%s'>--only=voix</font>." % (FONT_M, FONT_M, FONT_M, FONT_M), S["p"]))
    doc.build(st, onFirstPage=pied, onLaterPages=pied)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = None
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
        args = [a for a in args if a != out]
    if not args:
        print(__doc__ or "usage : rapport.py DIR [--out fichier.pdf]")
        sys.exit(2)
    d = Path(args[0])
    runs = lire_campagne(d)
    if not runs:
        print(f"rien a mettre en page dans {d} (pas de verdict.txt)")
        sys.exit(1)
    out = Path(out) if out else d / "rapport.pdf"
    construire(runs, out, d.name)
    print(out)


if __name__ == "__main__":
    main()
