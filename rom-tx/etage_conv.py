#!/usr/bin/env python3
"""etage_conv.py [dossier] : l'etage CONVOLUTIF intermediaire de la ROM (mots data[0x2bfa..], k = 16*mot + (15-bit))
contre le code convolutif GSM 05.03 (donnees seules, n < 184), pour chacun des 184 vecteurs injectes."""
import sys, os
ICI = os.path.dirname(os.path.abspath(__file__))
d = sys.argv[1] if len(sys.argv) > 1 else ''
def load(b):
    r = {}
    for l in open(os.path.join(ICI, d, f'inj_{b}.txt')):
        if l.startswith('#'): continue
        a, w = l.split(); r[int(a, 16)] = int(w, 16)
    return r
def expect(m):
    s = set()
    for dd in (0, 3, 4):
        if m + dd < 184: s.add(2 * (m + dd))
    for dd in (0, 1, 3, 4):
        if m + dd < 184: s.add(2 * (m + dd) + 1)
    return s
Z = load(0); bad = []
for k in range(1, 185):
    m = k - 1; V = load(k); got = set()
    for w in range(0x2bfa, 0x2bfa + 23):
        x = V[w] ^ Z[w]
        for b in range(16):
            if x >> (15 - b) & 1: got.add(16 * (w - 0x2bfa) + b)
    e = {x for x in expect(m) if x < 368}
    if got != e: bad.append((m, sorted(e - got), sorted(got - e)))
print(len(bad), '/184 vecteurs dont l etage convolutif differe du standard')
for b in bad[:8]: print('  m=%d manquants=%s en_trop=%s' % b)
