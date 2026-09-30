# banc.py — LE BANC VU PAR PYTEST : mode, journaux, VTY, compteurs.
#
# Le meme modele que /opt/GSM/tests/modules/_lib.sh, en Python : les deux
# couches 1 different par la VTY du mobile (4247 grgsm / 4347 dsp), la conf
# qu'il ouvre, et l'endroit ou leurs journaux tombent (qosmo :
# /run/user/<uid>/osmo-nitb/logs ; c54x_exe/run.sh : /tmp/c54x-pont). Le pont
# ecrit toujours /dev/shm/pont.log. Rien ici ne modifie le banc.
from __future__ import annotations

import os
import re
import socket
import subprocess
import time
from pathlib import Path

import pytest

ANSI = re.compile(r"\x1b\[[0-9;]*m")
DSPDIR = Path("/tmp/c54x-pont")
PONT_LOG = Path("/dev/shm/pont.log")
SMS_TXT = Path("/root/.osmocom/bb/sms.txt")
MSC_VTY, BSC_VTY, HLR_VTY, STP_VTY, BTS_VTY, MGW_VTY = 4254, 4242, 4258, 4239, 4241, 4243


def port_open(port: int, host="127.0.0.1", timeout=1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def alive(pattern: str) -> bool:
    return subprocess.run(["pgrep", "-f", "--", pattern], capture_output=True).returncode == 0


def _detect_mode() -> str:
    m = os.environ.get("CALYPSO_MODE", "").strip().lower()
    if m in ("dsp", "grgsm"):
        return m
    if port_open(4347):
        return "dsp"
    return "grgsm"


MODE = _detect_mode()
MOB_VTY = 4347 if MODE == "dsp" else 4247
MOB_CFG = Path("/opt/GSM/c54x_exe/mobile_pont.cfg" if MODE == "dsp" else "/root/.osmocom/bb/mobile.cfg")


def logdir() -> Path | None:
    cands = [p for p in Path("/run/user").glob("*/osmo-nitb/logs") if p.is_dir()]
    return max(cands, key=lambda p: p.stat().st_mtime) if cands else None


def log(name: str) -> Path | None:
    """Le journal `name` (dsp, qemu, osmocon, mobile, pont, bts) pour ce mode :
    le plus recent des emplacements possibles, None s'il n'existe pas."""
    if name == "pont":
        return PONT_LOG if PONT_LOG.is_file() else None
    cands = [DSPDIR / f"{name}.log"]
    ld = logdir()
    if ld:
        cands.append(ld / f"{name}.log")
    env = os.environ.get(f"CALYPSO_{name.upper()}_LOG")
    if env:
        cands.insert(0, Path(env))
    ok = [p for p in cands if p.is_file() and p.stat().st_size > 0]
    return max(ok, key=lambda p: p.stat().st_mtime) if ok else None


def text(name: str, tail: int = 0) -> str:
    p = log(name)
    if not p:
        return ""
    t = ANSI.sub("", p.read_text(errors="replace"))
    if tail:
        t = "\n".join(t.splitlines()[-tail:])
    return t


def count(name: str, regex: str, tail: int = 0) -> int:
    rx = re.compile(regex)
    return sum(1 for ln in text(name, tail).splitlines() if rx.search(ln))


def last(name: str, regex: str) -> str:
    rx = re.compile(regex)
    hits = [ln for ln in text(name).splitlines() if rx.search(ln)]
    return hits[-1] if hits else ""


def require_log(name: str) -> Path:
    p = log(name)
    if not p:
        pytest.skip(f"journal {name} absent pour le mode {MODE}")
    return p


def vty(port: int, cmd: str, wait: float = 1.0) -> str:
    """`enable` puis la commande ; on lit jusqu'au silence. Couleurs et \\r retires."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
            s.sendall(f"enable\n{cmd}\n".encode())
            s.settimeout(0.3)
            buf, fin = b"", time.time() + wait + 2
            while time.time() < fin:
                try:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                    if buf.rstrip().endswith(b"# ") or buf.rstrip().endswith(b"#"):
                        # invite revenue apres la commande : on laisse `wait` pour la suite asynchrone
                        time.sleep(wait)
                        try:
                            buf += s.recv(65536)
                        except OSError:
                            pass
                        break
                except socket.timeout:
                    continue
    except OSError:
        return ""
    return ANSI.sub("", buf.decode(errors="replace")).replace("\r", "")


def show_ms() -> str:
    return vty(MOB_VTY, "show ms 1")


def msc_stats() -> dict[str, list[int]]:
    """« show statistics » du MSC : {"SMS MO": [submitted, no_receiver], ...}."""
    out = {}
    for ln in vty(MSC_VTY, "show statistics").splitlines():
        m = re.match(r"([A-Za-z /-]+?)\s*:\s*(.*)", ln)
        if m and re.search(r"\d", m.group(2)):
            out[m.group(1).strip()] = [int(x) for x in re.findall(r"\d+", m.group(2))]
    return out


def imsi() -> str:
    try:
        m = re.search(r"^\s*imsi\s+(\d{15})", MOB_CFG.read_text(), re.M)
        return m.group(1) if m else ""
    except OSError:
        return ""


def msisdn(imsi_: str) -> str:
    m = re.search(r"MSISDN:\s*(\d+)", vty(MSC_VTY, f"show subscriber imsi {imsi_}"))
    return m.group(1) if m else ""
