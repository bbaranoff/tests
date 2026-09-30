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
    attendre_service 20
    vty "$MOB_VTY" "call 1 $DEST" > "$OUT/voix-appel-vty.txt"
    local i cc actif=0
    for i in $(seq 1 "$CALL_MAX"); do cc="$(cc_state)"; [ "$cc" = ACTIVE ] && { actif=1; break; }; sleep 1; done
    if [ "$actif" != 1 ]; then vty "$MOB_VTY" "call 1 hangup" >/dev/null; verdict voix ECHEC "appel vers $DEST jamais ACTIVE (CC ${cc:-aucune})"; return; fi
    sleep 2                                   # le TCH s'installe, gapk ouvre ses deux sens
    # [2026-09-30] 30 s et non 12 : en mode dsp le montant porte le ton ~10 s
    # apres son injection (trames de parole montantes manquantes, ~20 %, le
    # codeur consomme l'audio moins vite que le temps reel et le tampon de
    # capture grossit). L'analyse cherche le ton sur toute la duree et donne la
    # latence ; un retour a 10 s est un fait a noter, pas un echec du trajet.
    local REC_S="${VOIX_REC_S:-30}"
    timeout --foreground "$REC_S" parecord --device=gsm_audio.monitor --rate=8000 --channels=1 --format=s16le --raw "$rec" &
    local prec=$!
    sleep 3                                   # 3 s de silence : la reference
    timeout --foreground 6 paplay --device=gsm_mic "$ton"  # 4 s de ton dans le micro
    wait $prec 2>/dev/null
    vty "$MOB_VTY" "call 1 hangup" >> "$OUT/voix-appel-vty.txt"; sleep 2
    local res; res="$($py - "$rec" <<'PY'
import sys, numpy as np
x=np.fromfile(sys.argv[1],dtype='<i2').astype(float)
sr=8000
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
lat=t_ton-3.0
print(f"{'OK' if ok else 'ECHEC'} retour: ton retrouve a t={t_ton:.1f}s (latence {lat:.1f}s), rms silence={r_sil:.0f} rms ton={r_ton:.0f} (+{snr:.1f} dB) ; raie dominante {f_ton:.0f} Hz, {p_ton*100:.0f}% de l'energie dans 950-1050 Hz ; silence: raie {f_sil:.0f} Hz")
PY
)"
    printf '%s\n' "$res" > "$ana"
    case "$res" in OK*) verdict voix OK "${res#OK }" ;; *) verdict voix ECHEC "${res#ECHEC }" ;; esac
}
