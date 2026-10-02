"""The same kiosk actions and a scan, over real SMB - against a Samba share
per kiosk. Skipped unless KFW_TEST_SMB names one:

    KFW_TEST_SMB='\\\\localhost\\{0}|smbuser|smbpass|/srv/kiosks'

where /srv/kiosks/<HOST> is what the share <HOST> serves, and MWEB1 and PWEB1
resolve to the Samba server. See docs/TESTING.md.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from kfw.actions import ActionContext, run_action
from kfw.collector import read_fleet_csv, run_scan
from kfw.config import Settings
from kfw.demo import FakeLauncher, build_kiosks, docs
from kfw.kiosk_fs import KioskFS

SPEC = os.environ.get("KFW_TEST_SMB", "")
pytestmark = pytest.mark.skipif(not SPEC, reason="KFW_TEST_SMB is not set")


@pytest.fixture
def smb(tmp_path):
    template, user, password, local = SPEC.split("|")
    root = Path(local)
    for h in ("MWEB1", "PWEB1"):
        for p in sorted((root / h).glob("**/*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    build_kiosks(root)
    # The share's own user has to be able to write there, as on a kiosk.
    for p in [root, *root.glob("**/*")]:
        p.chmod(0o777 if p.is_dir() else 0o766)
    s = Settings(data_dir=tmp_path, root_template=template, kiosk_user=user, kiosk_password=password, ping_timeout_ms=500)
    dirs = {"ng": docs(root, "MWEB1") / "Mach2LauncherNG" / "S1", "pbi": docs(root, "PWEB1") / "PbiLauncher"}
    with FakeLauncher(root, dirs):
        yield s, root, dirs


def act(s, host, name, kind="ALL", params=None, secret=None):
    return run_action(name, ActionContext(settings=s, fs=KioskFS(s), target=host, kind=kind, params=params or {}, secret=secret))


def test_scan_over_smb(smb):
    s, root, _ = smb
    (s.data_dir / "kiosk-list.csv").write_text("Host,Type,HasMwst\nMWEB1,Mach2,Y\nPWEB1,PBI,\n")
    assert run_scan(s) == 0
    status = {r["Host"]: r["Outcome"] for r in read_fleet_csv(s.local_csv).rows if r["EventType"] == "HOST_STATUS"}
    assert status == {"MWEB1": "OK", "PWEB1": "OK"}


def test_actions_over_smb(smb):
    s, root, dirs = smb
    assert act(s, "MWEB1", "test")["Ok"]
    assert act(s, "MWEB1", "live")["Ok"]
    assert "taken" in act(s, "MWEB1", "control", params={"file": "refresh.txt"})["Detail"]
    assert act(s, "MWEB1", "snapshot")["Ok"]
    assert act(s, "MWEB1", "log", "NG")["Ok"]
    assert act(s, "PWEB1", "config-write", "PBI", {"instance": "S1", "values": {"DisplayURL": "https://new/x", "UserName": "kiosk@contoso.test"}})["Ok"]
    assert json.loads((dirs["pbi"] / "PWEB1.json").read_text())["DisplayURL"] == "https://new/x"
    assert act(s, "PWEB1", "password", "PBI", secret="Secret-Pass-1!")["Ok"]
    assert (dirs["pbi"] / "taken.seed").read_text() == "Secret-Pass-1!"
    assert act(s, "MWEB1", "message", params={"text": "hi", "seconds": 30, "poll": 0.5})["Status"] == "ACKNOWLEDGED"
