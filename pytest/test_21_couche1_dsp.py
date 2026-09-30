"""couche 1 dsp — c54x_exe (mask-ROM TI) : dsp.log de c54x_exe/run.sh, montant.c, pont_dsp.py.
Les points ouverts du README (B_BFI, SACCH en TCH, marge temps reel) sont des xfail : on les
mesure a chaque run, on ne les fait pas passer d'office."""
import re

import pytest

import banc

pytestmark = [pytest.mark.banc_couche1, pytest.mark.dsp]


def test_process_couche1():
    assert banc.alive("c54x_exe --arm"), "c54x_exe --arm absent"
    assert banc.alive("qemu-system-arm"), "qemu-system-arm absent"
    assert banc.alive("osmocon"), "osmocon absent"


def test_api_ram_partagee():
    banc.require_log("qemu")
    assert banc.count("qemu", r"pont DSP : API RAM partagee") >= 1, "QEMU n'a pas rejoint le DSP"


def test_tache_fb_postee_et_fb_detecte():
    banc.require_log("dsp")
    assert banc.count("dsp", r"tache FB postee par l'ARM") >= 1, "l'ARM n'a jamais poste la tache FB"
    assert banc.count("dsp", r"\[jalon\] fn=\d+ d_fb_det=1") >= 1, "la ROM n'a jamais leve d_fb_det"


def test_sb_plausible():
    banc.require_log("dsp")
    assert banc.count("dsp", r"tache SB postee par l'ARM") >= 1, "tache SB jamais postee"
    assert banc.count("dsp", r"SB PLAUSIBLE") >= 1, "aucun SB plausible (BSIC) decode par la ROM"


def test_rach_publie():
    banc.require_log("dsp")
    assert banc.count("dsp", r"\[montant\] RACH ra=") >= 1, "aucun RACH lu dans d_rach"


def test_canal_dedie_suivi():
    banc.require_log("dsp")
    assert banc.count("dsp", r"\[montant\] canal dedie .*SDCCH") >= 1, "le BSP n'a jamais suivi un canal dedie SDCCH"
    assert banc.count("dsp", r"\[montant\] SDCCH UL") >= 1, "aucun bloc SDCCH montant"


def test_chiffrement_a5_dans_le_dsp():
    banc.require_log("dsp")
    assert banc.count("dsp", r"\[a5-arm\]") >= 1, "l'ARM n'a jamais ecrit a_kc / d_a5mode"
    assert banc.count("dsp", r"\[montant\] chiffrement A5/") >= 1, "Kc jamais publie par montant.c"


def test_bascule_tch_suit_le_firmware():
    banc.require_log("dsp")
    if banc.count("pont", r"ASSIGNMENT COMMAND : TCH") == 0:
        pytest.skip("aucun appel dans ce run : pas de bascule TCH a verifier")
    assert banc.count("dsp", r"\[montant\] TCH : le firmware poste la tache") >= 1, "le BSP n'a pas bascule sur le TCH"


@pytest.mark.xfail(strict=False, reason="README c54x_exe : B_BFI sur toute la parole, point ouvert n°1")
def test_parole_descendante_pas_toute_bfi():
    banc.require_log("dsp")
    ln = banc.last("dsp", r"\[a_dd\]")
    if not ln:
        pytest.skip("pas de sonde [a_dd] : aucun TCH dans ce run")
    m = re.search(r"vues=(\d+) ko=(\d+) bfi=(\d+)", ln)
    assert m, ln
    vues, ko, bfi = map(int, m.groups())
    assert bfi < vues, f"toutes les trames TCH/F marquees BFI ({bfi}/{vues})"


@pytest.mark.xfail(strict=False, reason="README c54x_exe : 4.3-4.6 ms de travail DSP pour 4.62 ms")
def test_marge_temps_reel():
    banc.require_log("dsp")
    ln = banc.last("dsp", r"\[chrono\]")
    if not ln:
        pytest.skip("pas de [chrono]")
    vals = [float(x) for x in re.findall(r"(?:A|go|B|apres DONE) ([0-9.]+)", ln)]
    assert vals and sum(vals) < 4.62, f"budget DSP depasse : {sum(vals):.2f} ms >= 4.62 ms ({ln.strip()})"


def test_garde_mvkd_muette():
    banc.require_log("qemu")
    assert banc.count("qemu", r"\[garde-3d89\]") == 0, "la garde MVKD/MVDK a joue (README : SACCH en TCH, point ouvert n°2)"


def test_pas_de_los_en_dedie():
    banc.require_log("mobile")
    assert banc.count("mobile", r"LOS during dedicated|Radio link lost signal") == 0, "perte radio en mode dedie (SACCH/TF)"
