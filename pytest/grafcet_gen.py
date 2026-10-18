"""
grafcet_gen.py — produit LE grafcet go-live/IQ (HTML + MD) à partir de l'état
réel du run. Appelé par tests/conftest.py::pytest_sessionfinish, donc chaque
`pytest` régénère le grafcet avec le statut courant de chaque RANK dérivé des
logs (qemu.log / osmocon.log / mobile.log) — plus de grafcet lu à l'œil.

Statuts : ok (câblé, validé au run) · wip (posé, en cours) · bad (manquant/bloqué).
"""
from __future__ import annotations
import os
import re
import sys as _sys
from pathlib import Path

# banc.py = LE resolveur de journaux (meme source que les tests) : newest de
# /run/user/<uid>/osmo-nitb/logs et /tmp/c54x-pont, strip ANSI, override env.
# On passe par lui : AUCUN chemin de log en dur ici.
_sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import banc  # type: ignore
except Exception:  # hors pytest / banc indisponible -> repli best-effort
    banc = None


def _logpath(name: str, *fallbacks) -> str:
    """Chemin du journal `name` resolu par banc ; repli sur un fallback existant."""
    if banc is not None:
        try:
            p = banc.log(name)
            if p:
                return str(p)
        except Exception:
            pass
    for f in fallbacks:
        if f and Path(f).exists():
            return f
    return next((f for f in fallbacks if f), "")


QEMU_LOG = _logpath("qemu", os.environ.get("CALYPSO_QEMU_LOG"), "/root/qemu.log")
OSMOCON_LOG = _logpath("osmocon", "/root/osmocon.log")
MOBILE_LOG = _logpath("mobile", "/root/mobile.log")
DSP_LOG = _logpath("dsp")


def _read(p: str) -> str:
    try:
        return open(p, "rb").read().decode("latin-1", "replace")
    except OSError:
        return ""


def _deaccent(s):
    """Translit ASCII (evite mojibake Ã©/Ã¹ selon renderer). Pour qmd/Rmd."""
    import unicodedata as _ud
    m = {"\u2014":"-","\u2013":"-","\u00b7":"-","\u2026":"...","\u2192":"->",
         "\u2190":"<-","\u00ab":'"',"\u00bb":'"',"\u2019":"'","\u2018":"'",
         "\u201c":'"',"\u201d":'"',"\u00d7":"x","\U0001f534":"[X]","\U0001f7e2":"[OK]",
         "\U0001f7e0":"[~]","\u2705":"[OK]","\u274c":"[X]","\u26a0":"[!]","\ufe0f":""}
    for k,v in m.items(): s=s.replace(k,v)
    return _ud.normalize("NFKD", s or "").encode("ascii","ignore").decode("ascii")


def _tr(s):
    """Translit emoji/fleches -> marqueurs ASCII, garde les accents (latin-1 fpdf)."""
    repl = {"\U0001F534": "[X]", "\U0001F7E2": "[OK]", "\U0001F7E0": "[~]",
            "\U0001F7E1": "[~]", "\u2705": "[v]", "\u274c": "[x]", "\u26a0": "[!]",
            "\ufe0f": "", "\u2192": "->", "\u2190": "<-", "\u2014": "-", "\u2013": "-",
            "\u2019": "'", "\u2018": "'", "\u201c": '"', "\u201d": '"', "\u2026": "...",
            "\u2022": "-", "\u2265": ">=", "\u2264": "<=", "\u00d7": "x"}
    for k, v in repl.items():
        s = s.replace(k, v)
    return s.encode("latin-1", "replace").decode("latin-1")


def _count(name: str, pat: str) -> int:
    """Occurrences de `pat` dans le journal `name`, via banc (ANSI retire, bon
    chemin). Repli _read(path) si banc indisponible."""
    if banc is not None:
        try:
            return banc.count(name, pat)
        except Exception:
            pass
    path = {"qemu": QEMU_LOG, "osmocon": OSMOCON_LOG, "mobile": MOBILE_LOG,
            "dsp": DSP_LOG}.get(name, "")
    return len(re.findall(pat, _read(path))) if path else 0


def derive_status() -> dict:
    """Statut de chaque maillon de la chaine go-live -> camp, derive des VRAIS
    journaux du dernier run (dsp.log / qemu.log / osmocon.log / mobile.log).

    Mode-aware : un maillon L1 est 'ok' s'il est prouve cote DSP (c54x_exe,
    sondes [jalon]/[montant]) OU cote gr-gsm (pont.log / qemu backend). Les
    maillons L3 (SI, camp, LU, auth, chiffrement, TMSI) sont lus dans mobile.log,
    communs aux deux modes. 100% = mobile campe, inscrit et chiffre."""
    def ok(cond) -> str:
        return "ok" if cond else "bad"

    # --- L1 : synchro bas-niveau (DSP natif c54x_exe, ou gr-gsm) -------------
    romload = _count("osmocon", r"your code is running now")
    apiram = (_count("qemu", r"pont DSP : API RAM partagee")
              or _count("qemu", r"backend gr-gsm"))
    fb_n = (_count("dsp", r"\[jalon\] fn=\d+ d_fb_det=1")
            or _count("qemu", r"synchro gr-gsm : ARFCN="))
    sb_n = (_count("dsp", r"SB PLAUSIBLE")
            or _count("qemu", r"synchro gr-gsm : ARFCN=.*BSIC="))

    # --- L1 montant : RACH / canal dedie (DSP [montant], ou qemu/pont) -------
    rach_n = (_count("dsp", r"\[montant\] RACH ra=")
              or _count("pont", r"rach=[1-9]") or _count("qemu", r"IMM ASS"))
    sdcch_n = (_count("dsp", r"\[montant\] canal dedie .*SDCCH")
               or _count("qemu", r"canal dedie (arme|SDCCH)"))
    a5_n = _count("dsp", r"\[a5-arm\]") or _count("qemu", r"chiffrement A5/")

    # --- L3 : couche 3 mobile (mobile.log, commun aux deux modes) ------------
    si_n = _count("mobile", r"New SYSTEM INFORMATION [124]\b")
    camp_n = _count("mobile", r"normal service")
    auth_n = _count("mobile", r"AUTHENTICATION REQUEST")
    ciph_n = _count("mobile", r"CIPHERING MODE COMPLETE")
    tmsi_n = _count("mobile", r"got TMSI")
    lu_ok = _count("mobile", r"LOCATION UPDATING ACCEPT")
    lu_ko = _count("mobile", r"LOCATION UPDATING REJECT")

    # --- gardes (un hit = defaut) -------------------------------------------
    los_n = _count("mobile", r"LOS during dedicated|Radio link lost")
    crash_n = (_count("mobile", r"Segmentation fault|Aborted|core dumped")
               + _count("qemu", r"Aborted|Segmentation fault|qemu: hardware error"))

    st = dict(
        romload=ok(romload),
        apiram=ok(apiram),
        fb=ok(fb_n),
        sb=ok(sb_n),
        si=ok(si_n >= 3),                       # SI1+SI2+SI4 au minimum
        camp=ok(camp_n),
        rach=ok(rach_n),
        sdcch=ok(sdcch_n),
        auth=ok(auth_n),
        cipher=("ok" if ciph_n else ("wip" if a5_n else "bad")),
        tmsi=ok(tmsi_n),
        lu=("ok" if (lu_ok and not lu_ko) else ("wip" if lu_ok else "bad")),
        radio=("bad" if (los_n or crash_n) else "ok"),
    )
    # metriques exposees (rendu / meta)
    st.update(mode=(banc.MODE if banc is not None else "?"),
              fb_n=fb_n, sb_n=sb_n, rach_n=rach_n, sdcch_n=sdcch_n, a5_n=a5_n,
              si_n=si_n, camp_n=camp_n, auth_n=auth_n, ciph_n=ciph_n,
              tmsi_n=tmsi_n, lu_ok=lu_ok, lu_ko=lu_ko, los_n=los_n,
              crash_n=crash_n, romload_n=romload)
    return st


# ---- rendu -----------------------------------------------------------------

_MERMAID_CLASS = {"ok": "ok", "wip": "wip", "bad": "bad"}

# ---------------------------------------------------------------------------
# LE CHAINON UNIQUE (source de verite des rendus). Chaque etape :
#   (code, clef_statut, libelle, poids%, detail_mermaid)
# Poids ordonnes : le but (camp + LU + chiffrement) porte le gros du %.
# Somme des poids = 100.
# ---------------------------------------------------------------------------
_CHAIN = [
    ("ROM",  "romload", "osmocon : romload termine",        6,  "your code is running now"),
    ("API",  "apiram",  "QEMU <-> DSP : API RAM partagee",  6,  "pont DSP / backend gr-gsm"),
    ("FB",   "fb",      "FB detecte (d_fb_det=1)",          8,  "[jalon] d_fb_det=1 / synchro"),
    ("SB",   "sb",      "SB plausible (BSIC decode)",       8,  "SB PLAUSIBLE"),
    ("SI",   "si",      "SI 1/2/4 decodes (BCCH)",         10,  "New SYSTEM INFORMATION"),
    ("CAMP", "camp",    "mobile campe (normal service)",   20,  "normal service / C3 camped"),
    ("RACH", "rach",    "RACH monte (acces aleatoire)",     6,  "[montant] RACH ra="),
    ("SDCCH","sdcch",   "canal dedie SDCCH suivi",          8,  "[montant] canal dedie SDCCH"),
    ("AUTH", "auth",    "authentification (RAND/SRES)",     6,  "AUTHENTICATION REQUEST"),
    ("CIPH", "cipher",  "chiffrement A5 complete",         10,  "CIPHERING MODE COMPLETE"),
    ("TMSI", "tmsi",    "TMSI attribue (LU acceptee)",      6,  "got TMSI / LU ACCEPT"),
    ("LINK", "radio",   "lien radio tenu (pas de LOS)",     6,  "garde : LOS / crash = 0"),
]


def _mermaid(st: dict) -> str:
    c = lambda k: _MERMAID_CLASS.get(st.get(k, "bad"), "bad")
    head = ("""flowchart TD
  classDef src  fill:#12242f,stroke:#6ea8d8,stroke-width:1px,color:#cfe3f2;
  classDef ok   fill:#0f2620,stroke:#46c39a,stroke-width:1px,color:#bfe9d7;
  classDef wip  fill:#2a2211,stroke:#e6a94e,stroke-width:1px,color:#f0d6a4;
  classDef bad  fill:#2a1412,stroke:#e86a5f,stroke-width:1.4px,color:#f2c3bd;
  classDef join fill:#101d22,stroke:#38d3c2,stroke-width:1.4px,color:#bff0ea;

  E0["BTS emet en continu<br/>FCCH - SCH - BCCH - FN reelle"]:::src""")
    lines = [head]
    prev = "E0"
    for code, key, label, w, detail in _CHAIN:
        node = f'{code}["{label}<br/>{detail}"]:::{c(key)}'
        lines.append(f"  {prev} --> {node}")
        prev = code
    lines.append("  linkStyle default stroke:#3a565d,stroke-width:1.3px;")
    return "\n".join(lines)


# Table des maillons : derivee de _CHAIN (code, maillon, sonde/journal, clef).
_RANK_ROWS = [(code, label, detail, key) for (code, key, label, w, detail) in _CHAIN]

_PILL = {"ok": ("p-ok", "VALIDE"), "wip": ("p-wip", "EN COURS"), "bad": ("p-bad", "MANQUANT")}


def _css() -> str:
    return """
  :root{--bg:#0c1418;--panel:#0f191e;--line:#20343b;--ink:#d7e3e5;--muted:#83999d;
    --faint:#5b7176;--cyan:#38d3c2;--ok:#46c39a;--wip:#e6a94e;--bad:#e86a5f;--src:#6ea8d8;
    --mono:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;
    --sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);line-height:1.55}
  .wrap{max-width:1080px;margin:0 auto;padding:48px 28px 80px}
  header{border-bottom:1px solid var(--line);padding-bottom:26px;margin-bottom:20px}
  .eyebrow{font-family:var(--mono);font-size:12px;letter-spacing:.22em;text-transform:uppercase;color:var(--cyan);margin:0 0 14px}
  h1{font-family:var(--mono);font-weight:600;font-size:clamp(24px,4vw,38px);margin:0 0 10px;color:#eef6f6}
  .sub{color:var(--muted);max-width:64ch;margin:0;font-size:15px}
  .meta{font-family:var(--mono);font-size:12px;color:var(--faint);margin-top:16px;display:flex;gap:20px;flex-wrap:wrap}
  .legend{display:flex;gap:8px 22px;flex-wrap:wrap;margin:24px 0 8px;font-family:var(--mono);font-size:12.5px}
  .legend span{display:inline-flex;align-items:center;gap:8px;color:var(--muted)}
  .dot{width:10px;height:10px;border-radius:2px}
  .d-ok{background:var(--ok)}.d-wip{background:var(--wip)}.d-bad{background:var(--bad)}.d-src{background:var(--src)}
  .diagram{background:#0f191e;border:1px solid var(--line);border-radius:12px;padding:14px;margin:10px 0 40px;overflow-x:auto}
  .mermaid{min-width:640px}
  h2{font-family:var(--mono);font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:var(--cyan);margin:36px 0 16px}
  table{width:100%;border-collapse:collapse;font-size:14px}
  th,td{text-align:left;padding:11px 14px;border-bottom:1px solid var(--line);vertical-align:top}
  th{font-family:var(--mono);font-size:11.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--faint)}
  td.rank{font-family:var(--mono);color:var(--cyan);white-space:nowrap;font-weight:600}
  td.env{font-family:var(--mono);font-size:12.5px;color:var(--muted)}
  .pill{font-family:var(--mono);font-size:11px;padding:2px 9px;border-radius:20px;display:inline-block;font-weight:600}
  .p-ok{background:rgba(70,195,154,.14);color:var(--ok);border:1px solid rgba(70,195,154,.35)}
  .p-wip{background:rgba(230,169,78,.13);color:var(--wip);border:1px solid rgba(230,169,78,.35)}
  .p-bad{background:rgba(232,106,95,.13);color:var(--bad);border:1px solid rgba(232,106,95,.38)}
  .foot{margin-top:40px;padding-top:22px;border-top:1px solid var(--line);font-family:var(--mono);font-size:12px;color:var(--faint)}
  code{font-family:var(--mono)}
"""


def render_html(st: dict, ts: str = "") -> str:
    rows = "\n".join(
        f'      <tr><td class="rank">{r}</td><td>{d}</td><td class="env">{e}</td>'
        f'<td><span class="pill {_PILL[st[k]][0]}">{_PILL[st[k]][1]}</span></td></tr>'
        for (r, d, e, k) in _RANK_ROWS
    )
    return f"""<title>GRAFCET &#8212; Calypso L1 DSP &rarr; camp &amp; couche 3</title>
<style>{_css()}</style>
<div class="wrap">
  <header>
    <p class="eyebrow">TI Calypso &#183; emulation QEMU &#183; baseband GSM &#183; mode {st.get('mode','?')} &#183; auto-genere par pytest</p>
    <h1>GRAFCET &#8212; romload &rarr; synchro L1 &rarr; camp &rarr; chiffrement</h1>
    <p class="sub">Etat-transition de la chaine go-live : chaque maillon est derive des VRAIS journaux du dernier run (dsp/qemu/osmocon/mobile.log, resolus par banc.py).</p>
    <div class="meta"><span>{ts}</span><span>FB {st.get('fb_n','?')} &#183; SB {st.get('sb_n','?')}</span><span>SI {st.get('si_n','?')} &#183; camp {st.get('camp_n','?')}</span><span>auth {st.get('auth_n','?')} &#183; chiffre {st.get('ciph_n','?')} &#183; TMSI {st.get('tmsi_n','?')}</span></div>
  </header>
  <div class="legend">
    <span><i class="dot d-src"></i>source</span><span><i class="dot d-ok"></i>valide</span>
    <span><i class="dot d-wip"></i>en cours</span><span><i class="dot d-bad"></i>manquant/bloque</span>
  </div>
  <div class="diagram"><pre class="mermaid">
{_mermaid(st)}
  </pre></div>
  <h2>Rang de blocage &#183; gates</h2>
  <table>
    <thead><tr><th>Rang</th><th>Maillon</th><th>Gate / wire</th><th>Etat</th></tr></thead>
    <tbody>
{rows}
    </tbody>
  </table>
  <p class="foot">Auto-genere par tests/conftest.py::pytest_sessionfinish &#8594; grafcet_gen.py &#183; statut derive de qemu/osmocon/mobile.log</p>
</div>
"""


def render_md(st: dict, ts: str = "") -> str:
    badge = {"ok": "`VALIDE`", "wip": "`EN COURS`", "bad": "`MANQUANT`"}

    def deent(s):
        return (s.replace("&#8594;", "->").replace("&#8212;", "-")
                 .replace("&#8722;", "-").replace("&#183;", "-"))

    rows = "\n".join(
        f"| {deent(r)} | {deent(d)} | `{deent(e)}` | {badge[st[k]]} |"
        for (r, d, e, k) in _RANK_ROWS
    )
    return f"""# GRAFCET — romload → synchro L1 → camp → chiffrement

*Auto-généré par `tests/conftest.py::pytest_sessionfinish` — statut dérivé des VRAIS journaux du dernier run (mode **{st.get('mode','?')}**, {ts}). Chemins résolus par `banc.py`.*

- L1 : FB **{st.get('fb_n','?')}** · SB **{st.get('sb_n','?')}** · RACH **{st.get('rach_n','?')}** · SDCCH **{st.get('sdcch_n','?')}**
- L3 : SI **{st.get('si_n','?')}** · camp **{st.get('camp_n','?')}** · auth **{st.get('auth_n','?')}** · chiffrement **{st.get('ciph_n','?')}** · TMSI **{st.get('tmsi_n','?')}** · LU acc/rej **{st.get('lu_ok','?')}/{st.get('lu_ko','?')}**

```mermaid
{_mermaid(st)}
```

## Maillons de la chaîne · journal/sonde

| Étape | Maillon | Journal / sonde | État |
|------|---------|-------------|------|
{rows}

> Chaîne ordonnée : la synchro L1 (FB/SB côté DSP ou gr-gsm) débloque le camping
> (SI + `normal service`), puis la couche 3 (RACH → SDCCH → authentification →
> chiffrement A5 → TMSI). 100 % = mobile campé, inscrit et chiffré.
"""


def _ascii(s: str) -> str:
    rep = {"→": "->", "—": "-", "−": "-", "·": "-", "∧": "et",
           "≤": "<=", "≥": ">=", "‘": "'", "’": "'"}
    for k, v in rep.items():
        s = s.replace(k, v)
    return s.encode("latin-1", "replace").decode("latin-1")



# ---- Grafcet interprété (dessin natif fpdf) + UML pipeline (graphviz dot) --------
# Chemin ORDONNE + poids (%) : FBSB (d_fb_det) et camping portent le max de %,
# les etages infra/amont peu (le % reflete la progression reelle vers le but, pas
# le nombre de tests). Somme des poids = 100.
# Derive de _CHAIN (code, libelle, clef, poids) : meme chaine ordonnee que le
# mermaid et la table ; le camping + chiffrement portent le gros du %.
_STAGES = [(code, label, key, w) for (code, key, label, w, detail) in _CHAIN]

def _stage_stt(st, key):
    return (st.get(key, "bad") if key in st else key) if key in ("ok", "wip", "bad") or key in st else "bad"

def _weighted_pct(st):
    """Progression ordonnee ponderee : ok=plein, wip=demi, bad=0.
    Retourne (pct_total, pct_cumul_chemin, [(code,label,w,stt,got)])."""
    rows = []
    got_sum = 0.0
    tot = sum(w for *_, w in _STAGES) or 1
    path_broken = False
    path_sum = 0.0
    for code, label, key, w in _STAGES:
        stt = st.get(key, "bad") if key in st else key
        if stt not in ("ok", "wip", "bad"):
            stt = "bad"
        got = 1.0 if stt == "ok" else (0.5 if stt == "wip" else 0.0)
        got_sum += got * w
        # chemin dans l'ordre : on cumule tant que la chaine tient (premier bad = mur)
        if not path_broken:
            path_sum += got * w
            if stt != "ok":
                path_broken = True
        rows.append((code, label, w, stt, got))
    return (round(100.0 * got_sum / tot), round(100.0 * path_sum / tot), rows)


def _draw_grafcet(pdf, st):
    """Grafcet GEMMA-like : etapes (boites carrees) + transitions verticales,
    couleur = statut. Rendu vectoriel natif (pas d'image)."""
    C = {"ok": (70, 195, 154), "wip": (230, 169, 78), "bad": (232, 106, 95)}
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 12); pdf.set_text_color(20, 40, 46)
    pdf.cell(0, 8, "GRAFCET interprete (etat go-live -> correlateur -> camp)", ln=1)
    pdf.set_text_color(20, 20, 20)
    pct_tot, pct_path, _rows = _weighted_pct(st)
    # barre de progression ponderee (chemin ordonne : FBSB & camping = max %)
    pdf.set_font("Helvetica", "B", 9)
    pdf.cell(0, 6, _ascii(f"Progression chemin (ponderee) : {pct_path}%   "
                          f"[FBSB 25% + camping 22% = 47% du but]  -  total etapes atteintes {pct_tot}%"), ln=1)
    bx, by, bwd, bhh = 14.0, pdf.get_y() + 1, 182.0, 5.0
    pdf.set_draw_color(120, 130, 134); pdf.set_fill_color(232, 236, 236)
    pdf.rect(bx, by, bwd, bhh, "DF")
    pdf.set_fill_color(70, 195, 154)
    pdf.rect(bx, by, bwd * pct_path / 100.0, bhh, "F")
    pdf.set_y(by + bhh + 2)
    x0 = 26.0; y = pdf.get_y() + 4
    bw, bh = 150.0, 8.5; gap = 4.0
    for i, (code, label, key, w) in enumerate(_STAGES):
        stt = st.get(key, "bad") if key in st else key
        if stt not in C: stt = "bad"
        r, g, b = C[stt]
        # transition (trait vertical + barre) entre etapes
        if i > 0:
            pdf.set_draw_color(90, 100, 105); pdf.set_line_width(0.4)
            cx = x0 + 8
            pdf.line(cx, y - gap, cx, y)
            pdf.line(cx - 3, y - gap/2, cx + 3, y - gap/2)  # barre de transition
        # etape : liseré gauche coloré + boite
        pdf.set_fill_color(r, g, b)
        pdf.rect(x0, y, 6, bh, "F")                       # marqueur etat
        pdf.set_draw_color(60, 70, 74); pdf.set_line_width(0.3)
        pdf.set_fill_color(246, 248, 248)
        pdf.rect(x0 + 8, y, bw, bh, "DF")                 # corps etape
        pdf.set_xy(x0 + 11, y + 1.6)
        pdf.set_font("Helvetica", "B", 8); pdf.set_text_color(30, 40, 44)
        pdf.cell(12, 5, _ascii(code), 0, 0)
        pdf.set_font("Helvetica", "", 8); pdf.set_text_color(35, 35, 35)
        pdf.cell(0, 5, _ascii(label), 0, 0)
        pdf.set_font("Helvetica", "", 7); pdf.set_text_color(110, 110, 110)
        pdf.set_xy(x0 + 8 + bw - 62, y + 1.6)
        pdf.cell(20, 5, _ascii(f"{w}%"), 0, 0, "R")
        pdf.set_text_color(r, g, b); pdf.set_font("Helvetica", "B", 7)
        pdf.set_xy(x0 + 8 + bw - 30, y + 1.6)
        pdf.cell(28, 5, {"ok": "CABLE", "wip": "EN COURS", "bad": "MANQUANT"}[stt], 0, 0, "R")
        pdf.set_text_color(20, 20, 20)
        y += bh + gap
        if y > 250:
            pdf.add_page(); y = pdf.get_y() + 4

def _uml_png(out_dir, st):
    """Genere un diagramme pipeline (graphviz dot -> PNG) colore par statut.
    Retourne le chemin PNG ou None si dot indisponible."""
    import subprocess, shutil
    if not shutil.which("dot"):
        return None
    C = {"ok": "#46c39a", "wip": "#e6a94e", "bad": "#e86a5f"}
    def col(key):
        return C.get(st.get(key, "bad"), "#e86a5f")
    # noeuds derives de _CHAIN : meme chaine que le mermaid, colores par statut.
    nodes = [("bts", "BTS\\nFCCH/SCH/BCCH", None)]
    nodes += [(key, f"{code}\\n{detail[:18]}", key) for (code, key, label, w, detail) in _CHAIN]
    edges = ["bts->" + _CHAIN[0][1]]
    edges += [f"{_CHAIN[i][1]}->{_CHAIN[i+1][1]}" for i in range(len(_CHAIN) - 1)]
    dot = ['digraph pipeline {', 'rankdir=LR;', 'bgcolor="white";',
           'node [shape=box,style="filled,rounded",fontname="Helvetica",fontsize=10,color="#333333"];',
           'edge [color="#5a7176",penwidth=1.2];']
    for nid, lbl, key in nodes:
        fill = "#6ea8d8" if key is None else col(key)
        dot.append(f'{nid} [label="{lbl}",fillcolor="{fill}"];')
    dot += edges
    dot.append('}')
    dpath = Path(out_dir) / "pipeline_uml.dot"
    ppath = Path(out_dir) / "pipeline_uml.png"
    dpath.write_text("\n".join(dot), encoding="utf-8")
    try:
        subprocess.run(["dot", "-Tpng", "-Gdpi=140", str(dpath), "-o", str(ppath)],
                       check=True, timeout=30, capture_output=True)
        return ppath if ppath.exists() else None
    except Exception:
        return None


def write_pdf(out_dir, ts: str = "") -> Path:
    """Rapport final PDF : grafcet (état) + pipeline + RANK + milestones + logs.
    Pur-Python (fpdf2), aucune dépendance système."""
    from fpdf import FPDF
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    st = derive_status()
    C = {"ok": (70, 195, 154), "wip": (230, 169, 78), "bad": (232, 106, 95)}
    MARK = {"ok": "[CABLE]", "wip": "[EN COURS]", "bad": "[MANQUANT]"}

    pdf = FPDF()
    pdf.set_auto_page_break(True, margin=16)
    pdf.add_page()
    pdf.set_fill_color(12, 20, 24)
    pdf.rect(0, 0, 210, 34, "F")
    pdf.set_text_color(56, 211, 194)
    pdf.set_font("Helvetica", "B", 9)
    pdf.set_xy(14, 9)
    pdf.cell(0, 5, "TI CALYPSO - EMULATION QEMU - BASEBAND GSM", ln=1)
    pdf.set_text_color(238, 246, 246)
    pdf.set_font("Helvetica", "B", 20)
    pdf.set_x(14)
    pdf.cell(0, 10, "GRAFCET - romload -> synchro L1 -> camp -> chiffrement", ln=1)
    pdf.set_text_color(90, 113, 118)
    pdf.set_font("Helvetica", "", 9)
    pdf.set_x(14)
    pdf.cell(0, 6, _ascii(f"Rapport final auto-genere par pytest  -  mode {st.get('mode','?')}  -  {ts}  -  "
                          f"FB {st.get('fb_n')} / SB {st.get('sb_n')} / camp {st.get('camp_n')} / chiffre {st.get('ciph_n')}"), ln=1)
    pdf.ln(8)
    pdf.set_text_color(20, 20, 20)

    def h2(t):
        pdf.ln(3); pdf.set_font("Helvetica", "B", 12); pdf.set_text_color(20, 40, 46)
        pdf.cell(0, 8, _ascii(t), ln=1); pdf.set_text_color(20, 20, 20)

    # --- GRAFCET interprete (dessin natif) ---
    try:
        _draw_grafcet(pdf, st)
    except Exception:
        pass
    # --- UML pipeline (graphviz dot -> PNG embarque) ---
    try:
        _up = _uml_png(out_dir, st)
        if _up:
            pdf.add_page()
            h2("Diagramme pipeline (UML)")
            pdf.image(str(_up), x=14, w=182)
    except Exception:
        pass
    # --- diagrammes MERMAID (grafcet/sequence/timeline) + TEMPORELS (matplotlib) ---
    try:
        for _title, _png in _all_diagram_pngs(out_dir, st):
            pdf.add_page(); h2(_title)
            try: pdf.image(str(_png), x=14, w=182)
            except Exception: pass
    except Exception:
        pass
    # --- pipeline (grafcet en étapes texte) ---
    h2("Pipeline (etapes)")
    pdf.set_font("Courier", "", 9)
    _cnt = {"fb": st.get("fb_n"), "sb": st.get("sb_n"), "si": st.get("si_n"),
            "camp": st.get("camp_n"), "rach": st.get("rach_n"),
            "sdcch": st.get("sdcch_n"), "auth": st.get("auth_n"),
            "cipher": st.get("ciph_n"), "tmsi": st.get("tmsi_n")}
    steps = []
    for code, key, label, w, detail in _CHAIN:
        n = _cnt.get(key)
        suffix = f"  (x{n})" if n not in (None, 0) else ""
        steps.append((st.get(key, "bad"), _ascii(f"{code:5} {label}  [{detail}]{suffix}")))
    for stt, line in steps:
        r, g, b = C[stt]
        pdf.set_text_color(r, g, b)
        pdf.cell(4, 5, "*", 0, 0)
        pdf.set_text_color(30, 30, 30)
        pdf.cell(0, 5, _ascii(line), ln=1)

    # --- table RANK ---
    h2("Rang de blocage - gates")
    pdf.set_font("Helvetica", "B", 8)
    pdf.set_fill_color(240, 242, 242)
    pdf.cell(18, 7, "Rang", 1, 0, "L", True)
    pdf.cell(92, 7, "Maillon", 1, 0, "L", True)
    pdf.cell(50, 7, "Gate / wire", 1, 0, "L", True)
    pdf.cell(0, 7, "Etat", 1, 1, "L", True)
    pdf.set_font("Helvetica", "", 7.5)
    for (r, dsc, e, k) in _RANK_ROWS:
        rr, gg, bb = C[st[k]]
        y = pdf.get_y()
        pdf.multi_cell(18, 6, _ascii(re.sub("&#[0-9]+;", "-", r)), 1, "L", False)
        pdf.set_xy(28, y)
        pdf.multi_cell(92, 6, _ascii(re.sub("&#[0-9]+;", "-", dsc))[:78], 1, "L", False)
        pdf.set_xy(120, y)
        pdf.multi_cell(50, 6, _ascii(re.sub("&#[0-9]+;", "-", e))[:34], 1, "L", False)
        pdf.set_xy(170, y)
        pdf.set_text_color(rr, gg, bb); pdf.set_font("Helvetica", "B", 7.5)
        pdf.cell(0, 6, MARK[st[k]], 1, 1, "L")
        pdf.set_text_color(20, 20, 20); pdf.set_font("Helvetica", "", 7.5)

    # --- milestones (depuis report.md du run si présent) ---
    rep = Path(out_dir) / "report.md"
    if not rep.exists():
        rep = Path(out_dir).parent / "report.md"
    if rep.exists():
        h2("Milestones (resultats pytest)")
        pdf.set_font("Courier", "", 7.5)
        txt = _ascii(rep.read_text(encoding="utf-8", errors="replace"))
        for line in txt.splitlines():
            if any(t in line for t in ("PASS", "FAIL", "XFAIL", "XPASS", "SKIP", "milestone", "PHASE")):
                pdf.set_x(pdf.l_margin)
                pdf.multi_cell(0, 4.4, line[:110] or " ")

    # --- rapport de tests COMPLET : test_results.md en BLOC CODE COLORE (dark) ---
    trp = Path(out_dir) / "test_results.md"
    if not trp.exists():
        trp = Path(out_dir).parent / "test_results.md"
    try:
        trtxt = trp.read_text(encoding="utf-8", errors="replace")
    except Exception:
        trtxt = ""
    if trtxt:
        pdf.add_page()
        h2("Rapport de tests complet (test_results.md)")
        pdf.set_font("Courier", "", 6.0)
        # syntaxe light-theme (style GitHub clair) sur FOND BLANC
        BG = (255, 255, 255)
        COL = {"hdr": (0, 92, 197), "ok": (34, 134, 58), "bad": (203, 36, 49),
               "warn": (176, 122, 0), "key": (111, 66, 193), "code": (3, 102, 102),
               "txt": (36, 41, 46)}
        def _cls(s):
            u = s.upper(); st = s.lstrip()
            if st.startswith("#"): return "hdr"
            if any(t in u for t in ("PASS", "[OK]", "[V]")): return "ok"
            if any(t in u for t in ("FAIL", " MUR", "[X]", "ERROR")): return "bad"
            if any(t in u for t in ("XFAIL", "XPASS", "SKIP", "[~]")): return "warn"
            if st.startswith("- **") or st.startswith("**") or st.startswith("|"): return "key"
            if st.startswith("`") or st.startswith(">"): return "code"
            return "txt"
        for raw in trtxt.splitlines():
            l = _tr(raw)
            r, g, b = COL[_cls(l)]
            pdf.set_text_color(r, g, b)
            if not l:
                pdf.set_x(pdf.l_margin); pdf.multi_cell(0, 3.1, " "); continue
            for i in range(0, len(l), 140):
                pdf.set_x(pdf.l_margin)
                pdf.multi_cell(0, 3.1, l[i:i+140] or " ")
        pdf.set_text_color(20, 20, 20)

    # --- annexes : logs ---
    def appendix(title, path, filt=None, maxlines=70):
        txt = _read(path)
        if not txt:
            return
        txt = re.sub(r"\x1b\[[0-9;]*m", "", txt)  # retire les couleurs ANSI (mobile.log)
        lines = txt.splitlines()
        if filt:
            lines = [l for l in lines if any(f in l for f in filt)]
        lines = lines[-maxlines:]
        if not lines:
            return
        pdf.add_page()
        h2("Annexe - " + title)
        pdf.set_font("Courier", "", 6.3)
        pdf.set_text_color(40, 40, 40)
        for l in lines:
            pdf.set_x(pdf.l_margin)
            pdf.multi_cell(0, 3.3, _ascii(l)[:138] or " ")

    appendix("dsp.log  (synchro L1 : jalon FB, SB, montant RACH/SDCCH, A5)", DSP_LOG,
             filt=["[jalon]", "SB PLAUSIBLE", "[montant]", "[a5-arm]", "tache FB"],
             maxlines=90)
    appendix("qemu.log  (pont DSP / trx : IMM ASS, canal dedie, A_SCH)", QEMU_LOG,
             filt=["pont DSP", "backend gr-gsm", "IMM ASS", "canal dedie",
                   "chiffrement A5", "[trx]", "[dcch]"], maxlines=70)
    appendix("osmocon.log  (romload, L1CTL)", OSMOCON_LOG,
             filt=["your code is running now", "L1CTL", "romload", "TOA AVG"], maxlines=45)
    appendix("mobile.log  (SI, camp, LU, auth, chiffrement, TMSI)", MOBILE_LOG,
             filt=["SYSTEM INFORMATION", "normal service", "LOCATION UPDATING",
                   "AUTHENTICATION", "CIPHERING", "TMSI", "camped"], maxlines=55)

    out = Path(out_dir) / "rapport.pdf"
    pdf.output(str(out))
    return out


# ============ Rendu mermaid (mmdc) + diagrammes temporels + Rmd/qmd ============
_MMDC = "/opt/node/bin/mmdc"
_PUPPET = "/root/.puppeteer.json"

_MMDC_PKG = os.environ.get("CALYPSO_MMDC_PKG", "@mermaid-js/mermaid-cli@11.4.2")

def _mmdc_cmd():
    """mmdc natif s'il existe, sinon repli sur `npx @mermaid-js/mermaid-cli`
    (deploie avec npx, aucune install globale requise)."""
    import shutil
    if os.path.exists(_MMDC):
        return [_MMDC]
    m = shutil.which("mmdc")
    if m:
        return [m]
    npx = shutil.which("npx")
    if npx:
        return [npx, "-y", _MMDC_PKG]
    return None

def _mermaid_png(mmd_text, out_png):
    import subprocess, os, shutil
    base = _mmdc_cmd()
    if not base:
        return None
    src_p = Path(out_png).with_suffix(".mmd")
    try:
        src_p.write_text(mmd_text, encoding="utf-8")
        env = dict(os.environ, PATH="/opt/node/bin:" + os.environ.get("PATH", ""))
        # Chromium refuse de tourner en root sans --no-sandbox : config auto si absente.
        puppet = _PUPPET
        if not os.path.exists(puppet):
            puppet = str(src_p.with_name("puppeteer.json"))
            if not os.path.exists(puppet):
                Path(puppet).write_text(
                    '{"args":["--no-sandbox","--disable-setuid-sandbox",'
                    '"--disable-gpu","--disable-dev-shm-usage"]}', encoding="utf-8")
        cmd = base + ["-i", str(src_p), "-o", str(out_png), "-b", "white", "-p", puppet]
        subprocess.run(cmd, check=True, timeout=300, capture_output=True, env=env)
        try:
            src_p.unlink()   # nettoie le .mmd temporaire (d_*.mmd) : seuls les vrais splits restent
        except Exception:
            pass
        return Path(out_png) if Path(out_png).exists() else None
    except Exception:
        return None

def _seq_diagram(st):
    def m(k):
        return {"ok": "OK", "wip": "wip"}.get(st.get(k), "MUR")
    return ("sequenceDiagram\n  autonumber\n"
            "  participant BTS\n  participant L1 as L1 (DSP/gr-gsm)\n"
            "  participant MS as Mobile (L2/L3)\n  participant NET as Reseau (MSC/HLR)\n"
            "  BTS->>L1: FCCH / SCH / BCCH (FN reelle)\n"
            "  L1->>L1: FB detecte " + m("fb") + " / SB plausible " + m("sb") + "\n"
            "  L1->>MS: SI 1/2/4 " + m("si") + "\n"
            "  MS->>MS: camp normal service " + m("camp") + "\n"
            "  MS->>BTS: RACH " + m("rach") + "\n"
            "  BTS-->>MS: IMM ASS -> SDCCH " + m("sdcch") + "\n"
            "  MS->>NET: Location Updating Request\n"
            "  NET-->>MS: AUTHENTICATION REQUEST " + m("auth") + "\n"
            "  NET-->>MS: CIPHERING MODE COMMAND (A5) " + m("cipher") + "\n"
            "  NET-->>MS: LU ACCEPT + TMSI " + m("tmsi") + "\n")

def _timeline_diagram(st):
    def m(k):
        return "OK" if st.get(k) == "ok" else ("wip" if st.get(k) == "wip" else "MUR")
    return ("timeline\n  title romload -> synchro L1 -> camp -> chiffrement\n"
            "  Boot : osmocon romload " + m("romload") + " : API RAM " + m("apiram") + "\n"
            "  Synchro L1 : FB " + m("fb") + " : SB " + m("sb") + "\n"
            "  Camp : SI 1/2/4 " + m("si") + " : normal service " + m("camp") + "\n"
            "  Dedie : RACH " + m("rach") + " : SDCCH " + m("sdcch") + "\n"
            "  Couche 3 : auth " + m("auth") + " : chiffrement " + m("cipher") +
            " : TMSI " + m("tmsi") + "\n")

def _temporal_plots(out_dir):
    """Series temporelles tirees des VRAIS journaux (dsp.log : budget trame,
    d_fb_det, rint). PNG best-effort via matplotlib ; aucune donnee -> aucun PNG."""
    pngs = []
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        dlog = banc.text("dsp") if banc is not None else _read(DSP_LOG)

        def series(text, pat):
            xs, ys = [], []
            for line in text.splitlines():
                mt = re.search(pat, line)
                if mt:
                    try:
                        xs.append(float(mt.group(1)))
                        ys.append(float(mt.group(2)))
                    except Exception:
                        pass
            return xs, ys

        specs = [
            (r"\[chrono\] fn=(\d+).*?\btrame ([0-9.]+)",
             "Budget trame DSP (ms) vs FN", "ms", "#1f7a7a", "t_trame.png"),
            (r"\[chrono\] fn=(\d+).*?DSP pire ([0-9.]+)",
             "Pire trame DSP (ms) vs FN", "ms", "#b07a00", "t_pire.png"),
            (r"\bfn=(\d+)\b.*?d_fb_det=(\d+)",
             "d_fb_det vs FN", "d_fb_det", "#2e7d32", "t_fbdet.png"),
            (r"\[vsp\] fn=(\d+).*?rint=(\d+)",
             "rint (frame-IRQ cumul) vs FN", "rint", "#3a5fa0", "t_rint.png"),
        ]
        for pat, title, ylab, col, fn in specs:
            xs, ys = series(dlog, pat)
            if not xs:
                continue
            plt.figure(figsize=(9, 2.5)); plt.plot(xs, ys, lw=0.8, color=col)
            plt.title(title); plt.xlabel("FN"); plt.ylabel(ylab)
            plt.grid(alpha=.3); plt.tight_layout()
            p = Path(out_dir) / fn; plt.savefig(p, dpi=130); plt.close()
            pngs.append((title, p))
    except Exception:
        pass
    return pngs

def _all_diagram_pngs(out_dir, st):
    res = []
    g = _mermaid_png(_mermaid(st), str(Path(out_dir) / "d_grafcet.png"))
    if g: res.append(("GRAFCET (mermaid interprete)", g))
    sq = _mermaid_png(_seq_diagram(st), str(Path(out_dir) / "d_sequence.png"))
    if sq: res.append(("Sequence go-live (ARM/DSP/correlateur)", sq))
    tl = _mermaid_png(_timeline_diagram(st), str(Path(out_dir) / "d_timeline.png"))
    if tl: res.append(("Timeline milestones", tl))
    for mmd, title in (("pipeline.qmd.mmd", "Pipeline (arbre mermaid)"),
                       ("detail.qmd.mmd", "Detail tests par module (UML)")):
        p = Path(out_dir) / mmd
        if not p.exists():
            p = Path(out_dir).parent / mmd
        if p.exists():
            out = str(Path(out_dir) / (mmd.replace(".mmd", "") + ".png"))
            r = _mermaid_png(p.read_text(encoding="utf-8", errors="replace"), out)
            if r: res.append((title, r))
    res += _temporal_plots(out_dir)
    return res

def _report_md_body(st, ts):
    tot, path, rows = _weighted_pct(st)
    out = ["**Progression chemin (ponderee, ordonnee) : %d %%**  " % path,
           "camp 20%% + chiffrement 10%% + SI 10%% = cible L3 ; total etapes %d %%  " % tot,
           "mode %s - FB %s / SB %s / camp %s / chiffre %s - %s" % (
               st.get("mode"), st.get("fb_n"), st.get("sb_n"),
               st.get("camp_n"), st.get("ciph_n"), ts), "",
           "| Etape | Poids | Etat | Description |", "|---|---|---|---|"]
    for code, label, w, stt, got in rows:
        badge = {"ok": "OK", "wip": "en cours", "bad": "MUR"}[stt]
        out.append("| %s | %d%% | %s | %s |" % (code, w, badge, label))
    return "\n".join(out)

def _strip_ctrl(s):
    """Retire les caracteres de controle C0/C1 (U+0080 etc.) que LaTeX refuse."""
    import re
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]", "", s or "")

def _diagram_section(out_dir, st):
    """Markdown des diagrammes : uniquement les PNG REELLEMENT generes (existants).
    Evite les 'Could not fetch resource t_*.png' quand un plot n'a pas de donnees."""
    md = []
    for title, p in _all_diagram_pngs(out_dir, st):
        try:
            if Path(p).exists():
                md.append("## " + title + "\n\n![" + title + "](" + Path(p).name + ")\n")
        except Exception:
            pass
    return "\n".join(md) if md else "_(aucun diagramme genere)_\n"

def _write_mmd_files(out_dir, st):
    """Ecrit chaque diagramme mermaid dans son propre .mmd A COTE du qmd/Rmd."""
    out = Path(out_dir); files = {}
    for name, gen in (("grafcet", _mermaid), ("sequence", _seq_diagram), ("timeline", _timeline_diagram)):
        try:
            txt = _deaccent(gen(st)).replace("'", "")
            (out / (name + ".mmd")).write_text(txt, encoding="utf-8")
            files[name] = name + ".mmd"
        except Exception:
            pass
    return files

def _temporal_png_md(out_dir, st):
    md = []
    for title, p in _all_diagram_pngs(out_dir, st):
        nm = Path(p).name
        if nm.startswith("t_") and Path(p).exists():
            md.append("## " + title + "\n\n![" + title + "](" + nm + ")\n")
    return "\n".join(md) if md else "_(pas de donnees log pour les plots temporels)_\n"

def write_qmd(out_dir, ts=""):
    st = derive_status()
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    tr = _read(str(Path(out_dir) / "test_results.md")) or _read(str(Path(out_dir).parent / "test_results.md"))
    parts = []
    parts.append("---\ntitle: \"Calypso GSM - GRAFCET go-live & tests\"\nsubtitle: \"%s\"\n"
                 "format:\n  html:\n    toc: true\n    code-fold: true\nmermaid:\n  theme: default\n---\n" % ts)
    parts.append("# Synthese\n\n" + _report_md_body(st, ts) + "\n")
    _write_mmd_files(out_dir, st)   # grafcet.mmd / sequence.mmd / timeline.mmd splittes A COTE (source editable)
    # Contenu INLINE (le %%| file: externe n'est pas supporte par tous les Quarto ;
    # l'inline rend partout, comme test_results.qmd). ASCII + <br/>->espace + sans quote-cassantes.
    def _mm_inline(txt):
        return _deaccent(txt).replace("<br/>", " ").replace("<br>", " ").replace("'", "")
    for _t, _g in (("GRAFCET interprete", _mermaid), ("Sequence go-live", _seq_diagram), ("Timeline milestones", _timeline_diagram)):
        parts.append("# " + _t + "\n\n```{mermaid}\n" + _mm_inline(_g(st)) + "\n```\n")
    parts.append("# Diagrammes temporels\n\n" + _temporal_png_md(out_dir, st))
    parts.append("# Rapport de tests COMPLET (test_results.md)\n\n" + _strip_ctrl((tr or "_(absent)_").replace("'", "")) + "\n")
    p = out / "rapport_final.qmd"
    p.write_text(_deaccent("\n".join(parts)), encoding="utf-8")
    return p

def write_rmd(out_dir, ts=""):
    st = derive_status()
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    tr = _read(str(Path(out_dir) / "test_results.md")) or _read(str(Path(out_dir).parent / "test_results.md"))
    parts = []
    parts.append("---\ntitle: \"Calypso GSM - GRAFCET go-live & tests\"\nsubtitle: \"%s\"\n"
                 "output:\n  html_document:\n    toc: true\n    toc_float: true\n---\n" % ts)
    parts.append("```{r setup, include=FALSE}\nknitr::opts_chunk$set(echo = FALSE)\n```\n")
    parts.append("# Synthese\n\n" + _report_md_body(st, ts) + "\n")
    # PNG rendus par mmdc (bulletproof, aucune dep) ; seulement ceux qui existent
    _mm = _write_mmd_files(out_dir, st)   # .mmd splittes A COTE du Rmd
    for _t, _k, _png in (("GRAFCET interprete", "grafcet", "d_grafcet.png"),
                         ("Sequence go-live", "sequence", "d_sequence.png"),
                         ("Timeline milestones", "timeline", "d_timeline.png")):
        if (Path(out_dir) / _png).exists():
            parts.append("# " + _t + "\n\n![" + _t + "](" + _png + ")  \n_source mermaid : " + _mm.get(_k, _k + ".mmd") + "_\n")
    parts.append("# Diagrammes temporels\n\n" + _temporal_png_md(out_dir, st))
    parts.append("# Rapport de tests COMPLET (test_results.md)\n\n```\n" + _strip_ctrl((tr or "(absent)").replace("'", "")) + "\n```\n")
    p = out / "rapport.Rmd"
    p.write_text(_deaccent("\n".join(parts)), encoding="utf-8")
    return p


def write_grafcet(out_dir, ts: str = "") -> list:
    """Écrit grafcet.html + grafcet.md (+ rapport_final.pdf) dans out_dir."""
    st = derive_status()
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    h = out / "grafcet.html"
    m = out / "grafcet.md"
    h.write_text(render_html(st, ts), encoding="utf-8")
    m.write_text(render_md(st, ts), encoding="utf-8")
    paths = [h, m]
    try:
        paths.append(write_pdf(out_dir, ts))
    except Exception:
        pass  # PDF best-effort (fpdf2 requis)
    # qmd unifie produit par conftest (rapport.qmd) ; ici seulement le Rmd
    try: paths.append(write_rmd(out_dir, ts))
    except Exception: pass
    return paths


if __name__ == "__main__":
    import sys
    d = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
    paths = write_grafcet(d)
    print("grafcet écrit:", *[str(p) for p in paths])
