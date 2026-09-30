"""reseau — ce que le coeur dit de l'abonne : VLR, HLR, compteurs, SS7. Commun, lecture seule."""
import re
import subprocess

import pytest

import banc

pytestmark = [pytest.mark.banc_reseau, pytest.mark.commun]


def test_abonne_au_vlr():
    im = banc.imsi()
    out = banc.vty(banc.MSC_VTY, f"show subscriber imsi {im}")
    assert f"IMSI: {im}" in out, "l'abonne du mobile n'est pas au VLR"
    assert "Conf. by radio contact:         true" in out


def test_abonne_a_un_msisdn():
    assert re.fullmatch(r"\d{5,6}", banc.msisdn(banc.imsi()) or ""), "pas de MSISDN pour l'abonne (HLR provisionne sans numero ?)"


def test_hlr_connait_l_abonne_avec_cle():
    im = banc.imsi()
    r = subprocess.run(["sqlite3", "-separator", "|", "/var/lib/osmocom/hlr.db",
                        "select s.imsi, coalesce(s.msisdn,''), case when a.subscriber_id is null then 'non' else 'oui' end "
                        "from subscriber s left join auc_2g a on a.subscriber_id=s.id where s.imsi='%s'" % im],
                       capture_output=True, text=True)
    if r.returncode != 0:
        pytest.skip("sqlite3 ou hlr.db indisponible")
    assert r.stdout.strip(), "abonne absent du HLR"
    assert r.stdout.strip().endswith("|oui"), "abonne sans cle auc_2g : ne peut pas s'authentifier"


def test_lu_completees_sans_echec():
    st = banc.msc_stats()
    lu = st.get("Location Updating Results")
    assert lu, f"show statistics illisible : {list(st)[:5]}"
    assert lu[0] >= 1 and lu[1] == 0, f"LU completed={lu[0]} failed={lu[1]}"


def test_stp_asp_msc_et_bsc_actifs():
    out = banc.vty(banc.STP_VTY, "show cs7 instance 0 asp")
    actifs = [ln for ln in out.splitlines() if re.search(r"ASP[_-]ACTIVE", ln)]
    assert len(actifs) >= 2, f"moins de 2 ASP actifs sur le STP local :\n{out[-600:]}"


def test_sccp_utilisateurs_msc_bsc():
    out = banc.vty(banc.STP_VTY, "show cs7 instance 0 sccp users")
    assert "Unknown command" not in out
    assert len(re.findall(r"SSN\s+\d+", out)) >= 2 or "SCCP" in out, out[-400:]
