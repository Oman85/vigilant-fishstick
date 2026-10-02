"""Reading the launchers' state off a kiosk, and the watchdog's ledger.

Each launcher instance (one per screen folder: S1, S2, ...) rewrites
Status\\<instance>.status.json every few seconds while it runs. This turns those
files into one host status in the collector's vocabulary, plus the details the
dashboard shows. Three launchers share it:

  PBI Launcher       Users\\Public\\Documents\\PbiLauncher       a Power BI report
  Web Launcher       Users\\Public\\Documents\\WebLauncher       one web page
  Mach2 Launcher NG  Users\\Public\\Documents\\Mach2LauncherNG   a Mach2 dashboard,
                                                              and the watchdog

Host statuses, worst first:

  LAUNCHER_STALE     status not written for a while: not running    CRITICAL
  LAUNCHER_STOPPED   stopped (kill.txt) - the screen is empty       CRITICAL
  LAUNCHER_ERROR     Edge will not start, or Power BI refuses       CRITICAL
  SIGNIN_BLOCKED     sign-in needs a person (password, MFA)         CRITICAL
  WRONG_ACCOUNT      Power BI signed in as someone else             CRITICAL
  RECOVERING         fixing an error or blank page                  WARNING
  NOT_SHOWING        loading or signing in for over 15 minutes      WARNING
  NO_DISPLAY         the configured screen is not connected         WARNING
  HOLD               paused with hold.txt                           WARNING
  UNSUPERVISED       only keeping Edge open                         WARNING
  LAUNCHER_DISABLED  DisableStartup is set                          WARNING
  LAUNCHER_NOT_RUN   installed, never started                       WARNING
  OK
"""
from __future__ import annotations

import csv
import io
import json
import re
from datetime import datetime

from .kiosk_fs import KPath
from .timeutil import parse_utc, utc_iso

STATE_RANK = {
    "LAUNCHER_STALE": 1, "LAUNCHER_STOPPED": 2, "LAUNCHER_ERROR": 3, "SIGNIN_BLOCKED": 4, "WRONG_ACCOUNT": 5,
    "RECOVERING": 20, "NOT_SHOWING": 21, "NO_DISPLAY": 22, "HOLD": 23, "UNSUPERVISED": 24,
    "LAUNCHER_DISABLED": 25, "LAUNCHER_NOT_RUN": 26, "OK": 99,
}

NG_FOLDER = "Mach2LauncherNG"
PUBLIC_DOCS = ("Users", "Public", "Documents")


def is_ng_version(version) -> bool:
    """1.00NG and later: the watchdog is built into the launcher."""
    return re.match(r"^\d+\.\d+NG$", str(version or "").strip()) is not None


def _read_json(p: KPath):
    try:
        v = json.loads(p.read_text())
        return v[0] if isinstance(v, list) and v else v
    except (OSError, ValueError):
        return None


def instance_status(inst: dict, stale_minutes: int = 5, not_showing_minutes: int = 15, check_account: bool = True) -> tuple[str, str]:
    state = inst.get("State") or ""
    if state == "STOPPED":
        return "LAUNCHER_STOPPED", "CRITICAL"
    if state == "DISABLED":
        return "LAUNCHER_DISABLED", "WARNING"
    age = inst.get("AgeMinutes")
    if age is None or age > stale_minutes:
        return "LAUNCHER_STALE", "CRITICAL"
    simple = {"ERROR": ("LAUNCHER_ERROR", "CRITICAL"), "SIGNIN_BLOCKED": ("SIGNIN_BLOCKED", "CRITICAL"),
              "RECOVERING": ("RECOVERING", "WARNING"), "WAITING_DISPLAY": ("NO_DISPLAY", "WARNING"),
              "HOLD": ("HOLD", "WARNING"), "UNSUPERVISED": ("UNSUPERVISED", "WARNING")}
    if state in simple:
        return simple[state]
    if check_account and inst.get("UserName") and inst.get("SignedInAs") and inst["SignedInAs"] != inst["UserName"]:
        return "WRONG_ACCOUNT", "CRITICAL"
    mins = inst.get("StateMinutes")
    if state in ("LOADING", "SIGNING_IN", "STARTING", "LAUNCHING") and mins is not None and mins > not_showing_minutes:
        return "NOT_SHOWING", "WARNING"
    return "OK", "INFO"


def _has_config(d: KPath, host: str | None) -> bool:
    entries = d.files("*.json")
    names = {e.name.lower() for e in entries}
    if host and f"{host.lower()}.json" in names:
        return True
    if "config.json" in names:
        return True
    return any(e.name not in ("EXAMPLE.json", "migration.json") and not e.name.lower().endswith(".status.json") for e in entries)


def screen_folders(root: KPath, name: str, host: str | None) -> list[dict]:
    """Where a launcher keeps its screens: one folder per screen (S1, S2, ...),
    and - for PBI Launcher before 2.0.1 - the launcher's own folder, as S1."""
    base = root / "\\".join(PUBLIC_DOCS) / name
    rel = "Users\\Public\\Documents\\" + name
    out: list[dict] = []
    entries = base.iterdir()
    if not entries and not base.exists():
        return out
    for d in sorted((e for e in entries if e.is_dir and re.match(r"^S\d+$", e.name, re.IGNORECASE)), key=lambda e: e.name.upper()):
        out.append({"Screen": d.name.upper(), "Folder": f"{rel}\\{d.name}", "Path": d.path, "HasConfig": _has_config(d.path, host)})
    # The layout from before the screen folders: config and Status\ next to the script.
    names = {e.name.lower() for e in entries}
    host_json = bool(host) and f"{host.lower()}.json" in names
    if not any(s["Screen"] == "S1" and s["HasConfig"] for s in out) and ("status" in names or host_json):
        out = [{"Screen": "S1", "Folder": rel, "Path": base, "HasConfig": host_json, "Legacy": True}] + [s for s in out if s["Screen"] != "S1"]
    return out


def _empty_obs(kind: str) -> dict:
    return {"Launcher": kind, "Installed": False, "LegacyLauncher": False, "OldLauncher": False, "Screens": [], "Instances": [],
            "Status": None, "Severity": None, "Summary": "", "LauncherVersion": "", "PcBootUtc": None, "Error": ""}


def _age(now: datetime, t: datetime | None) -> float | None:
    return round((now - t).total_seconds() / 60.0, 1) if t else None


def pbi_observation(root: KPath, now: datetime, stale_minutes: int = 5, host: str | None = None, name: str = "PbiLauncher") -> dict:
    """Everything knowable about a kiosk's PBI Launcher (or, with
    name='WebLauncher', its Web Launcher) from its admin share. Never raises."""
    kind = "WEB" if name == "WebLauncher" else "PBI"
    obs = _empty_obs(kind)
    try:
        docs = root / "\\".join(PUBLIC_DOCS)
        if name == "PbiLauncher":
            for rel in ("Launchers", "Mach2Launchers"):
                for d in (docs / rel).dirs():
                    if d.name.upper().startswith("LAUNCHER S") and ((d.path / "PowerBILauncher.exe").exists() or (d.path / "PowerBILauncher\\PowerBILauncher.exe").exists()):
                        obs["LegacyLauncher"] = True

        folder = docs / name
        obs["Installed"] = (folder / f"{name}.ps1").exists()
        folders = screen_folders(root, name, host)
        obs["Screens"] = [s["Screen"] for s in folders if s["HasConfig"]]
        tag = "web" if kind == "WEB" else "launcher"
        if not obs["Installed"]:
            obs["Summary"] = f"{tag}=old" if obs["LegacyLauncher"] else (f"{tag}=config written, not installed" if obs["Screens"] else f"{tag}=none")
            return obs

        files = []
        for sf in folders:
            for f in (sf["Path"] / "Status").files("*.status.json"):
                files.append((f, sf))
        if not files:
            obs.update(Status="LAUNCHER_NOT_RUN", Severity="WARNING", Summary=f"{tag}=installed, not started")
            return obs

        worst = None
        instances = []
        for f, sf in files:
            s = _read_json(f.path)
            if not isinstance(s, dict):
                continue
            updated, since = parse_utc(s.get("UpdatedUtc")), parse_utc(s.get("StateSinceUtc"))
            inst = {
                "Instance": str(s.get("Instance") or ""), "Screen": sf["Screen"], "Folder": sf["Folder"], "Launcher": kind,
                "State": str(s.get("State") or ""), "Detail": str(s.get("Detail") or ""),
                "UpdatedUtc": updated, "AgeMinutes": _age(now, updated), "StateMinutes": _age(now, since),
                "LastShownUtc": parse_utc(s.get("LastShownUtc")), "LauncherVersion": str(s.get("LauncherVersion") or ""),
                "EdgeVersion": re.sub(r"^Edg/", "", str(s.get("EdgeVersion") or "")),
                "UserName": str(s.get("UserName") or ""), "SignedInAs": str(s.get("SignedInAs") or ""),
                "SignIns": s.get("SignIns"), "Reloads": s.get("Reloads"), "BrowserStarts": s.get("BrowserStarts"),
                "LastError": str(s.get("LastError") or ""), "PcBootUtc": parse_utc(s.get("PcBootUtc")),
                "HostStatus": "", "Severity": "",
            }
            inst["HostStatus"], inst["Severity"] = instance_status(inst, stale_minutes)
            instances.append(inst)
            if worst is None or STATE_RANK[inst["HostStatus"]] < STATE_RANK[worst["HostStatus"]]:
                worst = inst
        if worst is None:
            obs.update(Status="LAUNCHER_NOT_RUN", Severity="WARNING", Summary=f"{tag}=status unreadable")
            return obs

        obs.update(Instances=instances, Status=worst["HostStatus"], Severity=worst["Severity"],
                   LauncherVersion=worst["LauncherVersion"], PcBootUtc=worst["PcBootUtc"])
        parts = []
        for i in instances:
            as_ = f" as={i['SignedInAs']}" if i["SignedInAs"] else ""
            parts.append(f"{tag}={i['Screen']}:{i['State']}{as_} age={_num(i['AgeMinutes'])}m v{i['LauncherVersion']}")
        obs["Summary"] = "; ".join(parts)
    except Exception as e:  # noqa: BLE001 - never raises; the error is reported
        obs["Error"] = str(e)
    return obs


def web_observation(root: KPath, now: datetime, stale_minutes: int = 5, host: str | None = None) -> dict:
    return pbi_observation(root, now, stale_minutes, host, name="WebLauncher")


def ng_observation(folder: KPath, now: datetime, stale_minutes: int = 5) -> dict:
    """Mach2 Launcher NG, from the kiosk's Public Documents. Never raises."""
    obs = _empty_obs("MACH2")
    try:
        old = folder / "Mach2Launchers"
        obs["OldLauncher"] = any(d.name.upper().startswith("LAUNCHER S") and (d.path / "Mach2Launcher.exe").exists() for d in old.dirs())
        root = folder / NG_FOLDER
        obs["Installed"] = (root / "Mach2LauncherNG.ps1").exists()
        subdirs = root.dirs()
        obs["Screens"] = sorted(d.name.upper() for d in subdirs if re.match(r"^S\d+$", d.name, re.IGNORECASE)
                                and any(e.name != "EXAMPLE.json" for e in d.path.files("*.json")))
        if not obs["Installed"]:
            obs["Summary"] = "launcher=old" if obs["OldLauncher"] else ""
            return obs

        files = []
        for d in subdirs:
            for f in (d.path / "Status").files("*.status.json"):
                files.append((f, d.name))
        if not files:
            obs.update(Status="LAUNCHER_NOT_RUN", Severity="WARNING", Summary="launcher=NG installed, not started")
            return obs

        worst = None
        instances = []
        for f, dname in files:
            s = _read_json(f.path)
            if not isinstance(s, dict):
                continue
            updated, since = parse_utc(s.get("UpdatedUtc")), parse_utc(s.get("StateSinceUtc"))
            inst = {
                "Instance": str(s.get("Instance") or ""), "Screen": dname.upper(),
                "Folder": f"Users\\Public\\Documents\\{NG_FOLDER}\\{dname}", "Launcher": "MACH2",
                "State": str(s.get("State") or ""), "Detail": str(s.get("Detail") or ""),
                "UpdatedUtc": updated, "AgeMinutes": _age(now, updated), "StateMinutes": _age(now, since),
                "LastShownUtc": parse_utc(s.get("LastShownUtc")), "LauncherVersion": str(s.get("LauncherVersion") or ""),
                "EdgeVersion": re.sub(r"^Edg/", "", str(s.get("EdgeVersion") or "")),
                "Watchdog": bool(s.get("Watchdog")), "LoopGuard": str(s.get("LoopGuard") or ""),
                "PageWhitePercent": s.get("PageWhitePercent"), "ScreenWhitePercent": s.get("ScreenWhitePercent"),
                "SignIns": s.get("SignIns"), "Reloads": s.get("Reloads"), "BrowserStarts": s.get("BrowserStarts"),
                "PcRestarts": s.get("PcRestarts"), "LastError": str(s.get("LastError") or ""),
                "PcBootUtc": parse_utc(s.get("PcBootUtc")), "HostStatus": "", "Severity": "",
            }
            inst["HostStatus"], inst["Severity"] = instance_status(inst, stale_minutes, check_account=False)
            instances.append(inst)
            if worst is None or STATE_RANK[inst["HostStatus"]] < STATE_RANK[worst["HostStatus"]]:
                worst = inst
        if worst is None:
            obs.update(Status="LAUNCHER_NOT_RUN", Severity="WARNING", Summary="launcher=NG status unreadable")
            return obs

        obs.update(Instances=instances, Status=worst["HostStatus"], Severity=worst["Severity"],
                   LauncherVersion=worst["LauncherVersion"], PcBootUtc=worst["PcBootUtc"])
        parts = []
        for i in sorted(instances, key=lambda x: x["Instance"]):
            if i["ScreenWhitePercent"] is not None:
                w = f" screen={i['ScreenWhitePercent']}%"
            elif i["PageWhitePercent"] is not None:
                w = f" page={i['PageWhitePercent']}%"
            else:
                w = ""
            parts.append(f"launcher={i['Instance']}:{i['State']}{w} age={_num(i['AgeMinutes'])}m v{i['LauncherVersion']}")
        obs["Summary"] = "; ".join(parts)
    except Exception as e:  # noqa: BLE001
        obs["Error"] = str(e)
    return obs


def _num(v) -> str:
    if v is None:
        return ""
    return str(int(v)) if float(v).is_integer() else str(v)


def _iso(t) -> str:
    return utc_iso(t) if t else ""


def sidecar_entry(obs: dict) -> dict:
    """The per-kiosk details the dashboard shows, small enough for the collector's status file."""
    if obs["Launcher"] == "MACH2":
        return {
            "Launcher": "MACH2", "Installed": obs["Installed"], "OldLauncher": obs["OldLauncher"], "Screens": list(obs["Screens"]),
            "Status": obs["Status"], "Error": obs["Error"],
            "Instances": [{
                "Instance": i["Instance"], "Screen": i["Screen"], "Folder": i["Folder"], "State": i["State"], "Detail": i["Detail"],
                "HostStatus": i["HostStatus"], "UpdatedUtc": _iso(i["UpdatedUtc"]), "StateMinutes": i["StateMinutes"],
                "LastShownUtc": _iso(i["LastShownUtc"]), "Version": i["LauncherVersion"], "Edge": i["EdgeVersion"],
                "Watchdog": i["Watchdog"], "LoopGuard": i["LoopGuard"], "PageWhitePercent": i["PageWhitePercent"],
                "ScreenWhitePercent": i["ScreenWhitePercent"], "SignIns": i["SignIns"], "Reloads": i["Reloads"],
                "BrowserStarts": i["BrowserStarts"], "PcRestarts": i["PcRestarts"], "LastError": i["LastError"],
            } for i in obs["Instances"]],
        }
    return {
        "Launcher": obs["Launcher"], "Installed": obs["Installed"], "LegacyLauncher": obs["LegacyLauncher"], "Screens": list(obs["Screens"]),
        "Status": obs["Status"], "Error": obs["Error"],
        "Instances": [{
            "Instance": i["Instance"], "Screen": i["Screen"], "Folder": i["Folder"], "State": i["State"], "Detail": i["Detail"],
            "HostStatus": i["HostStatus"], "UpdatedUtc": _iso(i["UpdatedUtc"]), "StateMinutes": i["StateMinutes"],
            "LastShownUtc": _iso(i["LastShownUtc"]), "Version": i["LauncherVersion"], "Edge": i["EdgeVersion"],
            "UserName": i["UserName"], "SignedInAs": i["SignedInAs"], "SignIns": i["SignIns"], "Reloads": i["Reloads"],
            "BrowserStarts": i["BrowserStarts"], "LastError": i["LastError"],
        } for i in obs["Instances"]],
    }


# ---------------------------------------------------------------------------
# The watchdog's ledger
# ---------------------------------------------------------------------------
def read_agent_ledger(folder: KPath) -> dict:
    """Every ledger file a kiosk has, oldest first: rolled-over files (named by
    their timestamp) before the live one, so file order is event order."""
    result = {"Files": 0, "Rows": [], "Errors": []}
    files = folder.files("mwst_events*.csv")
    files.sort(key=lambda e: (1 if e.name.lower() == "mwst_events.csv" else 0, e.name))
    result["Files"] = len(files)
    for f in files:
        try:
            text = f.path.read_text()
            # Only complete lines: a row mid-append would otherwise be taken
            # truncated, and never replaced since its EventId is already known.
            cut = text.rfind("\n")
            if cut < 0:
                continue
            text = text[: cut + 1]
            result["Rows"].extend(csv.DictReader(io.StringIO(text)))
        except (OSError, csv.Error) as e:
            result["Errors"].append(f"Ledger {f.name}: {e}")
    return result
