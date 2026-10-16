#!/bin/bash
# voix : appel vers l'echo 600, ton 1 kHz injecte dans le micro du mobile (gsm_mic), sortie captee (gsm_audio.monitor), FFT
MOD_CHAINE=1
mod_titre() { echo "injection d'un ton 1 kHz, retour par l'echo $DEST, analyse FFT"; }
# LE CHEMIN PROUVE : gsm_mic -> (gsm_in) mobile gapk FR -> TCH montant -> BTS ->
# MGW -> osmo-sip-connector -> Asterisk Echo() -> TCH descendant -> gapk ->
# (gsm_out) gsm_audio.monitor. On injecte un ton pur et on cherche SA
# frequence dans ce qui revient : un niveau seul ne suffirait pas (le bruit
# d'un vocodeur qui decode n'importe quoi a aussi un niveau), la raie a 1 kHz
# ne peut venir que de notre injection. Deux fenetres : silence (avant le ton)
# et ton, pour lire le rapport signal/bruit du trajet.
mod_run() {
    local py=/root/.env/bin/python3 ton="$OUT/voix-ton-1khz.wav" rec="$OUT/voix-retour.raw" ana="$OUT/voix-analyse.txt"
    pactl info >/dev/null 2>&1 || { verdict voix ECHEC "PulseAudio injoignable (PULSE_SERVER=${PULSE_SERVER:-?})"; return; }
    pactl list short sinks | grep -qw gsm_mic && pactl list short sources | grep -qw gsm_audio.monitor \
        || { verdict voix ECHEC "sinks gsm_mic / gsm_audio absents (scripts/audio-chain.sh)"; return; }
    $py - "$ton" <<'PY'
import sys, wave, numpy as np
sr=8000; t=np.arange(sr*4)/sr
x=(0.6*np.sin(2*np.pi*1000*t)*32767).astype('<i2')
w=wave.open(sys.argv[1],'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(x.tobytes()); w.close()
PY
    : > "$OUT/voix-appel-vty.txt"
    appeler "$DEST" "$OUT/voix-appel-vty.txt" 3
    local i cc actif=0
    for i in $(seq 1 "$CALL_MAX"); do cc="$(cc_state)"; [ "$cc" = ACTIVE ] && { actif=1; break; }; sleep 1; done
    if [ "$actif" != 1 ]; then vty "$MOB_VTY" "call 1 hangup" >/dev/null; verdict voix ECHEC "appel vers $DEST jamais ACTIVE (CC ${cc:-aucune})"; return; fi
    sleep 2                                   # le TCH s'installe, gapk ouvre ses deux sens
    # [2026-09-30] L'EXTENSION 600 JOUE 22 s D'ANNONCE (demo-echotest) AVANT Echo().
    # Mesure sur l'appel de 10:54 : descendant = voix de l'annonce pendant 22 s,
    # ton injecte a +3 s donc jamais renvoye, puis Echo() renvoie fidelement ce
    # qui monte (silence -> silence, capture -> retour 1-2 s plus tard). On attend
    # donc le silence descendant (fin d'annonce) avant la reference et le ton.
    # VOIX_ATTENTE_ANNONCE_S borne l'attente (defaut 30).
    local w silence=0 rmsv
    for w in $(seq 1 "${VOIX_ATTENTE_ANNONCE_S:-30}"); do
        timeout --foreground 2 parecord --device=gsm_audio.monitor --rate=8000 --channels=1 --format=s16le --raw "$OUT/voix-sonde.raw" 2>/dev/null
        rmsv="$($py - "$OUT/voix-sonde.raw" <<'PY2'
import sys, numpy as np
x=np.fromfile(sys.argv[1],dtype='<i2').astype(float)
print(int(np.sqrt(np.mean(x*x))) if len(x) else 0)
PY2
)"
        if [ "${rmsv:-0}" -lt 150 ]; then silence=$((silence+1)); [ "$silence" -ge 2 ] && break; else silence=0; fi
    done
    say "annonce Asterisk terminee apres ~$((w*1))s (rms descendant ${rmsv:-?}) ; injection du ton"
    rm -f "$OUT/voix-sonde.raw"
    # [2026-09-30] 30 s et non 12 : en mode dsp le montant porte le ton ~10 s
    # apres son injection (trames de parole montantes manquantes, ~20 %, le
    # codeur consomme l'audio moins vite que le temps reel et le tampon de
    # capture grossit). L'analyse cherche le ton sur toute la duree et donne la
    # latence ; un retour a 10 s est un fait a noter, pas un echec du trajet.
    local REC_S="${VOIX_REC_S:-15}"   # l'echo revient 1-2 s apres le ton une fois l'annonce passee
    # [2026-10-16] le micro est enregistre EN MEME TEMPS que le retour : la latence est l'ecart entre
    # l'arrivee du ton dans les deux enregistrements (pas de 20 ms), plus « meilleure fenetre - 3 s »
    # qui ajoutait jusqu'a 2 s (6,0 s annoncees pour 4,5 s reelles, run 12:12).
    local mic="$OUT/voix-micro.raw"
    timeout --foreground "$REC_S" parecord --device=gsm_audio.monitor --rate=8000 --channels=1 --format=s16le --raw "$rec" &
    local prec=$!
    timeout --foreground "$REC_S" parecord --device=gsm_mic.monitor --rate=8000 --channels=1 --format=s16le --raw "$mic" &
    local pmic=$!
    sleep 3                                   # 3 s de silence : la reference
    timeout --foreground 6 paplay --device=gsm_mic "$ton"  # 4 s de ton dans le micro
    wait $prec $pmic 2>/dev/null
    vty "$MOB_VTY" "call 1 hangup" >> "$OUT/voix-appel-vty.txt"; sleep 2
    local res; res="$($py - "$rec" "$mic" <<'PY'
import sys, os, numpy as np
x=np.fromfile(sys.argv[1],dtype='<i2').astype(float)
sr=8000
def arrivee(v, seuil):
    # premier bloc de 20 ms ou l'amplitude de la composante 1 kHz depasse le seuil
    n=160; w=np.exp(-2j*np.pi*1000*np.arange(n)/sr)
    for k in range(len(v)//n):
        if abs((v[k*n:(k+1)*n]*w).sum())*2/n > seuil: return k*n/sr
    return None
m=np.fromfile(sys.argv[2],dtype='<i2').astype(float) if os.path.exists(sys.argv[2]) else np.zeros(0)
if len(x)<sr*6: print(f"ECHEC enregistrement trop court ({len(x)/sr:.1f}s)"); sys.exit()
sil=x[int(0.5*sr):int(2.5*sr)]
def rms(v): return float(np.sqrt(np.mean(v*v)))+1e-9
def raie(v):
    f=np.fft.rfftfreq(len(v),1/sr); s=np.abs(np.fft.rfft(v*np.hanning(len(v))))
    k=int(np.argmax(s[1:]))+1; tot=np.sum(s[1:]**2)+1e-9
    band=(f>=950)&(f<=1050); return float(f[k]), float(np.sum(s[band]**2)/tot)
# le ton est injecte a t=3 s ; on cherche la fenetre de 2 s, apres t=3 s, ou la raie 1 kHz porte le plus d'energie
best=None
for t0 in np.arange(3.0, len(x)/sr-2.0, 0.5):
    v=x[int(t0*sr):int((t0+2.0)*sr)]; f,p=raie(v)
    if best is None or p>best[2]: best=(t0,f,p,rms(v))
t_ton,f_ton,p_ton,r_ton=best
f_sil,p_sil=raie(sil); r_sil=rms(sil)
snr=20*np.log10(r_ton/r_sil)
ok = r_ton>200 and 950<=f_ton<=1050 and p_ton>0.5
t_ret=arrivee(x, max(300.0, 4*r_sil)); t_mic=arrivee(m, 1000.0) if len(m) else None
if t_ret is not None and t_mic is not None: lat=f"latence {t_ret-t_mic:.2f}s, micro t={t_mic:.2f}s -> retour t={t_ret:.2f}s"
elif t_ret is not None: lat=f"latence ~{t_ret-3.0:.2f}s (micro non enregistre)"
else: lat=f"latence ~{t_ton-3.0:.1f}s (fenetre)"
print(f"{'OK' if ok else 'ECHEC'} retour: ton retrouve a t={t_ton:.1f}s ({lat}), rms silence={r_sil:.0f} rms ton={r_ton:.0f} (+{snr:.1f} dB) ; raie dominante {f_ton:.0f} Hz, {p_ton*100:.0f}% de l'energie dans 950-1050 Hz ; silence: raie {f_sil:.0f} Hz")
PY
)"
    printf '%s\n' "$res" > "$ana"
    case "$res" in OK*) verdict voix OK "${res#OK }" ;; *) verdict voix ECHEC "${res#ECHEC }" ;; esac
}
