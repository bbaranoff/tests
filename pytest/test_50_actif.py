"""actif — les tests qui AGISSENT sur le banc : SMS MO/MT, USSD, appel. Opt-in par
CALYPSO_ACTIF=1, parce qu'ils consomment le canal et changent les compteurs : le lanceur
banc-max.sh les joue deja barreau par barreau ; ici ils existent pour pytest seul."""
import os
import subprocess
import time

import pytest

import banc

pytestmark = [pytest.mark.banc_actif, pytest.mark.commun,
              pytest.mark.skipif(os.environ.get("CALYPSO_ACTIF") != "1", reason="CALYPSO_ACTIF=1 pour les tests qui agissent")]


def test_sms_mo_vers_100102():
    out = banc.vty(banc.MOB_VTY, "sms 1 100102 pytest MO", wait=8)
    assert "SMS to 100102 successful" in out, out[-300:]


def test_sms_mt_par_proto_smsc():
    avant = banc.SMS_TXT.read_text().count("[SMS from") if banc.SMS_TXT.exists() else 0
    mt_avant = banc.msc_stats().get("SMS MT", [0])[0]
    r = subprocess.run(["bash", "/opt/GSM/osmo-operator/scripts/send-mt-sms.sh", banc.imsi(), "pytest MT"], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr[-300:]
    for _ in range(15):
        if banc.msc_stats().get("SMS MT", [0])[0] > mt_avant:
            return
        if banc.SMS_TXT.exists() and banc.SMS_TXT.read_text().count("[SMS from") > avant:
            return
        time.sleep(1)
    pytest.fail("SMS MT ni remis (MSC) ni recu (sms.txt)")


@pytest.mark.parametrize("code,attendu", [("*#100#", "Your extension is"), ("*#101#", "Your IMSI is")])
def test_ussd(code, attendu):
    out = banc.vty(banc.MOB_VTY, f"service 1 {code}", wait=8)
    assert "Service response:" in out and attendu in out, out[-300:]


def test_appel_echo_600_active():
    banc.vty(banc.MOB_VTY, "call 1 600")
    try:
        for _ in range(25):
            if "call control state: ACTIVE" in banc.show_ms():
                return
            time.sleep(1)
        pytest.fail("l'appel vers 600 n'est jamais passe ACTIVE")
    finally:
        banc.vty(banc.MOB_VTY, "call 1 hangup")
