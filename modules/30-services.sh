#!/bin/bash
# asterisk (5060/udp), osmo-sip-connector, socket du proto-SMSC
mod_titre() { echo "asterisk, sip-connector, proto-smsc"; }
mod_run() {
    local ko=""
    vivant asterisk || ko="$ko asterisk"
    ss -ulnp 2>/dev/null | grep -q ':5060 ' || ko="$ko sip:5060"
    vivant osmo-sip-connector || ko="$ko osmo-sip-connector"
    [ -S /tmp/sendmt_socket ] || ko="$ko /tmp/sendmt_socket"
    [ -z "$ko" ] && verdict services OK "asterisk 5060, sip-connector, /tmp/sendmt_socket" || verdict services ECHEC "manque :$ko"
}
