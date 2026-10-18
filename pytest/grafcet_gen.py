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
import warnings as _warnings
from pathlib import Path

# fpdf2 >=2.5.2 avertit sur cell(ln=...) : on garde l'API courte, on tait le bruit.
_warnings.filterwarnings("ignore", message=r'.*parameter "ln" is deprecated.*')

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
    chemin). Repli _read(path) si banc indisponible. Si un run est fixe
    (_use_run_logs), on lit SON journal et rien d'autre : banc.log() choisit le
    plus recent par date, ce qui ferait gagner la pile live sur le run."""
    if _RUN_DIR:
        p = os.path.join(_RUN_DIR, f"{name}.log")
        if not os.path.isfile(p):
            return 0          # journal absent du run : pas de repli live (melange)
        rx = re.compile(pat)
        txt = re.sub(r"\x1b\[[0-9;]*m", "", _read(p))
        return sum(1 for ln in txt.splitlines() if rx.search(ln))
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
    lostcov_n = _count("mobile", r"MM_EVENT_LOST_COVERAGE")   # perte de couverture cote MM
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
        # LOS en dedie / crash = MANQUANT ; perte de couverture MM (recuperee) = EN COURS
        radio=("bad" if (los_n or crash_n) else ("wip" if lostcov_n else "ok")),
    )
    # metriques exposees (rendu / meta)
    st.update(mode=(banc.MODE if banc is not None else "?"),
              fb_n=fb_n, sb_n=sb_n, rach_n=rach_n, sdcch_n=sdcch_n, a5_n=a5_n,
              si_n=si_n, camp_n=camp_n, auth_n=auth_n, ciph_n=ciph_n,
              tmsi_n=tmsi_n, lu_ok=lu_ok, lu_ko=lu_ko, los_n=los_n,
              crash_n=crash_n, lostcov_n=lostcov_n, romload_n=romload)
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
    ("LINK", "radio",   "lien radio tenu (ni LOS ni perte de couverture)", 6, "LOS / LOST_COVERAGE / crash = 0"),
]


def _mermaid(st: dict) -> str:
    c = lambda k: _MERMAID_CLASS.get(st.get(k, "bad"), "bad")
    head = ("""flowchart TD
  classDef src  fill:#eef4fb,stroke:#2780e3,stroke-width:1px,color:#1a4f8a;
  classDef ok   fill:#eaf7f0,stroke:#2e9e6a,stroke-width:1px,color:#145c3c;
  classDef wip  fill:#fdf4e3,stroke:#c08a16,stroke-width:1px,color:#7a5600;
  classDef bad  fill:#fdeceb,stroke:#d6484f,stroke-width:1.4px,color:#8f2b2f;
  classDef join fill:#e8f6f4,stroke:#1a9c8e,stroke-width:1.4px,color:#0c5f57;

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
    pdf.cell(0, 8, "GRAFCET interprete (romload -> synchro L1 -> camp -> chiffrement)", ln=1)
    pdf.set_text_color(20, 20, 20)
    pct_tot, pct_path, _rows = _weighted_pct(st)
    # barre de progression ponderee (chemin ordonne : camp + chiffrement = max %)
    pdf.set_font("Helvetica", "B", 9)
    pdf.cell(0, 6, _ascii(f"Progression chemin (ponderee) : {pct_path}%   "
                          f"[camp 20% + chiffrement 10% + SI 10% = cible L3]  -  total etapes atteintes {pct_tot}%"), ln=1)
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

    # --- LE GRAFCET, une seule fois : dessin natif (fiable, sans npx), avec
    #     barre de progression ponderee + etapes colorees. Pas de doublon :
    #     ni graphviz UML, ni PNG mermaid du grafcet, ni liste d'etapes texte. ---
    try:
        _draw_grafcet(pdf, st)
    except Exception:
        pass
    # --- figures complementaires (chacune UNE fois) : sequence, timeline,
    #     puis plots temporels. Le grafcet n'est PAS re-rendu ici. ---
    figs = []
    try:
        sq = _mermaid_png(_seq_diagram(st), str(Path(out_dir) / "d_sequence.png"))
        if sq: figs.append(("Sequence : BTS -> L1 -> mobile -> reseau", sq))
        tl = _mermaid_png(_timeline_diagram(st), str(Path(out_dir) / "d_timeline.png"))
        if tl: figs.append(("Timeline : romload -> camp -> chiffrement", tl))
        figs += _temporal_plots(out_dir)
    except Exception:
        pass
    for _title, _png in figs:
        try:
            pdf.add_page(); h2(_title); pdf.image(str(_png), x=14, w=182)
        except Exception:
            pass

    # --- table des maillons (detail par etape, pas une figure) ---
    h2("Maillons de la chaine - journal / sonde")
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

    # --- résumé des tests : MÊME source que le bandeau HTML (run archivé si
    #     fourni, sinon live). Plus de report.md / test_results.md hérités de
    #     l'ancien banc (ALL PASS 39/55, IrDA, abstract.py, /home/nirvana…). ---
    try:
        s = tests_summary(run_dir=_RUN_DIR) if _RUN_DIR else {}
    except Exception:
        s = {}
    if s and not s.get("error") and s.get("total"):
        p_, f_, sk_ = s.get("passed", 0), s.get("failed", 0), s.get("skipped", 0)
        ex_ = p_ + f_ + s.get("errors", 0)
        h2("Resume des tests (run %s)" % (s.get("source") or "?"))
        pdf.set_font("Helvetica", "", 9)
        pdf.cell(0, 6, _ascii("%d reussis / %d executes - %d echec(s) - %d saute(s) - %d collectes"
                              % (p_, ex_, f_ + s.get("errors", 0), sk_, s.get("total", 0))), ln=1)
        pdf.set_font("Courier", "", 8.5)
        for nom, b in s.get("batteries", {}).items():
            ne = b.get("passed", 0) + b.get("failed", 0) + b.get("errors", 0)
            sk = b.get("skipped", 0)
            pdf.cell(0, 5, _ascii("  %-9s %3d/%-3d executes%s" % (
                nom, b.get("passed", 0), ne, ("   +%d sautes (N/A ce mode / opt-in)" % sk) if sk else "")), ln=1)

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

def _mermaid_png(mmd_text, out_png, scale=1):
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
        cmd = base + ["-i", str(src_p), "-o", str(out_png), "-b", "white", "-p", puppet, "-s", str(scale)]
        subprocess.run(cmd, check=True, timeout=300, capture_output=True, env=env)
        try:
            src_p.unlink()   # nettoie le .mmd temporaire (d_*.mmd) : seuls les vrais splits restent
        except Exception:
            pass
        return Path(out_png) if Path(out_png).exists() else None
    except Exception:
        return None

def _mermaid_svg(mmd_text, out_svg):
    """Rend un .mmd en SVG (vectoriel, net, leger) via mmdc/npx. None si echec."""
    import subprocess
    base = _mmdc_cmd()
    if not base:
        return None
    src_p = Path(out_svg).with_suffix(".mmdsrc")
    try:
        src_p.write_text(mmd_text, encoding="utf-8")
        env = dict(os.environ, PATH="/opt/node/bin:" + os.environ.get("PATH", ""))
        puppet = _PUPPET
        if not os.path.exists(puppet):
            puppet = str(src_p.with_name("puppeteer.json"))
            if not os.path.exists(puppet):
                Path(puppet).write_text(
                    '{"args":["--no-sandbox","--disable-setuid-sandbox",'
                    '"--disable-gpu","--disable-dev-shm-usage"]}', encoding="utf-8")
        cmd = base + ["-i", str(src_p), "-o", str(out_svg), "-b", "transparent", "-p", puppet]
        subprocess.run(cmd, check=True, timeout=300, capture_output=True, env=env)
        try:
            src_p.unlink()
        except Exception:
            pass
        return Path(out_svg) if Path(out_svg).exists() else None
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


def _b64_img(path: Path) -> str:
    """data: URI d'une image (PNG/SVG) pour une page autonome ; '' si absente."""
    import base64, mimetypes
    try:
        if not path.is_file():
            return ""
        mt = mimetypes.guess_type(str(path))[0] or "image/png"
        return f"data:{mt};base64," + base64.b64encode(path.read_bytes()).decode()
    except Exception:
        return ""


_RUN_DIR = None


def _use_run_logs(run_dir) -> str:
    """Pointe les journaux de grafcet_gen (via banc : override CALYPSO_*_LOG) sur
    ceux du RUN archivé donné, pour que grafcet/bandeau/PDF viennent du MÊME run
    que le dossier. Retourne le nom du run, ou ""."""
    global _RUN_DIR
    if not run_dir or not os.path.isdir(run_dir):
        return ""
    _RUN_DIR = run_dir
    for name in ("qemu", "dsp", "osmocon", "mobile", "pont"):
        p = os.path.join(run_dir, f"{name}.log")
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            os.environ[f"CALYPSO_{name.upper()}_LOG"] = p
    # recharge les chemins module (QEMU_LOG/… relus par _logpath)
    global QEMU_LOG, OSMOCON_LOG, MOBILE_LOG, DSP_LOG
    QEMU_LOG = _logpath("qemu", os.environ.get("CALYPSO_QEMU_LOG"))
    OSMOCON_LOG = _logpath("osmocon", os.environ.get("CALYPSO_OSMOCON_LOG"))
    MOBILE_LOG = _logpath("mobile", os.environ.get("CALYPSO_MOBILE_LOG"))
    DSP_LOG = _logpath("dsp", os.environ.get("CALYPSO_DSP_LOG"))
    return os.path.basename(run_dir.rstrip("/"))


def _tests_summary_from_run(run_dir) -> dict:
    """Résumé par batterie lu dans les existant-pytest-*.txt du RUN archivé
    (ligne « counts : {...} » écrite par conftest). Aucun pytest relancé :
    cohérent avec le dossier et le GRAFCET du même run."""
    import ast, glob
    bat, tot = {}, dict(passed=0, failed=0, skipped=0, xfailed=0, xpassed=0, errors=0)
    files = sorted(glob.glob(os.path.join(run_dir, "existant-pytest-*.txt")))
    for f in files:
        m0 = re.search(r"existant-pytest-([a-z0-9]+)\.txt", os.path.basename(f))
        nom = m0.group(1) if m0 else os.path.basename(f)
        try:
            txt = open(f, errors="replace").read()
        except OSError:
            continue
        m = re.search(r"counts\s*:\s*(\{[^}]*\})", txt)
        c = {}
        if m:
            try:
                c = ast.literal_eval(m.group(1))
            except Exception:
                c = {}
        if not c:  # repli : ligne « N passed, M skipped, K failed »
            for k in ("passed", "failed", "skipped", "xfailed"):
                mm = re.search(r"(\d+) " + k, txt)
                if mm:
                    c[k] = int(mm.group(1))
        b = dict(passed=c.get("passed", 0), failed=c.get("failed", 0),
                 skipped=c.get("skipped", 0), xfailed=c.get("xfailed", 0),
                 xpassed=0, errors=c.get("errors", 0))
        bat[nom] = b
        for k in tot:
            tot[k] += b.get(k, 0)
    total = sum(tot.values())
    if not files:
        return {"error": "aucun existant-pytest-*.txt dans le run"}
    return dict(total=total, batteries=bat, source=os.path.basename(run_dir.rstrip("/")), **tot)


def tests_summary(testdir=None, timeout=300, run_dir=None) -> dict:
    """Résumé par batterie. Si run_dir : lu dans le RUN archivé (cohérent avec
    le dossier). Sinon : lance les batteries pytest sur la pile vivante.
    Retourne {total, passed, failed, skipped, xfailed, errors, batteries, source?}."""
    if run_dir:
        return _tests_summary_from_run(run_dir)
    import subprocess
    testdir = testdir or str(Path(__file__).resolve().parent)
    py = os.environ.get("CALYPSO_PY", _sys.executable)
    try:
        r = subprocess.run(
            [py, "-m", "pytest", testdir, "-v", "--tb=no", "-p", "no:cacheprovider",
             "--continue-on-collection-errors", "-o", "addopts=",
             "--ignore", os.path.join(testdir, "legacy"),
             "--ignore", os.path.join(testdir, "archives")],
            capture_output=True, text=True, timeout=timeout, cwd=testdir)
        out = r.stdout + "\n" + r.stderr
    except Exception as e:
        return {"error": str(e)}
    bat = {}
    tot = dict(passed=0, failed=0, skipped=0, xfailed=0, xpassed=0, errors=0)
    rxl = re.compile(r"^(test_\d+_([a-z]+)[\w]*\.py)::\S+?\s+(PASSED|FAILED|SKIPPED|XFAIL|XPASS|ERROR)")
    KEY = {"PASSED": "passed", "FAILED": "failed", "SKIPPED": "skipped",
           "XFAIL": "xfailed", "XPASS": "xpassed", "ERROR": "errors"}
    for ln in out.splitlines():
        m = rxl.match(ln.strip())
        if not m:
            continue
        nom, verdict = m.group(2), KEY[m.group(3)]
        b = bat.setdefault(nom, dict(passed=0, failed=0, skipped=0, xfailed=0, xpassed=0, errors=0))
        b[verdict] += 1
        tot[verdict] += 1
    total = sum(tot.values())
    if total == 0:
        # repli : la ligne de synthese « N passed, M skipped » si le -v n'a rien donne
        for k in tot:
            mm = re.search(r"(\d+) " + k, out)
            if mm:
                tot[k] = int(mm.group(1))
        total = sum(tot.values())
    return dict(total=total, batteries=bat, **tot)


def tests_summary_fragment(summary: dict, ts: str = "", run: str = "") -> str:
    """Bandeau SOBRE (thème cosmo du sous-domaine via --bg/--fg/--line/--acc) en
    tête de page : réussis/exécutés (jamais « 100% » si des tests sont sautés),
    tuiles passed/failed/skipped, barre par batterie (dénominateur = exécutés,
    les sauts N/A ne comptent pas comme trous), run source, horodatage."""
    s = summary or {}
    if s.get("error") or not s.get("total"):
        return (f'<section id="tests-panel"><p style="color:var(--mute,#6c757d)">'
                f'Résumé des tests indisponible{(" : " + s["error"]) if s.get("error") else ""}.</p></section>')
    passed, failed, skipped = s.get("passed", 0), s.get("failed", 0), s.get("skipped", 0)
    xf, err = s.get("xfailed", 0), s.get("errors", 0)
    total = s.get("total", 0)
    actifs = passed + failed  # tests qui ont reellement statue (ni sautes ni xfail)
    taux = round(100 * passed / actifs) if actifs else 0
    verdict = "OK" if failed == 0 and err == 0 else f"{failed + err} EN ÉCHEC"
    vcol = "var(--gok)" if failed == 0 and err == 0 else "var(--gbad)"

    tiles = [("passed", passed, "var(--gok)"), ("failed", failed, "var(--gbad)"),
             ("skipped", skipped, "var(--mute,#6c757d)")]
    if xf:
        tiles.append(("xfail", xf, "var(--gwip)"))
    if err:
        tiles.append(("errors", err, "var(--gbad)"))
    tcells = "".join(
        f'<div class="ttile"><div class="tv" style="color:{c}">{v}</div><div class="tk">{k}</div></div>'
        for k, v, c in tiles)

    order = ["infra", "couche1", "mobile", "reseau", "actif"]
    bats = s.get("batteries", {})
    rows = []
    for nom in order + [b for b in bats if b not in order]:
        b = bats.get(nom)
        if not b:
            continue
        p, f, sk = b.get("passed", 0), b.get("failed", 0), b.get("skipped", 0)
        # denominateur = EXECUTES (passed+failed) : les sauts (mode N/A, opt-in)
        # ne sont pas des trous de couverture, on les note a part.
        nexec = p + f + b.get("errors", 0)
        wok = round(100 * p / nexec) if nexec else 0
        wko = round(100 * (f + b.get("errors", 0)) / nexec) if nexec else 0
        skn = f' <span class="bsk">+{sk} sautés</span>' if sk else ""
        bar = (f'<span class="bbar"><i style="width:{wok}%;background:var(--gok)"></i>'
               f'<i style="width:{wko}%;background:var(--gbad)"></i></span>') if nexec else \
              '<span class="bbar bempty"></span>'
        rows.append(
            f'<div class="brow"><span class="bn">{nom}</span>{bar}'
            f'<span class="bc">{p}/{nexec}{skn}</span></div>')
    rows_html = "\n".join(rows)
    skip_note = (f'<div class="tnote">&#9888; Couverture partielle : {skipped} test(s) '
                 f'non ex&eacute;cut&eacute;(s) (saut&eacute;s) — le taux porte sur les {actifs} '
                 f'ex&eacute;cut&eacute;s, pas sur la couverture totale.</div>') if skipped else ""
    src = run or s.get("source", "")
    gen = (f'<span class="tgen">{("run " + src + " &middot; ") if src else ""}'
           f'g&eacute;n&eacute;r&eacute; {ts}</span>') if (ts or src) else ""

    return f"""<section id="tests-panel">
<style>
  #tests-panel{{--gok:#2e9e6a;--gwip:#c08a16;--gbad:#d6484f;
    --gmono:ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace;
    background:var(--side,#f8f9fa);color:var(--fg,#212529);
    border:1px solid var(--line,#dee2e6);border-radius:14px;padding:24px;margin:10px 0 18px}}
  #tests-panel *{{box-sizing:border-box}}
  #tests-panel .thead{{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:2px}}
  #tests-panel .tbig{{font:700 34px var(--gmono);color:var(--fg,#212529)}}
  #tests-panel .tlab{{font:500 14px var(--gmono);color:var(--mute,#6c757d)}}
  #tests-panel .tverd{{font:700 13px var(--gmono);letter-spacing:.08em;padding:3px 10px;border-radius:20px;color:#fff;background:{vcol}}}
  #tests-panel .tgen{{margin-left:auto;font:500 12px var(--gmono);color:var(--mute,#6c757d)}}
  #tests-panel .tmeta{{color:var(--mute,#6c757d);font-size:13px;margin-top:2px}}
  #tests-panel .tnote{{margin-top:12px;font-size:12.5px;color:var(--gwip);background:rgba(192,138,22,.08);
    border:1px solid rgba(192,138,22,.3);border-radius:8px;padding:8px 12px}}
  #tests-panel .ttiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(90px,1fr));gap:10px;margin:16px 0}}
  #tests-panel .ttile{{background:var(--bg,#fff);border:1px solid var(--line,#dee2e6);border-radius:10px;padding:12px 8px;text-align:center}}
  #tests-panel .tv{{font:700 24px var(--gmono)}}
  #tests-panel .tk{{font-family:var(--gmono);font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--mute,#6c757d);margin-top:3px}}
  #tests-panel .brow{{display:flex;align-items:center;gap:12px;margin:7px 0;font-size:13px}}
  #tests-panel .bn{{flex:0 0 76px;font-family:var(--gmono);color:var(--fg,#212529)}}
  #tests-panel .bbar{{flex:1;display:flex;height:9px;border-radius:5px;overflow:hidden;background:var(--line,#dee2e6);min-width:40px}}
  #tests-panel .bbar i{{display:block;height:100%}}
  #tests-panel .bc{{flex:0 0 auto;font-family:var(--gmono);color:var(--mute,#6c757d);font-variant-numeric:tabular-nums}}
  #tests-panel .bsk{{color:var(--mute,#6c757d);font-size:11px}}
  #tests-panel .bempty{{background:repeating-linear-gradient(45deg,var(--line,#dee2e6) 0 4px,transparent 4px 8px)}}
</style>
<div class="thead">
  <span class="tbig">{passed}</span><span class="tlab">r&eacute;ussis / {actifs} ex&eacute;cut&eacute;s</span>
  <span class="tverd">{verdict}</span>
  {gen}
</div>
<div class="tmeta">{failed} &eacute;chec(s) &middot; {skipped} saut&eacute;(s) &middot; {total} collect&eacute;s &middot; {taux}% des ex&eacute;cut&eacute;s r&eacute;ussis</div>
<div class="ttiles">{tcells}</div>
{rows_html}
{skip_note}
</section>"""


def grafcet_fragment(out_dir, ts: str = "", pdf_href: str = "rapport.pdf", run: str = "") -> str:
    """Fragment HTML AUTONOME et SCOPE (tout sous #grafcet-panel) a injecter dans
    une autre page (ex. le dossier tests.pl4y.store) : anneau de progression,
    chips par maillon, SVG grafcet inline, bouton PDF. N'embarque QUE le grafcet
    (sequence/timeline/plots restent dans le PDF). grafcet.svg doit exister dans
    out_dir (rendu npx)."""
    out = Path(out_dir)
    st = derive_status()
    tot, path, rows = _weighted_pct(st)

    def svg_inline(name):
        p = out / name
        if not p.is_file():
            return ""
        s = p.read_text(encoding="utf-8", errors="replace")
        s = re.sub(r"<\?xml.*?\?>", "", s, flags=re.S)
        s = re.sub(r"<!DOCTYPE.*?>", "", s, flags=re.S)
        return s

    _CNT = {"fb": "fb_n", "sb": "sb_n", "si": "si_n", "camp": "camp_n",
            "rach": "rach_n", "sdcch": "sdcch_n", "auth": "auth_n",
            "cipher": "ciph_n", "tmsi": "tmsi_n"}
    chips = []
    for code, key, label, w, detail in _CHAIN:
        stt = st.get(key, "bad")
        n = st.get(_CNT.get(key, ""), "")
        badge = {"ok": "VALIDE", "wip": "EN COURS", "bad": "MANQUANT"}[stt]
        cnt = f'<span class="gn">&times;{n}</span>' if (n not in ("", 0, None)) else ""
        chips.append(
            f'<div class="gchip g-{stt}"><div class="gch"><span class="gcode">{code}</span>{cnt}'
            f'<span class="gbadge">{badge}</span></div>'
            f'<div class="glabel">{label}</div><div class="gdet">{detail}</div></div>')
    chips_html = "\n".join(chips)

    R, circ = 46, 2 * 3.14159 * 46
    dash = circ * path / 100.0
    ring = (f'<svg viewBox="0 0 120 120" class="gring"><circle cx="60" cy="60" r="{R}" '
            f'class="grb"/><circle cx="60" cy="60" r="{R}" class="grf" '
            f'stroke-dasharray="{dash:.1f} {circ:.1f}" transform="rotate(-90 60 60)"/>'
            f'<text x="60" y="56" class="grp">{path}%</text>'
            f'<text x="60" y="76" class="grs">chemin</text></svg>')

    metrics = [("FB", st.get("fb_n")), ("SB", st.get("sb_n")), ("SI", st.get("si_n")),
               ("camp", st.get("camp_n")), ("RACH", st.get("rach_n")),
               ("SDCCH", st.get("sdcch_n")), ("auth", st.get("auth_n")),
               ("chiffre", st.get("ciph_n")), ("TMSI", st.get("tmsi_n")),
               ("LU", f"{st.get('lu_ok')}/{st.get('lu_ko')}")]
    mcells = "".join(f'<div class="gmetric"><div class="gmv">{v}</div><div class="gmk">{k}</div></div>'
                     for k, v in metrics)
    graf_svg = svg_inline("grafcet.svg")
    pdf_btn = (f'<a class="gdl" href="{pdf_href}" download>&#11015; Rapport PDF</a>'
               if pdf_href else "")

    # Styles SCOPES qui HERITENT des variables du sous-domaine tests.pl4y.store
    # (theme cosmo : --bg --fg --mute --line --side --acc, light/dark natif) avec
    # des fallbacks si injecte ailleurs. Seules les couleurs de STATUT sont
    # fixees (semantique vert/ambre/rouge, lisibles sur les deux fonds).
    return f"""<section id="grafcet-panel">
<style>
  #grafcet-panel{{--gok:#2e9e6a;--gwip:#c08a16;--gbad:#d6484f;
    --gmono:ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace;
    background:var(--side,#f8f9fa);color:var(--fg,#212529);
    border:1px solid var(--line,#dee2e6);border-radius:14px;padding:24px;margin:10px 0 30px}}
  #grafcet-panel *{{box-sizing:border-box}}
  #grafcet-panel .ghead{{display:flex;gap:22px;align-items:center;flex-wrap:wrap}}
  #grafcet-panel .gring{{width:100px;height:100px;flex:0 0 auto}}
  #grafcet-panel .grb{{fill:none;stroke:var(--line,#dee2e6);stroke-width:10}}
  #grafcet-panel .grf{{fill:none;stroke:var(--acc,#2780e3);stroke-width:10;stroke-linecap:round}}
  #grafcet-panel .grp{{fill:var(--fg,#212529);font:600 23px var(--gmono);text-anchor:middle}}
  #grafcet-panel .grs{{fill:var(--mute,#6c757d);font:500 10px var(--gmono);text-anchor:middle;letter-spacing:.14em}}
  #grafcet-panel .gtt{{flex:1 1 300px;min-width:260px}}
  #grafcet-panel .geb{{font-family:var(--gmono);font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:var(--acc,#2780e3);margin:0 0 8px}}
  #grafcet-panel h3.gh{{font-size:clamp(18px,2.3vw,25px);margin:0 0 6px;font-weight:700;color:var(--fg,#212529);border:0;padding:0}}
  #grafcet-panel .gsub{{color:var(--mute,#6c757d);margin:0;font-size:14px;max-width:62ch}}
  #grafcet-panel .gdl{{display:inline-flex;align-items:center;gap:8px;margin-top:14px;padding:9px 18px;border-radius:8px;
    font-weight:600;font-size:14px;color:#fff;text-decoration:none;background:var(--acc,#2780e3)}}
  #grafcet-panel .gdl:hover{{filter:brightness(1.08)}}
  #grafcet-panel .gmetrics{{display:grid;grid-template-columns:repeat(auto-fit,minmax(82px,1fr));gap:10px;margin:22px 0}}
  #grafcet-panel .gmetric{{background:var(--bg,#fff);border:1px solid var(--line,#dee2e6);border-radius:10px;padding:12px 8px;text-align:center}}
  #grafcet-panel .gmv{{font:600 20px var(--gmono);color:var(--fg,#212529)}}
  #grafcet-panel .gmk{{font-family:var(--gmono);font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--mute,#6c757d);margin-top:3px}}
  #grafcet-panel .gchips{{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;margin-bottom:22px}}
  #grafcet-panel .gchip{{background:var(--bg,#fff);border:1px solid var(--line,#dee2e6);border-left-width:4px;border-radius:10px;padding:12px 14px}}
  #grafcet-panel .g-ok{{border-left-color:var(--gok)}} #grafcet-panel .g-wip{{border-left-color:var(--gwip)}} #grafcet-panel .g-bad{{border-left-color:var(--gbad)}}
  #grafcet-panel .gch{{display:flex;align-items:center;gap:8px;margin-bottom:6px}}
  #grafcet-panel .gcode{{font-family:var(--gmono);font-weight:700;font-size:12px;color:var(--fg,#212529)}}
  #grafcet-panel .gn{{font-family:var(--gmono);font-size:11px;color:var(--mute,#6c757d)}}
  #grafcet-panel .gbadge{{margin-left:auto;font-family:var(--gmono);font-size:9px;letter-spacing:.06em;padding:2px 7px;border-radius:20px;color:#fff}}
  #grafcet-panel .g-ok .gbadge{{background:var(--gok)}}
  #grafcet-panel .g-wip .gbadge{{background:var(--gwip)}}
  #grafcet-panel .g-bad .gbadge{{background:var(--gbad)}}
  #grafcet-panel .glabel{{font-size:13px;color:var(--fg,#212529);font-weight:500}}
  #grafcet-panel .gdet{{font-family:var(--gmono);font-size:10px;color:var(--mute,#6c757d);margin-top:3px}}
  #grafcet-panel .gcard{{background:var(--bg,#fff);border:1px solid var(--line,#dee2e6);border-radius:12px;padding:18px;overflow:auto}}
  #grafcet-panel .gcard svg{{max-width:100%;height:auto;display:block;margin:0 auto}}
</style>
<div class="ghead">
  {ring}
  <div class="gtt">
    <p class="geb">TI Calypso &middot; mode {st.get('mode','?')} &middot; {ts}</p>
    <h3 class="gh">GRAFCET go-live &mdash; romload &rarr; synchro L1 &rarr; camp &rarr; chiffrement</h3>
    <p class="gsub">Chaque maillon d&eacute;riv&eacute; des journaux du run {run or 'live'} (m&ecirc;me run que le verdict et la couverture). Progression du chemin&nbsp;: {path}%.</p>
    {pdf_btn}
  </div>
</div>
<div class="gmetrics">{mcells}</div>
<div class="gchips">{chips_html}</div>
<div class="gcard">{graf_svg or '<p style="color:var(--mute,#6c757d)">grafcet.svg absent</p>'}</div>
</section>"""


def fragment_md(summary: dict, st: dict, ts: str = "", run: str = "") -> str:
    """Version MARKDOWN du bandeau + panneau GRAFCET (mêmes données, même run
    que les fragments HTML), placée en tête du dossier.qmd pour le PDF pandoc."""
    s = summary or {}
    out = ["## Résumé des tests", ""]
    if s.get("error") or not s.get("total"):
        out += ["_Résumé des tests indisponible._", ""]
    else:
        p, f = s.get("passed", 0), s.get("failed", 0) + s.get("errors", 0)
        sk, tot = s.get("skipped", 0), s.get("total", 0)
        ex = p + f
        out += [f"**{p} réussis / {ex} exécutés** — {f} échec(s) · {sk} sauté(s) · "
                f"{tot} collectés — run `{run or s.get('source') or 'live'}` — généré {ts}", ""]
        if sk:
            out += [f"> Couverture partielle : {sk} test(s) non exécuté(s) (sautés). "
                    f"Le taux porte sur les {ex} exécutés, pas sur la couverture totale.", ""]
        out += ["| Batterie | Réussis / exécutés | Sautés |", "|---|---|---|"]
        for nom, b in s.get("batteries", {}).items():
            ne = b.get("passed", 0) + b.get("failed", 0) + b.get("errors", 0)
            out.append(f"| {nom} | {b.get('passed', 0)} / {ne} | {b.get('skipped', 0) or ''} |")
        out.append("")
    tot_pct, path, _ = _weighted_pct(st)
    badge = {"ok": "VALIDE", "wip": "EN COURS", "bad": "MANQUANT"}
    out += ["## GRAFCET go-live", "",
            f"Chemin pondéré **{path} %** — journaux du run `{run or 'live'}` "
            f"(même run que le verdict et la couverture).", "",
            "| Étape | Maillon | Journal / sonde | État |", "|---|---|---|---|"]
    for code, key, label, w, detail in _CHAIN:
        out.append(f"| {code} | {label} | `{detail}` | {badge[st.get(key, 'bad')]} |")
    out += ["", "![GRAFCET go-live — chaîne ordonnée, couleur = état du maillon](grafcet.png){height=21cm}", ""]
    return "\n".join(out)


def pdf_from_qmd(qmd_path, frag_dir, out_pdf) -> Path:
    """PDF du dossier rendu par PANDOC (xelatex) à partir du MÊME dossier.qmd
    que la page HTML, avec fragment.md (bandeau + GRAFCET) en tête : page et
    PDF disent la même chose, sur le même run."""
    import subprocess
    qmd = Path(qmd_path).read_text(encoding="utf-8", errors="replace")
    meta = {}
    fm = re.match(r"^---\n(.*?)\n---\n", qmd, flags=re.S)
    if fm:
        for k in ("title", "subtitle", "date"):
            m = re.search(r'^%s:\s*"?(.*?)"?\s*$' % k, fm.group(1), flags=re.M)
            if m:
                meta[k] = m.group(1)
        qmd = qmd[fm.end():]
    frag = Path(frag_dir) / "fragment.md"
    head = frag.read_text(encoding="utf-8") if frag.is_file() else ""
    esc = lambda v: (v or "").replace('"', "'")
    front = f"""---
title: "{esc(meta.get('title', 'Dossier de run'))}"
subtitle: "{esc(meta.get('subtitle', ''))}"
date: "{esc(meta.get('date', ''))}"
lang: fr
documentclass: article
fontsize: 10pt
geometry: margin=1.5cm
mainfont: DejaVu Sans
monofont: DejaVu Sans Mono
colorlinks: true
linkcolor: blue
toc: true
toc-depth: 2
numbersections: true
header-includes:
  - \\usepackage{{fvextra}}
  - \\fvset{{breaklines=true,breakanywhere=true,fontsize=\\scriptsize}}
  - \\RecustomVerbatimEnvironment{{verbatim}}{{Verbatim}}{{breaklines,breakanywhere,fontsize=\\scriptsize}}
---

"""
    md = Path(frag_dir) / "dossier-pdf.md"
    md.write_text(front + head + "\n\n" + qmd, encoding="utf-8")
    out_pdf = Path(out_pdf)
    r = subprocess.run(
        ["pandoc", str(md), "-o", str(out_pdf), "--pdf-engine=xelatex",
         "--no-highlight", "--shift-heading-level-by=-1",
         "--resource-path", str(frag_dir)],
        capture_output=True, text=True, timeout=600)
    if r.returncode != 0 or not out_pdf.is_file():
        raise RuntimeError("pandoc : " + (r.stderr or r.stdout)[-800:])
    return out_pdf


def write_fragments(out_dir, ts: str = "", pdf_href: str = "rapport.pdf", run_dir=None) -> Path:
    """Prepare tout pour la page du sous-domaine : out_dir/fragment.html
    (bandeau + panneau grafcet, injectes dans l'HTML) et out_dir/fragment.md
    (meme contenu en markdown, place en tete du qmd pour le PDF pandoc), plus
    grafcet.svg (HTML) et grafcet.png (PDF). Si run_dir : TOUT provient du MEME
    run archive que le dossier (plus de melange de runs) ; sinon live."""
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    run = _use_run_logs(run_dir)          # pointe les journaux sur le run (si fourni)
    st = derive_status()
    _mermaid_svg(_mermaid(st), str(out / "grafcet.svg"))   # HTML : vectoriel inline
    _mermaid_png(_mermaid(st), str(out / "grafcet.png"), scale=3)   # PDF : image LaTeX nette
    # resume des tests : depuis le run archive (coherent) ou live
    summary = tests_summary(run_dir=run_dir)
    frag = tests_summary_fragment(summary, ts, run) + "\n" + grafcet_fragment(out_dir, ts, pdf_href, run)
    (out / "fragment.md").write_text(fragment_md(summary, st, ts, run), encoding="utf-8")
    p = out / "fragment.html"
    p.write_text(frag, encoding="utf-8")
    return p


def write_deploy(out_dir, ts: str = "", pdf_href: str = "rapport.pdf") -> Path:
    """Page de deploiement AUTONOME et soignee (index.html) : anneau de
    progression, chips par maillon derive des VRAIS logs, SVG grafcet/sequence/
    timeline inline, plots temporels en data-URI, bouton PDF telechargeable.
    Les SVG/PNG doivent deja exister dans out_dir (npx mmdc + matplotlib)."""
    out = Path(out_dir)
    st = derive_status()
    tot, path, rows = _weighted_pct(st)

    def svg_inline(name):
        p = out / name
        if not p.is_file():
            return ""
        s = p.read_text(encoding="utf-8", errors="replace")
        s = re.sub(r"<\?xml.*?\?>", "", s, flags=re.S)
        s = re.sub(r"<!DOCTYPE.*?>", "", s, flags=re.S)
        return s

    _CNT = {"fb": "fb_n", "sb": "sb_n", "si": "si_n", "camp": "camp_n",
            "rach": "rach_n", "sdcch": "sdcch_n", "auth": "auth_n",
            "cipher": "ciph_n", "tmsi": "tmsi_n"}
    chips = []
    for code, key, label, w, detail in _CHAIN:
        stt = st.get(key, "bad")
        n = st.get(_CNT.get(key, ""), "")
        badge = {"ok": "VALIDE", "wip": "EN COURS", "bad": "MANQUANT"}[stt]
        cnt = f'<span class="chip-n">&times;{n}</span>' if (n not in ("", 0, None)) else ""
        chips.append(
            f'<div class="chip chip-{stt}"><div class="chip-h"><span class="chip-code">{code}</span>{cnt}'
            f'<span class="chip-badge">{badge}</span></div>'
            f'<div class="chip-l">{label}</div><div class="chip-d">{detail}</div></div>')
    chips_html = "\n".join(chips)

    # anneau SVG (progression ponderee du chemin)
    R, circ = 52, 2 * 3.14159 * 52
    dash = circ * path / 100.0
    ring = (f'<svg viewBox="0 0 120 120" class="ring"><circle cx="60" cy="60" r="{R}" '
            f'class="ring-bg"/><circle cx="60" cy="60" r="{R}" class="ring-fg" '
            f'stroke-dasharray="{dash:.1f} {circ:.1f}" transform="rotate(-90 60 60)"/>'
            f'<text x="60" y="56" class="ring-pct">{path}%</text>'
            f'<text x="60" y="76" class="ring-sub">chemin</text></svg>')

    metrics = [("FB", st.get("fb_n")), ("SB", st.get("sb_n")), ("SI", st.get("si_n")),
               ("camp", st.get("camp_n")), ("RACH", st.get("rach_n")),
               ("SDCCH", st.get("sdcch_n")), ("auth", st.get("auth_n")),
               ("chiffre", st.get("ciph_n")), ("TMSI", st.get("tmsi_n")),
               ("LU", f"{st.get('lu_ok')}/{st.get('lu_ko')}")]
    mcells = "".join(f'<div class="metric"><div class="m-v">{v}</div><div class="m-k">{k}</div></div>'
                     for k, v in metrics)

    plots = []
    for fn, title in (("t_trame.png", "Budget trame DSP (ms) vs FN"),
                      ("t_pire.png", "Pire trame DSP (ms) vs FN"),
                      ("t_fbdet.png", "d_fb_det vs FN"),
                      ("t_rint.png", "rint (frame-IRQ) vs FN")):
        uri = _b64_img(out / fn)
        if uri:
            plots.append(f'<figure class="plot"><img src="{uri}" alt="{title}"/><figcaption>{title}</figcaption></figure>')
    plots_html = "\n".join(plots) or '<p class="muted">Pas de donnees temporelles dans dsp.log.</p>'

    seq_svg = svg_inline("sequence.svg")
    tl_svg = svg_inline("timeline.svg")
    graf_svg = svg_inline("grafcet.svg")
    uml_uri = _b64_img(out / "pipeline_uml.png")

    html = f"""<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Calypso GSM — GRAFCET go-live</title>
<style>
  :root{{--bg:#0a1014;--bg2:#0d161b;--panel:#101c22;--line:#1e333b;--ink:#dde8ea;
    --muted:#8aa0a5;--faint:#5f767b;--cyan:#38d3c2;--ok:#46c39a;--wip:#e6a94e;--bad:#e86a5f;--src:#6ea8d8;
    --mono:ui-monospace,"JetBrains Mono","SF Mono",Menlo,Consolas,monospace;
    --sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;}}
  *{{box-sizing:border-box}}
  html{{scroll-behavior:smooth}}
  body{{margin:0;background:radial-gradient(1200px 600px at 70% -10%,#12343a 0%,transparent 60%),var(--bg);
    color:var(--ink);font-family:var(--sans);line-height:1.55;-webkit-font-smoothing:antialiased}}
  .wrap{{max-width:1180px;margin:0 auto;padding:40px 24px 120px}}
  header.hero{{display:flex;gap:28px;align-items:center;flex-wrap:wrap;
    border:1px solid var(--line);border-radius:20px;padding:30px 32px;
    background:linear-gradient(135deg,rgba(56,211,194,.06),rgba(110,168,216,.04));box-shadow:0 20px 60px -30px #000}}
  .hero .ring{{width:132px;height:132px;flex:0 0 auto}}
  .ring-bg{{fill:none;stroke:#1e333b;stroke-width:11}}
  .ring-fg{{fill:none;stroke:url(#g);stroke-width:11;stroke-linecap:round;transition:stroke-dasharray 1s ease}}
  .ring-pct{{fill:#eef6f6;font:600 26px var(--mono);text-anchor:middle}}
  .ring-sub{{fill:var(--muted);font:500 11px var(--mono);text-anchor:middle;letter-spacing:.15em}}
  .hero-txt{{flex:1 1 320px;min-width:280px}}
  .eyebrow{{font-family:var(--mono);font-size:12px;letter-spacing:.22em;text-transform:uppercase;color:var(--cyan);margin:0 0 12px}}
  h1{{font-size:clamp(26px,3.6vw,40px);margin:0 0 10px;font-weight:700;letter-spacing:-.02em;color:#f3fafa}}
  .sub{{color:var(--muted);margin:0;max-width:60ch}}
  .tag{{display:inline-block;font-family:var(--mono);font-size:11px;padding:3px 10px;border-radius:30px;
    border:1px solid var(--line);color:var(--cyan);margin:12px 8px 0 0;background:#0c181d}}
  .dl{{display:inline-flex;align-items:center;gap:10px;margin-top:18px;padding:12px 22px;border-radius:12px;
    font-weight:600;font-size:15px;color:#042018;text-decoration:none;
    background:linear-gradient(135deg,#46c39a,#38d3c2);box-shadow:0 12px 30px -12px #38d3c2}}
  .dl:hover{{filter:brightness(1.08)}}
  .metrics{{display:grid;grid-template-columns:repeat(auto-fit,minmax(92px,1fr));gap:12px;margin:28px 0}}
  .metric{{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 10px;text-align:center}}
  .m-v{{font:600 22px var(--mono);color:#eef6f6}}
  .m-k{{font-family:var(--mono);font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--faint);margin-top:4px}}
  h2{{font-family:var(--mono);font-size:13px;letter-spacing:.18em;text-transform:uppercase;color:var(--cyan);
    margin:48px 0 18px;display:flex;align-items:center;gap:12px}}
  h2::after{{content:"";flex:1;height:1px;background:var(--line)}}
  .chips{{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:14px}}
  .chip{{background:var(--panel);border:1px solid var(--line);border-left-width:4px;border-radius:12px;padding:14px 16px;transition:transform .15s}}
  .chip:hover{{transform:translateY(-3px)}}
  .chip-ok{{border-left-color:var(--ok)}} .chip-wip{{border-left-color:var(--wip)}} .chip-bad{{border-left-color:var(--bad)}}
  .chip-h{{display:flex;align-items:center;gap:8px;margin-bottom:8px}}
  .chip-code{{font-family:var(--mono);font-weight:700;font-size:13px;color:#eef6f6}}
  .chip-n{{font-family:var(--mono);font-size:12px;color:var(--muted)}}
  .chip-badge{{margin-left:auto;font-family:var(--mono);font-size:10px;letter-spacing:.08em;padding:2px 8px;border-radius:20px}}
  .chip-ok .chip-badge{{color:var(--ok);background:rgba(70,195,154,.14)}}
  .chip-wip .chip-badge{{color:var(--wip);background:rgba(230,169,78,.14)}}
  .chip-bad .chip-badge{{color:var(--bad);background:rgba(232,106,95,.14)}}
  .chip-l{{font-size:14px;color:var(--ink);font-weight:500}}
  .chip-d{{font-family:var(--mono);font-size:11px;color:var(--faint);margin-top:4px}}
  .card{{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:22px;margin-top:16px;overflow:auto}}
  .card svg{{max-width:100%;height:auto;display:block;margin:0 auto}}
  .grid2{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}
  @media(max-width:820px){{.grid2{{grid-template-columns:1fr}}}}
  .plots{{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}}
  .plot{{margin:0;background:#fff;border:1px solid var(--line);border-radius:12px;padding:8px}}
  .plot img{{width:100%;display:block;border-radius:6px}}
  .plot figcaption{{font-family:var(--mono);font-size:11px;color:#33484d;text-align:center;padding:8px 4px 4px}}
  .muted{{color:var(--muted)}}
  footer{{margin-top:60px;padding-top:24px;border-top:1px solid var(--line);
    font-family:var(--mono);font-size:12px;color:var(--faint);display:flex;gap:20px;flex-wrap:wrap}}
  .dlbar{{position:fixed;right:22px;bottom:22px;z-index:9}}
  .dlbar a{{box-shadow:0 16px 40px -14px #000}}
</style></head>
<body>
<svg width="0" height="0"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#46c39a"/><stop offset="1" stop-color="#38d3c2"/></linearGradient></defs></svg>
<div class="wrap">
  <header class="hero">
    {ring}
    <div class="hero-txt">
      <p class="eyebrow">TI Calypso &middot; QEMU &middot; baseband GSM &middot; mode {st.get('mode','?')}</p>
      <h1>GRAFCET go-live&nbsp;: romload &rarr; synchro L1 &rarr; camp &rarr; chiffrement</h1>
      <p class="sub">Chaque maillon est d&eacute;riv&eacute; des <b>vrais journaux</b> du dernier run (dsp/qemu/osmocon/mobile.log, r&eacute;solus par <code>banc.py</code>). Diagrammes rendus via npx&nbsp;mermaid-cli.</p>
      <div>
        <span class="tag">{ts}</span>
        <span class="tag">chemin pond&eacute;r&eacute; {path}%</span>
        <span class="tag">total {tot}%</span>
      </div>
      <a class="dl" href="{pdf_href}" download>&#11015; T&eacute;l&eacute;charger le rapport PDF</a>
    </div>
  </header>

  <div class="metrics">{mcells}</div>

  <h2>Cha&icirc;ne de maillons</h2>
  <div class="chips">{chips_html}</div>

  <h2>GRAFCET interpr&eacute;t&eacute;</h2>
  <div class="card">{graf_svg or '<p class=muted>SVG grafcet absent.</p>'}</div>

  <h2>S&eacute;quence &amp; timeline</h2>
  <div class="grid2">
    <div class="card">{seq_svg or '<p class=muted>sequence.svg absent</p>'}</div>
    <div class="card">{tl_svg or '<p class=muted>timeline.svg absent</p>'}</div>
  </div>

  <h2>Diagrammes temporels (dsp.log)</h2>
  <div class="plots">{plots_html}</div>

  {('<h2>Pipeline (UML)</h2><div class="card" style="background:#fff"><img style="width:100%" src="'+uml_uri+'"></div>') if uml_uri else ''}

  <footer>
    <span>Auto-g&eacute;n&eacute;r&eacute; par grafcet_gen.py</span>
    <span>statut &larr; qemu/dsp/osmocon/mobile.log</span>
    <span>rendu npx &middot; fpdf2</span>
  </footer>
</div>
<div class="dlbar"><a class="dl" href="{pdf_href}" download>&#11015; PDF</a></div>
</body></html>"""
    p = out / "index.html"
    p.write_text(html, encoding="utf-8")
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
    import sys, time
    argv = sys.argv[1:]
    ts = time.strftime("%Y-%m-%d %H:%M")
    if argv and argv[0] == "fragments":
        # fragments <out_dir> [pdf_href] [run_dir] : bandeau + grafcet (HTML + md)
        d = argv[1] if len(argv) > 1 else "/tmp/calypso-frag"
        href = argv[2] if len(argv) > 2 else "rapport.pdf"
        run_dir = argv[3] if len(argv) > 3 and argv[3] else None
        p = write_fragments(d, ts, href, run_dir)
        print("fragment ecrit:", p)
    elif argv and argv[0] == "pdf":
        # pdf <dossier.qmd> <frag_dir> <out.pdf> : PDF pandoc du meme qmd que l'HTML
        p = pdf_from_qmd(argv[1], argv[2], argv[3])
        print("pdf ecrit:", p)
    elif argv and argv[0] == "deploy":
        d = argv[1] if len(argv) > 1 else "/tmp/calypso-deploy"
        paths = write_grafcet(d, ts)          # html/md/pdf/rmd + d_*.png (npx)
        idx = write_deploy(d, ts)             # page autonome index.html
        print("deploy ecrit:", idx)
        for p in paths:
            print("  +", p)
    else:
        d = argv[0] if argv else "/tmp"
        paths = write_grafcet(d, ts)
        print("grafcet écrit:", *[str(p) for p in paths])
