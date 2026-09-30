"""infra — les demons du coeur, la BTS, les services, l'audio. Commun aux deux modes."""
import subprocess

import pytest

import banc

pytestmark = [pytest.mark.banc_infra, pytest.mark.commun]


@pytest.mark.parametrize("proc,port", [("osmo-hlr", banc.HLR_VTY), ("osmo-stp", banc.STP_VTY), ("osmo-msc", banc.MSC_VTY),
                                       ("osmo-bsc", banc.BSC_VTY), ("osmo-mgw", banc.MGW_VTY)])
def test_coeur_process_et_vty(proc, port):
    assert banc.alive(proc), f"{proc} absent"
    assert banc.port_open(port), f"{proc} : VTY {port} muette"


def test_bts_trx_vty():
    assert banc.alive("osmo-bts-"), "aucun osmo-bts-*"
    assert banc.port_open(banc.BTS_VTY), "BTS : VTY 4241 muette"


def test_bts_trx_operationnel():
    out = banc.vty(banc.BSC_VTY, "show bts 0")
    assert "BTS 0" in out, "le BSC ne decrit pas le BTS 0"
    assert "Unknown command" not in out


def test_asterisk_sip_5060():
    assert banc.alive("asterisk"), "asterisk absent"
    r = subprocess.run(["ss", "-ulnp"], capture_output=True, text=True)
    assert ":5060 " in r.stdout, "pas d'ecoute SIP sur 5060/udp"


def test_sip_connector_et_mncc():
    assert banc.alive("osmo-sip-connector"), "osmo-sip-connector absent : pas de voix"
    import os
    assert os.path.exists("/tmp/msc_mncc"), "socket MNCC /tmp/msc_mncc absent"


def test_proto_smsc_socket():
    import os, stat
    assert os.path.exists("/tmp/sendmt_socket") and stat.S_ISSOCK(os.stat("/tmp/sendmt_socket").st_mode), "/tmp/sendmt_socket absent"


def test_pulse_sinks_gsm():
    r = subprocess.run(["pactl", "list", "short", "sinks"], capture_output=True, text=True)
    if r.returncode != 0:
        pytest.skip("PulseAudio injoignable")
    assert "gsm_audio" in r.stdout and "gsm_mic" in r.stdout, "sinks gsm_audio / gsm_mic absents (scripts/audio-chain.sh)"
