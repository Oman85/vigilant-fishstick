"""A fleet that is not there: kiosks as folders, a thread playing their
launchers and watchdog, and the events of a recent scan. For trying the app
(kfw demo, or KFW_DEMO=1 in the container) and for the tests."""
from __future__ import annotations

import base64
import csv
import json
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .collector import COLUMNS
from .timeutil import local_date, local_iso, utc_iso

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
LEDGER_HEADER = "EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail"


def docs(root: Path, host: str) -> Path:
    return root / host / "Users" / "Public" / "Documents"


def write_json(p: Path, obj) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj), encoding="utf-8")


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f0Z")


def build_kiosks(root: Path) -> dict[str, Path]:
    """MWEB1 runs Mach2 Launcher NG on S1 (and is the watchdog), PWEB1 runs
    PBI Launcher in its old single-folder layout, NEWWEB1 is an empty PC."""
    now = datetime.now(timezone.utc)
    ng = docs(root, "MWEB1") / "Mach2LauncherNG" / "S1"
    pbi = docs(root, "PWEB1") / "PbiLauncher"
    for d in (ng / "Status", ng / "Logs", pbi / "Status", root / "NEWWEB1" / "Users", docs(root, "MWEB1") / "mwst_inbox"):
        d.mkdir(parents=True, exist_ok=True)
    (ng.parent / "Mach2LauncherNG.ps1").write_text("# fake")
    (pbi / "PbiLauncher.ps1").write_text("# fake")
    write_json(ng / "MWEB1.json", {"ConfigVersion": "1.00NG", "LoginURL": "http://station:302/prelogin?clear=true",
                                   "DisplayURL": "http://station:302/ord/dashboard", "UserName": "operator", "ScreenSelect": "1",
                                   "Watchdog": "1", "LogName": "MWEB1_Mach2LauncherNG.log"})
    write_json(ng / "Status" / "S1.status.json", {
        "Instance": "S1", "State": "SHOWING", "LauncherVersion": "1.00NG", "EdgeVersion": "Edg/153.0", "UpdatedUtc": iso(now),
        "StateSinceUtc": iso(now - timedelta(minutes=55)), "Watchdog": True, "LoopGuard": "OFF", "ScreenWhitePercent": 72,
        "PageWhitePercent": 63, "SignIns": 1, "Reloads": 2, "BrowserStarts": 1, "PcRestarts": 0, "LastError": ""})
    (ng / "Logs" / "MWEB1_Mach2LauncherNG.log").write_text(
        '<![LOG[The dashboard is on screen.]LOG]!><time="08:30:00.000+000" date="09-20-2026" component="Mach2LauncherNG" context="" type="1" thread="1" file="">')
    write_json(pbi / "PWEB1.json", {"DisplayURL": "https://app.powerbi.test/report", "UserName": "kiosk@contoso.test"})
    write_json(pbi / "Status" / "PWEB1.status.json", {
        "Instance": "PWEB1", "State": "SHOWING", "LauncherVersion": "2.0.0", "EdgeVersion": "Edg/153.0", "UpdatedUtc": iso(now),
        "StateSinceUtc": iso(now - timedelta(minutes=30)), "UserName": "kiosk@contoso.test", "SignedInAs": "kiosk@contoso.test",
        "SignIns": 1, "Reloads": 3, "BrowserStarts": 1, "LastError": ""})
    # The watchdog's own files: a fresh log and a ledger.
    (docs(root, "MWEB1") / "mwst.log").write_text("heartbeat\n")
    boot = now - timedelta(hours=9)
    rows = [LEDGER_HEADER,
            f"{uuid.uuid4()},{utc_iso(now - timedelta(days=2))},,MWEB1,AGENT_START,INFO,STARTED,,,,1.00NG,{utc_iso(boot)},started"]
    (docs(root, "MWEB1") / "mwst_events.csv").write_text("\r\n".join(rows) + "\r\n")
    return {"ng": ng, "pbi": pbi}


class FakeLauncher:
    """Takes control files, answers snapshot.txt with a picture, stores
    password.seed, and plays the watchdog for messages - leaving hold.txt
    alone, as a real launcher does."""

    def __init__(self, root: Path, dirs: dict[str, Path]):
        self.root = root
        self.dirs = [(dirs["ng"], "S1"), (dirs["pbi"], "PWEB1")]
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.stop.wait(0.1):
            for d, name in self.dirs:
                for f in ("refresh.txt", "relaunch.txt", "kill.txt"):
                    p = d / f
                    if p.exists():
                        try:
                            (d / f"taken.{f}").write_text(p.read_text())
                            p.unlink()
                        except OSError:
                            pass
                snap = d / "snapshot.txt"
                if snap.exists():
                    snap.unlink(missing_ok=True)
                    (d / "Status" / f"{name}.png").write_bytes(PNG)
                    write_json(d / "Status" / f"{name}.snapshot.json", {
                        "TakenUtc": iso(datetime.now(timezone.utc)), "State": "SHOWING", "Url": "http://station/dashboard",
                        "Title": "Dashboard", "Image": f"{name}.png", "Error": ""})
                seed = d / "password.seed"
                if seed.exists():
                    try:
                        (d / "taken.seed").write_text(seed.read_text())
                        seed.unlink()
                    except OSError:
                        pass
            inbox = docs(self.root, "MWEB1") / "mwst_inbox"
            for m in inbox.glob("msg_*.json"):
                try:
                    msg = json.loads(m.read_text())
                except (OSError, ValueError):
                    continue
                m.unlink(missing_ok=True)
                now = datetime.now(timezone.utc)
                ledger = docs(self.root, "MWEB1") / "mwst_events.csv"
                with open(ledger, "a", encoding="utf-8") as fh:
                    fh.write(f"{uuid.uuid4()},{utc_iso(now)},,MWEB1,MESSAGE_SHOWN,INFO,SHOWN,,,,1.00NG,,MessageId={msg['Id']}; shown\r\n")
                    fh.write(f"{uuid.uuid4()},{utc_iso(now)},,MWEB1,MESSAGE_CLOSED,INFO,ACKNOWLEDGED,,,,1.00NG,,MessageId={msg['Id']}; OK pressed\r\n")

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.stop.set()
        self.thread.join(2)


def write_events(csv_path: Path) -> None:
    """The events CSV and status file as the collector leaves them."""
    now = datetime.now(timezone.utc).replace(microsecond=0)
    kiosks = [
        ("MWEB1", "LINE1", "Mach2", "OK", "TRUE", "1.00NG", 1),
        ("MWEB2", "LINE2", "Mach2", "STALE", "FALSE", "7.0", 1900),
        ("MWEB3", "LINE3", "Mach2", "OK", "TRUE", "6.1", 2),
        ("PWEB1", "APU1", "PBI", "OK", "", "", None),
        ("PWEB2", "APU2", "PBI - SR", "WRONG_ACCOUNT", "", "", None),
        ("PWEB3", "APU3", "PBI", "OFFLINE", "", "", None),
        ("OWEB1", "STORE", "Signage", "OK", "", "", None),
    ]
    rows = []

    def add(**v):
        r = {c: "" for c in COLUMNS}
        r.update(v)
        rows.append(r)

    t = now - timedelta(minutes=4)
    for h, loc, typ, status, wd, agent, log in kiosks:
        add(EventId=str(uuid.uuid4()), EventTimeUtc=utc_iso(t), EventTimeLocal=local_iso(t), EventDate=local_date(t), Host=h,
            Location=loc, KioskType=typ, EventCategory="HOST", EventType="HOST_STATUS", Severity="INFO", Outcome=status,
            Reachable="TRUE", WatchdogRunning=wd, AgentVersion=agent, MinutesSinceLastLog="" if log is None else str(log),
            BootTimeUtc=utc_iso(now - timedelta(hours=9)), UptimeHours="9", Source="Collector", Detail=f"reach=ping share=ok for {h}")
    # MWEB2's week: a reboot the watchdog asked for, an update's restart
    # today and another yesterday, each followed by its boot.
    def reboot(when, etype, trigger, script, canonical, detail=""):
        add(EventId=str(uuid.uuid4()), EventTimeUtc=utc_iso(when), EventTimeLocal=local_iso(when), EventDate=local_date(when),
            Host="MWEB2", Location="LINE2", KioskType="Mach2", EventCategory="REBOOT", EventType=etype,
            Severity="CRITICAL" if script else "WARNING", Outcome="BOOT" if etype == "BOOT" else "REBOOT",
            IsCanonicalReboot="TRUE" if canonical else "FALSE", IsScriptReboot="TRUE" if script else "FALSE",
            RebootTrigger=trigger, Source="Agent" if etype == "RESTART_TRIGGERED" else "EventLog", Detail=detail)
    y = now - timedelta(days=1)
    reboot(y, "REBOOT_EXTERNAL", "EXTERNAL", False, True, "Process=TrustedInstaller.exe; Reason=Operating System: Upgrade")
    reboot(y + timedelta(minutes=2), "BOOT", "", False, False)
    reboot(now - timedelta(hours=5), "RESTART_TRIGGERED", "WATCHDOG_WHITE", True, True, "Kind=WHITE white for 300s")
    reboot(now - timedelta(hours=3), "REBOOT_EXTERNAL", "EXTERNAL", False, True, "Process=explorer.exe; Reason=Other (Unplanned)")
    reboot(now - timedelta(hours=3) + timedelta(minutes=2), "BOOT", "", False, False)
    add(EventId=str(uuid.uuid4()), EventTimeUtc=utc_iso(t), EventTimeLocal=local_iso(t), EventDate=local_date(t),
        EventCategory="COLLECTOR", EventType="COLLECTOR_RUN", Severity="INFO", Outcome="OK", Source="Collector")
    with open(csv_path, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, COLUMNS, quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(rows)
    sidecar = {
        "LastRunUtc": utc_iso(t), "DurationSeconds": 42, "Hosts": 7, "Reachable": 6, "NewEvents": 0, "CollectorVersion": "6.2", "Runner": "test@here",
        "PbiLaunchers": {
            "PWEB1": {"Installed": True, "LegacyLauncher": False, "Status": "OK", "Error": "", "Screens": ["S1"], "Instances": [
                {"Instance": "PWEB1", "Screen": "S1", "State": "SHOWING", "HostStatus": "OK", "UpdatedUtc": utc_iso(now), "StateMinutes": 30,
                 "Version": "2.0.0", "Edge": "153.0", "SignedInAs": "kiosk@contoso.test", "SignIns": 1, "Reloads": 3, "BrowserStarts": 1, "LastError": ""}]},
            "PWEB2": {"Installed": True, "LegacyLauncher": False, "Status": "WRONG_ACCOUNT", "Error": "", "Instances": [
                {"Instance": "PWEB2", "Screen": "S1", "State": "SHOWING", "HostStatus": "WRONG_ACCOUNT", "UpdatedUtc": utc_iso(now), "StateMinutes": 12,
                 "Version": "2.0.0", "Edge": "153.0", "SignedInAs": "someone@contoso.test", "SignIns": 1, "Reloads": 1, "BrowserStarts": 1, "LastError": ""}]},
        },
        "Mach2Launchers": {
            "MWEB1": {"Installed": True, "OldLauncher": False, "Status": "OK", "Error": "", "Screens": ["S1"], "Instances": [
                {"Instance": "S1", "Screen": "S1", "State": "SHOWING", "HostStatus": "OK", "UpdatedUtc": utc_iso(now), "StateMinutes": 55,
                 "Version": "1.00NG", "Edge": "153.0", "Watchdog": True, "LoopGuard": "OFF", "PageWhitePercent": 63, "ScreenWhitePercent": 72,
                 "SignIns": 1, "Reloads": 2, "BrowserStarts": 1, "PcRestarts": 0, "LastError": ""}]},
        },
    }
    csv_path.with_suffix(".status.json").write_text(json.dumps(sidecar))


DEMO_LIST = """Host,Location,Type,HasMwst,Active,RestartGroup
MWEB1,LINE1,Mach2,Y,,A
MWEB2,LINE2,Mach2,Y,,A
MWEB3,LINE3,Mach2,Y,,B
PWEB1,APU1,PBI,,,
PWEB2,APU2,PBI - SR,,,
PWEB3,APU3,PBI,,,
OWEB1,STORE,Signage,,,
NEWWEB1,LAB,Web board,,N,
"""


def seed(data_dir: Path) -> tuple[Path, FakeLauncher]:
    """Kiosks under data_dir/demo-kiosks, a kiosk list and a scan's worth of
    events - once - and the launchers playing. Returns the kiosks' template."""
    root = data_dir / "demo-kiosks"
    data_dir.mkdir(parents=True, exist_ok=True)
    if not root.exists():
        build_kiosks(root)
        for h in ("MWEB2", "MWEB3", "PWEB2", "OWEB1"):
            (root / h / "Users" / "Public" / "Documents").mkdir(parents=True, exist_ok=True)
    dirs = {"ng": docs(root, "MWEB1") / "Mach2LauncherNG" / "S1", "pbi": docs(root, "PWEB1") / "PbiLauncher"}
    if not (data_dir / "MWST_FleetEvents.csv").exists():
        write_events(data_dir / "MWST_FleetEvents.csv")
    if not any(data_dir.glob("kiosk-list.*")):
        (data_dir / "kiosk-list.csv").write_text(DEMO_LIST)
    launcher = FakeLauncher(root, dirs)
    launcher.__enter__()
    return root, launcher
