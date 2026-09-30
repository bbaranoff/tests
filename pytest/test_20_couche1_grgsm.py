"""couche 1 grgsm — gr-gsm dans QEMU (qosmo calypso_l1_grgsm.c) et le pont (pont.py).
Motifs = les chaines que ces programmes ecrivent."""
import re

import pytest

import banc

pytestmark = [pytest.mark.banc_couche1, pytest.mark.grgsm]


def test_process_couche1():
    assert banc.alive("qemu-system-arm"), "qemu-system-arm absent"
    assert banc.alive("osmocon"), "osmocon absent"


def test_backend_grgsm_annonce():
    banc.require_log("qemu")
    assert banc.count("qemu", r"backend gr-gsm") >= 1, "qemu.log : la couche 1 gr-gsm ne s'est pas annoncee"


def test_synchro_fb_sb():
    banc.require_log("qemu")
    ln = banc.last("qemu", r"synchro gr-gsm : ARFCN=")
    assert ln, "pas de « synchro gr-gsm : ARFCN=... BSIC=... » : FB/SB non decodes"
    assert re.search(r"BSIC=\d+", ln), ln


def test_pont_stats_bursts_descendants():
    banc.require_log("pont")
    ln = banc.last("pont", r"STATS fn=")
    assert ln, "pont.log sans ligne STATS"
    m = re.search(r"DL bursts=(\d+) blocs=(\d+) crc=(\d+)", ln)
    assert m, ln
    bursts, blocs, crc = map(int, m.groups())
    assert bursts > 1000, f"seulement {bursts} bursts DL"
    assert blocs > 0, "aucun bloc L2 decode"
    assert crc <= max(5, blocs // 100), f"{crc} echecs CRC pour {blocs} blocs"


def test_pont_rach_monte():
    banc.require_log("pont")
    ln = banc.last("pont", r"STATS fn=")
    m = re.search(r"rach=(\d+)", ln)
    assert m and int(m.group(1)) >= 1, f"aucun RACH publie par le firmware : {ln}"


def test_immediate_assignment_vu():
    banc.require_log("pont")
    assert banc.count("pont", r"IMMEDIATE ASSIGNMENT") >= 1


def test_canal_dedie_sdcch():
    banc.require_log("qemu")
    assert banc.count("qemu", r"canal dedie SDCCH") >= 1, "aucun canal dedie SDCCH ouvert cote QEMU"


def test_chiffrement_a5_publie_et_confirme():
    banc.require_log("qemu")
    assert banc.count("qemu", r"chiffrement A5/") >= 1, "Kc jamais publie par le firmware"
    if banc.log("pont"):
        assert banc.count("pont", r"chiffrement descendant confirme par la BTS") >= 1, "le pont n'a pas vu la BTS chiffrer"


def test_pas_de_saut_de_frequence_non_gere():
    banc.require_log("pont")
    assert banc.count("pont", r"saut de frequence : TCH non arme") == 0, "ASSIGNMENT avec saut de frequence : hors du montage"


def test_pas_de_release_orphelin():
    banc.require_log("pont")
    assert banc.count("pont", r"CHANNEL RELEASE sans liberation du mobile") == 0


def test_qemu_sans_crash():
    banc.require_log("qemu")
    assert banc.count("qemu", r"Aborted|Segmentation fault|assertion failed|qemu: hardware error") == 0
