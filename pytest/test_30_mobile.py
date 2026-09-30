"""mobile — osmocon, le mobile osmocom-bb, le camp, la LU, le chiffrement. Commun."""
import re

import pytest

import banc

pytestmark = [pytest.mark.banc_mobile, pytest.mark.commun]


def test_osmocon_romload_fini():
    banc.require_log("osmocon")
    assert banc.count("osmocon", r"your code is running now") >= 1, "osmocon : romload jamais termine"


def test_mobile_vty_repond():
    assert banc.alive("mobile"), "process mobile absent"
    assert banc.port_open(banc.MOB_VTY), f"VTY mobile {banc.MOB_VTY} muette"
    assert "MS '1' is" in banc.show_ms()


def test_imsi_du_mobile_est_celle_de_sa_conf():
    im = banc.imsi()
    assert len(im) == 15, f"IMSI illisible dans {banc.MOB_CFG}"
    out = banc.vty(banc.MOB_VTY, "show subscriber 1")
    assert im in out, f"la VTY ne presente pas l'IMSI {im}"


def test_campe_c3():
    ms = banc.show_ms()
    assert "C3 camped normally" in ms, re.search(r"cell selection state: .*", ms).group(0) if "cell selection" in ms else ms[-300:]
    assert re.search(r"ARFCN=\S+ CGI=\S+", ms)


def test_sysinfo_bcch_decodes():
    banc.require_log("mobile")
    for si in ("1", "2", "4"):
        assert banc.count("mobile", rf"New SYSTEM INFORMATION {si}\b") >= 1, f"SI{si} jamais decode"


def test_location_updating_accept():
    banc.require_log("mobile")
    assert banc.count("mobile", r"LOCATION UPDATING ACCEPT") >= 1
    assert banc.count("mobile", r"LOCATION UPDATING REJECT") == 0


def test_mm_normal_service():
    assert "normal service" in banc.show_ms(), "MM pas en service normal"


def test_authentification_et_chiffrement():
    banc.require_log("mobile")
    assert banc.count("mobile", r"AUTHENTICATION REQUEST") >= 1, "pas d'authentification"
    assert banc.count("mobile", r"CIPHERING MODE COMPLETE") >= 1, "chiffrement jamais complete"


def test_tmsi_attribue():
    banc.require_log("mobile")
    assert banc.count("mobile", r"got TMSI") >= 1


def test_mobile_sans_crash_ni_vty_bind():
    banc.require_log("mobile")
    assert banc.count("mobile", r"Segmentation fault|Aborted|core dumped") == 0
    assert banc.count("mobile", r"Address already in use|Cannot bind telnet|Cannot init VTY") == 0
