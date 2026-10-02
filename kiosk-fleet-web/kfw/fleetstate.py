"""From the events CSV (and the collector's status file next to it) to what
the page draws: the latest status per kiosk, reboot counts, a week of daily
counts, the launcher details, and every kiosk's details card.

The JSON keys are the PowerShell front end's (Host, Status, Launchers, ...),
so the page and anything else built against them keep working.
"""
from __future__ import annotations

import csv
import io
import json
import re
from datetime import datetime, timedelta
from pathlib import Path

from .launchers import is_ng_version
from .timeutil import format_minutes, parse_local, parse_utc, utcnow

STATUS_RANK = {
    "OFFLINE": 0, "LOOP_GUARD": 1, "NO_AGENT": 2, "STALE": 3,
    "LAUNCHER_STALE": 1, "LAUNCHER_STOPPED": 1, "LAUNCHER_ERROR": 1, "SIGNIN_BLOCKED": 1, "WRONG_ACCOUNT": 1,
    "NO_ACCESS": 4, "AGENT_OUTDATED": 5, "EVENTLOG_UNAVAILABLE": 6,
    "RECOVERING": 5, "NOT_SHOWING": 5, "NO_DISPLAY": 5, "HOLD": 6, "UNSUPERVISED": 6, "LAUNCHER_DISABLED": 6, "LAUNCHER_NOT_RUN": 6,
    "OK": 9, "INACTIVE": 10,
}
CRITICAL = {"OFFLINE", "STALE", "NO_AGENT", "LOOP_GUARD", "LAUNCHER_STALE", "LAUNCHER_STOPPED", "LAUNCHER_ERROR", "SIGNIN_BLOCKED", "WRONG_ACCOUNT"}
WARNING = {"NO_ACCESS", "AGENT_OUTDATED", "EVENTLOG_UNAVAILABLE", "RECOVERING", "NOT_SHOWING", "NO_DISPLAY", "HOLD", "UNSUPERVISED", "LAUNCHER_DISABLED", "LAUNCHER_NOT_RUN"}

LAUNCHER_FOLDERS = {"NG": "Mach2LauncherNG", "PBI": "PbiLauncher", "WEB": "WebLauncher"}
LAUNCHER_NAMES = {"NG": "Mach2 Launcher NG", "PBI": "PBI Launcher", "WEB": "Web Launcher"}
TAB_KINDS = {"Mach2": "NG", "PBI": "PBI", "Web": "WEB"}
KIND_TABS = {"NG": "Mach2", "PBI": "PBI", "WEB": "Web"}
KIND_OF_SCREEN_LAUNCHER = {"MACH2": "NG", "PBI": "PBI", "WEB": "WEB"}
LAUNCHER_TAB = {"MACH2": "Mach2", "PBI": "PBI", "WEB": "Web"}


def needs_attention(k: dict) -> bool:
    # INACTIVE is a decision, not a fault.
    return k["Status"] not in ("OK", "INACTIVE")


def severity(status: str) -> str:
    if status == "OK":
        return "OK"
    if status == "INACTIVE":
        return "INACTIVE"
    if status in CRITICAL:
        return "CRITICAL"
    if status in WARNING:
        return "WARNING"
    return "UNKNOWN"


def short_type(kind: str) -> str:
    if not kind:
        return ""
    t = kind.strip()
    if re.match(r"^(PBI|POWER\s*BI)", t, re.IGNORECASE):
        return "PBI"
    if re.match(r"^MACH", t, re.IGNORECASE):
        return "Mach2"
    if re.match(r"^WEB", t, re.IGNORECASE):
        return "Web"
    return re.split(r"[\s\-]", t)[0]


def kiosk_tab(kind: str) -> str:
    return {"Mach2": "Mach2", "PBI": "PBI", "Web": "Web"}.get(short_type(kind), "Other")


def kiosk_screens(entry: dict) -> list[dict]:
    """A kiosk's screens, whatever runs on them, from the collector's status file."""
    out: dict[str, dict] = {}
    for kind, l in (("MACH2", entry.get("Ng")), ("PBI", entry.get("Pbi")), ("WEB", entry.get("Web"))):
        if not l:
            continue
        for i in l.get("Instances") or []:
            if not i:
                continue
            screen = str(i.get("Screen") or (i.get("Instance") if kind == "MACH2" else "S1") or "S1")
            key = f"{screen}|{kind}"
            if key in out:
                continue
            out[key] = {"Screen": screen.upper(), "Launcher": kind, "Instance": str(i.get("Instance") or ""),
                        "State": str(i.get("State") or ""), "HostStatus": str(i.get("HostStatus") or ""),
                        "Detail": str(i.get("Detail") or ""), "Version": str(i.get("Version") or ""),
                        "Folder": str(i.get("Folder") or ""), "Watchdog": bool(i.get("Watchdog")), "Source": i}
        for s in l.get("Screens") or []:
            if not s:
                continue
            key = f"{s}|{kind}"
            if key in out:
                continue
            out[key] = {"Screen": str(s).upper(), "Launcher": kind, "Instance": str(s), "State": "NOT_RUN",
                        "HostStatus": "LAUNCHER_NOT_RUN", "Detail": "config written, no status yet", "Version": "",
                        "Folder": "", "Watchdog": False, "Source": None}
    return sorted(out.values(), key=lambda x: (x["Screen"], x["Launcher"]))


def kiosk_tabs(kind: str, screens: list[dict]) -> list[str]:
    tabs: list[str] = []
    t = kiosk_tab(kind)
    if t != "Other":
        tabs.append(t)
    for s in screens:
        tab = LAUNCHER_TAB.get(s["Launcher"])
        if tab and tab not in tabs:
            tabs.append(tab)
    return tabs or [t]


def _read_text(path: Path) -> str:
    return path.read_bytes().decode("utf-8-sig", errors="replace")


def read_fleet_state(path: Path) -> dict:
    """Everything a front end needs, in one pass over the CSV."""
    state = {"Ok": False, "Error": None, "Hosts": [], "LastCollected": None, "LastRun": None, "RowCount": 0,
             "DayKeys": [], "Pbi": {}, "Ng": {}, "Web": {}, "Sidecar": None, "Path": str(path)}
    if not path.exists():
        state["Error"] = f"No events file yet at {path} - run a scan once."
        return state
    try:
        text = _read_text(path)
        if not text.strip():
            state["Error"] = "The events file is empty."
            return state
        rows = list(csv.DictReader(io.StringIO(text)))
    except (OSError, csv.Error) as e:
        state["Error"] = f"Could not read the events file: {e}"
        return state
    state["RowCount"] = len(rows)

    sidecar = path.with_suffix(".status.json")
    if sidecar.exists():
        try:
            sc = json.loads(_read_text(sidecar))
            state["Sidecar"] = sc
            state["LastRun"] = sc.get("LastRunUtc")
            state["Pbi"] = dict(sc.get("PbiLaunchers") or {})
            state["Ng"] = dict(sc.get("Mach2Launchers") or {})
            state["Web"] = dict(sc.get("WebLaunchers") or {})
        except (OSError, ValueError, AttributeError):
            pass

    today = datetime.now().astimezone().date()
    state["DayKeys"] = [(today - timedelta(days=d)).isoformat() for d in range(6, -1, -1)]
    cutoff24 = datetime.now().astimezone() - timedelta(hours=24)
    by_host: dict[str, dict] = {}

    for r in rows:
        etype = r.get("EventType") or ""
        t_utc = r.get("EventTimeUtc") or ""
        if etype == "COLLECTOR_RUN":
            if not state["LastCollected"] or t_utc > state["LastCollected"]:
                state["LastCollected"] = t_utc
            continue
        h = r.get("Host") or ""
        if not h:
            continue
        e = by_host.get(h)
        if e is None:
            e = by_host[h] = {"Host": h, "Location": "", "Type": "", "Tab": "", "Tabs": [], "Status": "UNKNOWN",
                              "StatusRow": None, "Reboots24": 0, "Script24": 0, "Episodes24": 0, "HasWatchdog": False,
                              "Days": {}, "Pbi": None, "Ng": None, "Web": None, "Screens": []}
        if etype == "HOST_STATUS":
            if r.get("WatchdogRunning"):
                e["HasWatchdog"] = True
            if e["StatusRow"] is None or t_utc > e["StatusRow"].get("EventTimeUtc", ""):
                e["StatusRow"] = r
                e["Status"] = r.get("Outcome") or "UNKNOWN"
        if r.get("Location"):
            e["Location"] = r["Location"]
        if r.get("KioskType"):
            e["Type"] = r["KioskType"]
        if r.get("IsCanonicalReboot") == "TRUE":
            d = r.get("EventDate")
            if d:
                e["Days"][d] = e["Days"].get(d, 0) + 1
            when = parse_local(r.get("EventTimeLocal"))
            if when and when >= cutoff24:
                e["Reboots24"] += 1
                if r.get("IsScriptReboot") == "TRUE":
                    e["Script24"] += 1
        if etype in ("WHITE_EPISODE_START", "LOWWHITE_EPISODE_START"):
            when = parse_local(r.get("EventTimeLocal"))
            if when and when >= cutoff24:
                e["Episodes24"] += 1

    for e in by_host.values():
        e["Pbi"] = state["Pbi"].get(e["Host"])
        e["Ng"] = state["Ng"].get(e["Host"])
        e["Web"] = state["Web"].get(e["Host"])
        e["Screens"] = kiosk_screens(e)
        e["Tabs"] = kiosk_tabs(e["Type"], e["Screens"])
        e["Tab"] = kiosk_tab(e["Type"])
        if e["Tab"] == "Other" and e["Tabs"][0] != "Other":
            e["Tab"] = e["Tabs"][0]

    # Trouble first, then the kiosks that run a watchdog, then by place.
    state["Hosts"] = sorted(by_host.values(), key=lambda e: (
        STATUS_RANK.get(e["Status"], 8), 0 if e["HasWatchdog"] else 1, e["Location"].lower(), e["Host"].lower()))
    state["Ok"] = True
    return state


def freshness(state: dict | None, stale_minutes: int = 45) -> dict:
    """How old the data is, and whether that is a problem in itself: a dead
    collector must never look like a healthy fleet."""
    out = {"text": "collector has never run", "stale": True, "minutes": None, "lastRun": "never"}
    stamp = (state or {}).get("LastRun") or (state or {}).get("LastCollected")
    last = parse_utc(stamp)
    if not last:
        return out
    out["lastRun"] = last.astimezone().strftime("%a %d %b %H:%M")
    mins = max(0, int((utcnow() - last).total_seconds() / 60))
    out["minutes"] = mins
    if mins < stale_minutes:
        out["stale"] = False
        out["text"] = "collected just now" if mins <= 1 else f"collected {mins} min ago"
    elif mins < 1440:
        out["text"] = f"STALE - collector last ran {mins // 60} h ago"
    else:
        out["text"] = f"STALE - collector last ran {mins // 1440} days ago"
    return out


# ---------------------------------------------------------------------------
# One kiosk, as the page draws it
# ---------------------------------------------------------------------------
def launcher_view(k: dict, tab: str = "") -> dict:
    """What a kiosk's launcher was doing at the last scan. tab picks the
    launcher that tab is about; without it, the kiosk's own, then any."""
    out = {"Kind": "", "Known": False, "Installed": False, "Old": False, "State": "", "For": "", "Account": "",
           "Version": "", "Screen": "", "Severity": "UNKNOWN", "Instances": [], "Status": "", "Error": ""}
    if not k:
        return out
    want = TAB_KINDS.get(tab) if tab else TAB_KINDS.get(k.get("Tab") or "", "")
    have = {"NG": k.get("Ng"), "PBI": k.get("Pbi"), "WEB": k.get("Web")}
    entry = None
    if want and have.get(want):
        entry, out["Kind"] = have[want], want
    elif not want or not tab:
        for kind, v in have.items():
            if v:
                entry, out["Kind"] = v, kind
                break
    if not entry:
        if tab == "Mach2" or (not tab and k.get("Tab") == "Mach2"):
            out["State"], out["Severity"] = "old launcher", "INACTIVE"
        return out

    out["Known"] = True
    out["Status"] = str(entry.get("Status") or "")
    out["Error"] = str(entry.get("Error") or "")
    out["Installed"] = bool(entry.get("Installed"))
    out["Old"] = bool(entry.get("OldLauncher")) if out["Kind"] == "NG" else bool(entry.get("LegacyLauncher")) if out["Kind"] == "PBI" else False
    out["Instances"] = list(entry.get("Instances") or [])
    if not out["Installed"]:
        out["State"] = "old launcher" if out["Old"] else "no launcher"
        out["Severity"] = "INACTIVE"
        return out
    if not out["Instances"]:
        out["State"], out["Severity"] = "not started", "WARNING"
        return out

    first = out["Instances"][0]
    screen_of = lambda i: str(i.get("Screen") or i.get("Instance") or "")  # noqa: E731
    out["State"] = " ".join(f"{screen_of(i)}:{i.get('State')}" for i in out["Instances"]) if len(out["Instances"]) > 1 else str(first.get("State") or "")
    out["For"] = format_minutes(first.get("StateMinutes"))
    out["Version"] = str(first.get("Version") or "")
    if out["Kind"] == "PBI":
        out["Account"] = str(first.get("SignedInAs") or "")
    elif out["Kind"] == "NG":
        pct = first.get("ScreenWhitePercent")
        if pct is None:
            pct = first.get("PageWhitePercent")
        if pct is not None and str(pct) != "":
            out["Screen"] = f"{pct}%"
    st = str(first.get("State") or "")
    if st in ("SHOWING", "BROWSING"):
        out["Severity"] = "OK"
    elif st in ("LOADING", "SIGNING_IN", "LAUNCHING", "STARTING", "RESTARTING_PC"):
        out["Severity"] = "UNKNOWN"
    elif st in ("SIGNIN_BLOCKED", "ERROR", "STOPPED"):
        out["Severity"] = "CRITICAL"
    else:
        out["Severity"] = "WARNING"
    if str(first.get("HostStatus") or "") == "LAUNCHER_STALE":
        out["State"] = "(" + out["State"] + ")"
        out["Severity"] = "CRITICAL"
    return out


def _row(label: str, value, sev: str = "", wrap: bool = False) -> dict:
    return {"Label": label, "Value": "" if value is None else str(value), "Sev": sev, "Wrap": wrap}


def _ago(iso) -> str:
    t = parse_utc(iso)
    return format_minutes((utcnow() - t).total_seconds() / 60) if t else ""


def kiosk_detail(k: dict) -> list[dict]:
    """The details card: sections of label/value rows, coloured by severity name."""
    sections = []
    rows = []
    r0 = k.get("StatusRow")
    if r0:
        when = parse_utc(r0.get("EventTimeUtc"))
        rows.append(_row("Seen", when.astimezone().strftime("%a %d %b %H:%M") if when else ""))
        if r0.get("Detail"):
            rows.append(_row("Detail", r0["Detail"], "DIM", True))
        boot = parse_utc(r0.get("BootTimeUtc"))
        if boot:
            rows.append(_row("PC up since", f"{boot.astimezone().strftime('%d %b %H:%M')}  ({format_minutes((utcnow() - boot).total_seconds() / 60)})"))
    else:
        rows.append(_row("Seen", "no status row yet", "WARNING"))
    rows.append(_row("Reboots 24h", f"{k['Reboots24']}" + (f" ({k['Script24']} by the watchdog)" if k["Script24"] else "")))
    rows.append(_row("Screen events", f"{k['Episodes24']} in 24h"))
    sections.append({"Title": "LAST SCAN", "Rows": rows})

    if k["HasWatchdog"] and r0:
        wd = {"TRUE": "running", "FALSE": "DEAD"}.get(r0.get("WatchdogRunning") or "", "unknown")
        rows = [_row("State", wd, "CRITICAL" if wd == "DEAD" else "OK"), _row("Version", r0.get("AgentVersion") or "")]
        if r0.get("MinutesSinceLastLog"):
            try:
                rows.append(_row("Last wrote", f"{format_minutes(float(r0['MinutesSinceLastLog']))} ago"))
            except ValueError:
                pass
        sections.append({"Title": "WATCHDOG", "Rows": rows})

    kinds = [kk for kk, v in (("NG", k.get("Ng")), ("PBI", k.get("Pbi")), ("WEB", k.get("Web"))) if v]
    if not kinds and k.get("Tab") in TAB_KINDS:
        kinds = [TAB_KINDS[k["Tab"]]]
    screens = k.get("Screens") or []
    if len(screens) > 1 or len(kinds) > 1:
        sections.append({"Title": "SCREENS", "Rows": [
            _row(s["Screen"], f"{LAUNCHER_NAMES[KIND_OF_SCREEN_LAUNCHER[s['Launcher']]]}  -  {s['State']}", severity(s["HostStatus"]))
            for s in screens]})
    for kind in kinds:
        rows = []
        lv = launcher_view(k, KIND_TABS[kind])
        if not lv["Known"]:
            why = "not installed - this kiosk still runs Mach2Launcher.exe and the MWST watchdog" if kind == "NG" else "nothing was read at the last scan"
            rows.append(_row("Installed", why, "DIM", True))
        elif not lv["Installed"]:
            if lv["Old"]:
                why = "no - still on the old launcher"
            elif any(KIND_OF_SCREEN_LAUNCHER[s["Launcher"]] == kind for s in screens):
                why = "no - config written, launcher not installed"
            else:
                why = "no"
            rows.append(_row("Installed", why, "WARNING", True))
        elif not lv["Instances"]:
            rows.append(_row("State", "installed, never started", "WARNING"))
        for i in lv["Instances"]:
            label = str(i.get("Screen") or i.get("Instance") or "")
            rows.append(_row(label, f"{i.get('State')} for {format_minutes(i.get('StateMinutes'))}", severity(str(i.get("HostStatus") or ""))))
            if i.get("Detail"):
                rows.append(_row("", i["Detail"], "DIM", True))
            if kind == "PBI":
                rows.append(_row("Signed in as", i.get("SignedInAs") or "not seen yet", "CRITICAL" if k["Status"] == "WRONG_ACCOUNT" else "DIM"))
            elif kind == "NG":
                w = []
                if i.get("ScreenWhitePercent") not in (None, ""):
                    w.append(f"screen {i['ScreenWhitePercent']}%")
                if i.get("PageWhitePercent") not in (None, ""):
                    w.append(f"page {i['PageWhitePercent']}%")
                if w:
                    rows.append(_row("White", ", ".join(w), "DIM"))
                if i.get("Watchdog"):
                    rows.append(_row("Watchdog", "this screen is the watchdog", "DIM"))
                if i.get("LoopGuard") and str(i["LoopGuard"]) != "OFF":
                    rows.append(_row("Loop guard", i["LoopGuard"], "CRITICAL"))
                if i.get("PcRestarts"):
                    rows.append(_row("PC restarts", i["PcRestarts"], "DIM"))
            rows.append(_row("Version", f"v{i.get('Version') or ''}   Edge {i.get('Edge') or ''}", "DIM"))
            if kind == "WEB":
                counts = f"{_n(i.get('Reloads'))} reloads, {_n(i.get('BrowserStarts'))} browser starts"
            else:
                counts = f"{_n(i.get('Reloads'))} reloads, {_n(i.get('SignIns'))} sign-ins, {_n(i.get('BrowserStarts'))} browser starts"
            rows.append(_row("Counts", counts, "DIM"))
            if i.get("UpdatedUtc"):
                rows.append(_row("Status written", _ago(i["UpdatedUtc"]) + " ago", "DIM"))
            if i.get("LastError"):
                rows.append(_row("Last error", i["LastError"], "WARNING", True))
        if lv["Error"]:
            rows.append(_row("Could not read", lv["Error"], "WARNING", True))
        if lv["Installed"] and lv["Old"]:
            rows.append(_row("Old launcher", "still on this kiosk", "DIM"))
        sections.append({"Title": LAUNCHER_NAMES[kind].upper(), "Rows": rows})
    return sections


def _n(v) -> str:
    return "" if v is None else str(v)


def _version_tuple(text: str):
    if not re.match(r"^\d+(\.\d+){1,3}$", text.strip()):
        return None
    return tuple(int(p) for p in text.strip().split("."))


def kiosk_view(k: dict, day_keys: list[str]) -> dict:
    r0 = k.get("StatusRow")
    log_age = uptime = watchdog = agent = note = ""
    if r0:
        try:
            if r0.get("MinutesSinceLastLog"):
                log_age = f"{int(float(r0['MinutesSinceLastLog']))}m"
        except ValueError:
            pass
        if r0.get("UptimeHours"):
            try:
                h = float(r0["UptimeHours"])
                uptime = f"{int(h / 24)}d" if h >= 48 else f"{int(h)}h"
            except ValueError:
                pass
        elif r0.get("BootTimeUtc"):
            boot = parse_utc(r0["BootTimeUtc"])
            if boot:
                uptime = format_minutes((utcnow() - boot).total_seconds() / 60)
        watchdog = {"TRUE": "running", "FALSE": "DEAD"}.get(r0.get("WatchdogRunning") or "", "")
        agent = r0.get("AgentVersion") or ""
        note = r0.get("Detail") or ""
    reb = ""
    if k["Reboots24"] > 0:
        reb = str(k["Reboots24"])
    if k["Script24"] > 0:
        reb = f"{k['Reboots24']} ({k['Script24']})"

    launchers = {}
    for tab in ("Mach2", "PBI", "Web", "Other"):
        lv = launcher_view(k, "" if tab == "Other" else tab)
        launchers[tab] = {key: lv[key] for key in ("Kind", "Known", "Installed", "State", "For", "Account", "Version", "Screen", "Severity")}

    screens = [{"Screen": s["Screen"], "Kind": KIND_OF_SCREEN_LAUNCHER[s["Launcher"]],
                "Name": LAUNCHER_NAMES[KIND_OF_SCREEN_LAUNCHER[s["Launcher"]]], "State": s["State"],
                "Severity": severity(s["HostStatus"])} for s in k.get("Screens") or []]

    installed = [v for v in (k.get("Ng"), k.get("Pbi"), k.get("Web")) if v and v.get("Installed")]
    ver = (r0 or {}).get("AgentVersion") or ""
    message_ok = k.get("Tab") == "Mach2" or bool(k.get("Ng"))
    message_why = "" if message_ok else "Only Mach2 kiosks have a watchdog to show a message"
    if message_ok and ver and not is_ng_version(ver):
        v = _version_tuple(ver)
        if v is None or v < (7, 0):
            message_ok = False
            message_why = f"runs watchdog v{ver}; messages need V7.0 or later, or Mach2 Launcher NG"

    return {
        "Host": k["Host"], "Location": k["Location"], "Type": k["Type"], "Tab": k["Tab"], "Tabs": list(k["Tabs"]),
        "Status": k["Status"], "Severity": severity(k["Status"]), "Attention": needs_attention(k),
        "Rank": STATUS_RANK.get(k["Status"], 8),
        "LogAge": log_age, "Uptime": uptime, "Watchdog": watchdog, "Agent": agent, "Reboots": reb,
        "Days": [int(k["Days"].get(d, 0)) for d in day_keys], "Note": note,
        "Launchers": launchers, "Screens": screens, "Detail": kiosk_detail(k),
        "HasLauncher": bool(installed), "MessageOk": message_ok, "MessageWhy": message_why,
        "Reboots24": int(k["Reboots24"]), "Script24": int(k["Script24"]), "Episodes24": int(k["Episodes24"]),
        "DeployNotes": deploy_notes(k),
    }


def deploy_notes(k: dict) -> dict:
    """What each kiosk runs, as the deploy list shows it, per product."""
    out = {}
    ver = (k.get("StatusRow") or {}).get("AgentVersion") or ""
    screens = k.get("Screens") or []
    for product in ("NG", "PBI", "WEB", "WATCHDOG"):
        tab = {"NG": "Mach2", "PBI": "PBI", "WEB": "*"}.get(product, "Mach2")
        lv = launcher_view(k, "Web" if tab == "*" else tab)
        bits = []
        if lv["Installed"]:
            bits.append(f"{LAUNCHER_NAMES[lv['Kind']]} v{lv['Version']}")
        elif lv["State"]:
            bits.append(lv["State"])
        if len(screens) > 1 or (screens and tab == "*"):
            bits.append(", ".join(f"{s['Screen']} {LAUNCHER_NAMES[KIND_OF_SCREEN_LAUNCHER[s['Launcher']]]}" for s in screens))
        if product == "WATCHDOG" and ver:
            bits.append(f"watchdog v{ver}")
        elif ver and not lv["Installed"]:
            bits.append(f"agent v{ver}")
        out[product] = ", ".join(bits)
    return out


def fleet_view(state: dict | None) -> dict:
    """The whole fleet as the page needs it. Freshness is left out: it changes
    by the minute, so it is worked out when asked."""
    if not state or not state.get("Ok"):
        return {"Ok": False, "Error": (state or {}).get("Error") or "not read yet", "Kiosks": []}
    hosts = state["Hosts"]
    kiosks = [kiosk_view(k, state["DayKeys"]) for k in hosts]
    attention = [k for k in hosts if needs_attention(k)]
    tabs = {}
    for t in ("Mach2", "PBI", "Web", "Other"):
        lst = [k for k in hosts if k["Tab"] == t or t in k["Tabs"]]
        tabs[t] = {"Count": len(lst), "Attention": sum(1 for k in lst if needs_attention(k))}
    totals: dict[str, int] = {}
    for k in hosts:
        for d, n in k["Days"].items():
            totals[d] = totals.get(d, 0) + n
    chart = []
    for d in state["DayKeys"]:
        day = datetime.strptime(d, "%Y-%m-%d")
        chart.append({"Day": d, "Label": day.strftime("%a"), "Long": day.strftime("%a %d %b"), "Count": int(totals.get(d, 0))})
    sc = state.get("Sidecar")
    collector = None
    if sc:
        collector = {"Took": int(sc.get("DurationSeconds") or 0), "Reachable": sc.get("Reachable"), "Hosts": sc.get("Hosts"),
                     "NewEvents": sc.get("NewEvents"), "Version": str(sc.get("CollectorVersion") or ""), "Runner": str(sc.get("Runner") or "")}
    return {
        "Ok": True, "Error": None, "Total": len(hosts), "Attention": len(attention),
        "Critical": sum(1 for k in attention if severity(k["Status"]) == "CRITICAL"),
        "Inactive": sum(1 for k in hosts if k["Status"] == "INACTIVE"),
        "Reboots24": sum(k["Reboots24"] for k in hosts), "Script24": sum(k["Script24"] for k in hosts),
        "Episodes24": sum(k["Episodes24"] for k in hosts),
        "Launchers": {
            "Ng": sum(1 for k in hosts if k.get("StatusRow") and is_ng_version(k["StatusRow"].get("AgentVersion"))),
            "Pbi": sum(1 for k in hosts if k.get("Pbi") and k["Pbi"].get("Installed")),
            "Web": sum(1 for k in hosts if k.get("Web") and k["Web"].get("Installed")),
        },
        "Tabs": tabs, "Chart": chart, "DayKeys": list(state["DayKeys"]), "Collector": collector,
        "RowCount": state["RowCount"], "File": Path(state["Path"]).name, "Kiosks": kiosks,
    }
