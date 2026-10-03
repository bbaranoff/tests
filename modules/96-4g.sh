#!/bin/bash
# --4g : la 4G du banc (Open5GS + srsENB + srsUE sur ZeroMQ) : demons, S1, attache de l'UE, plan de donnees (ping dans le netns), SGs vers le MSC
MOD_CHAINE=0; MOD_OPTIONNEL=1
# --restart relance eNB et UE (osmo-lte start attend l'attache, 30 s) : plus que
# les 240 s d'un barreau ordinaire si le coeur doit aussi monter.
MOD_TIMEOUT="${LTE_TIMEOUT:-420}"
mod_titre() { echo "4G : coeur Open5GS, eNB, UE, donnees, SGs"; }
# Ce barreau ne CONSTATE que ce que la pile 4G dit d'elle-meme : processus,
# association S1 (SCTP 36412), tun_srsue dans le netns de l'UE, ping vers la
# passerelle ogstun, association SGs (SCTP 29118) vers OsmoMSC. Avec --restart
# il (re)lance la pile par « osmo-lte start » (osmo-epc, eNB, UE, dans l'ordre
# et dans les temps : voir tools/osmo-lte.sh). Sans --4g il ne joue pas : la
# 4G n'est pas dans l'echelle GSM, et ZeroMQ occupe des ports a part.
mod_run() {
    if [ "${LTE:-0}" != 1 ]; then verdict 4g SAUTE "sans --4g"; return; fi
    local lte=/usr/local/bin/osmo-lte epc=/usr/local/bin/osmo-epc ko="" d ns="${OSMO_LTE_NETNS:-ue1}" ip gw
    [ -x "$lte" ] || lte="$REPO/tools/osmo-lte.sh"
    [ -x "$epc" ] || epc="$REPO/tools/osmo-epc.sh"
    [ -x "$lte" ] || { verdict 4g ECHEC "osmo-lte absent (tools/osmo-lte-install.sh)"; return; }
    if [ "$RESTART" = 1 ]; then
        say "osmo-lte restart (osmo-epc, srsenb, srsue)"
        "$lte" restart > "$OUT/4g-start.log" 2>&1 || ko="$ko demarrage(voir 4g-start.log)"
    fi
    "$epc" status > "$OUT/4g-epc-status.txt" 2>&1
    "$lte" status > "$OUT/4g-lte-status.txt" 2>&1
    sed -i 's/\x1b\[[0-9;]*m//g' "$OUT/4g-epc-status.txt" "$OUT/4g-lte-status.txt"
    # 1. les processus : le coeur Open5GS, l'eNB, l'UE
    local arret=""
    for d in open5gs-mmed open5gs-sgwcd open5gs-sgwud open5gs-smfd open5gs-upfd open5gs-hssd open5gs-pcrfd srsenb srsue; do
        pgrep -x "$d" >/dev/null 2>&1 || arret="$arret $d"
    done
    pgrep -x mongod >/dev/null 2>&1 || arret="$arret mongod"
    [ -z "$arret" ] || ko="$ko processus(arretes:$arret)"
    # 2. S1 : l'eNB associe au MME
    ss -San 2>/dev/null | grep -q 'ESTAB.*:36412' || ko="$ko s1(pas d'association eNB-MME)"
    # 3. la radio ZeroMQ : un eNB dont la radio est morte (fail_on_disconnect) garde son S1
    grep -q 'radio de l eNB est morte' "$OUT/4g-lte-status.txt" && ko="$ko zmq(radio eNB morte)"
    grep -q 'aucun lien eNB' "$OUT/4g-lte-status.txt" && ko="$ko zmq(aucun lien eNB-UE)"
    # 4. l'attache : l'UE a une adresse sur tun_srsue dans son netns
    ip="$(ip -n "$ns" -4 -o addr show 2>/dev/null | awk '/tun_srsue/ {print $4}' | cut -d/ -f1)"
    [ -n "$ip" ] || ko="$ko attache(pas de tun_srsue dans $ns)"
    # 5. le plan de donnees : ping de la passerelle ogstun depuis le netns de l'UE
    gw="$(ip -4 -o addr show ogstun 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sed -n 1p)"
    if [ -n "$ip" ] && [ -n "$gw" ]; then
        ip netns exec "$ns" ping -c 4 -W 2 "$gw" > "$OUT/4g-ping.txt" 2>&1 \
            || ko="$ko donnees(ping $gw sans reponse)"
        grep -q ' 0% packet loss' "$OUT/4g-ping.txt" || { grep -q 'packet loss' "$OUT/4g-ping.txt" && ko="$ko donnees(pertes: $(grep -o '[0-9]*% packet loss' "$OUT/4g-ping.txt"))"; }
    elif [ -n "$ip" ]; then ko="$ko donnees(pas d'interface ogstun)"; fi
    # 6. SGs : l'association SCTP vers OsmoMSC (CSFB : voix et SMS depuis la 4G)
    ss -np 2>/dev/null | grep -q 29118 || ko="$ko sgs(pas d'association vers OsmoMSC)"
    local res="UE ${ip:-sans adresse}${gw:+, passerelle $gw}"
    [ -z "$ko" ] && verdict 4g OK "$res, S1 et SGs etablis" || verdict 4g ECHEC "$(printf '%s' "$ko" | sed 's/^ //' | cut -c1-150) (4g-lte-status.txt, 4g-epc-status.txt)"
}
