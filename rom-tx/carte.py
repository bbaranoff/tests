#!/usr/bin/env python3
"""carte.py : carte entree -> sortie du codage montant de la ROM (tampon data[0x4280]).
Entrees : inj_<n>.txt (sortie ROM pour le bloc n de blocs-injectes.txt : bloc nul, 184 vecteurs
a un bit, bloc nul). Pour chaque bit de sortie, on cherche les bits du codeur standard
(gsm0503_xcch_encode, ./enc) dont la signature sur les 184 vecteurs est identique."""
import os, subprocess, collections, sys
ICI = os.path.dirname(os.path.abspath(__file__))
def enc(hexs):
    return [int(c) for c in subprocess.check_output([os.path.join(ICI, 'enc')] + hexs.split()).decode().strip()[:456]]
blocs = [l.split() for l in open(os.path.join(ICI, 'blocs-injectes.txt')) if l.strip()]
def rom(n):
    d = {}
    for l in open(os.path.join(ICI, f'inj_{n}.txt')):
        if not l.startswith('#'):
            a, w = l.split(); d[int(a, 16)] = int(w, 16)
    return [int(c) for a in range(0x4280, 0x42a0) for c in format(d[a], '016b')]
Z = rom(0); ez = enc(' '.join(blocs[0]))
R = {k: [x ^ y for x, y in zip(rom(k), Z)] for k in range(1, 185)}
E = {k: [x ^ y for x, y in zip(enc(' '.join(blocs[k])), ez)] for k in range(1, 185)}
sig = lambda M, i: tuple(M[k][i] for k in range(1, 185))
byE = collections.defaultdict(list)
for i in range(456): byE[sig(E, i)].append(i)
zero = tuple([0]*184)
carte = {}; sans = []
for p in range(512):
    s = sig(R, p)
    if s == zero: continue
    if s in byE and len(byE[s]) == 1: carte[p] = byE[s][0]
    else: sans.append(p)
if __name__ == '__main__':
    print(len(carte), 'positions avec correspondance unique ;', len(sans), 'non constantes sans equivalent exact')
    for g in range(4):
        print(f'g{g}:', ' '.join(f'{p%128}>{carte[p]}' for p in sorted(carte) if p//128 == g)[:400])
    print('sans equivalent (g,q):', [(p//128, p%128) for p in sans])
