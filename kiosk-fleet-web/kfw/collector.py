"""The fleet collector: one run is one scan of the fleet, merged into one CSV.

A port of Collect-MWSTFleet.ps1 (collector v6.2), unchanged in what it writes,
so the Power BI report and anything else reading MWST_FleetEvents.csv see no
difference. For every kiosk on the list it:

  - checks the kiosk is reachable (ping, falling back to SMB on 445)
  - reads the watchdog's event ledger (mwst_events*.csv) over the admin share,
    including the Windows System-log records (1074, 6008, 6005) each kiosk's
    agent copies into it
  - checks how recently mwst.log was written, to tell whether the watchdog is alive
  - reads the launchers' status files (PBI Launcher, Web Launcher, Mach2 Launcher NG)

and merges it all into a long fact table with one row per event. Every row
has a stable EventId, so reading the same ledger again never duplicates.

Why no reboot is missed, and why one boot is one reboot however many records
describe it, is explained at update_reboot_flags. Count rows with
IsScriptReboot = TRUE (reboots the watchdog caused) or IsCanonicalReboot = TRUE
(every reboot), never EventType rows directly.

The CSV is a cache of durable sources: rewritten in full (atomically) when
something changed, re-derivable from the kiosks. Two copies are kept - the
published one (KFW_PUBLISH_CSV, e.g. a synced SharePoint folder) and the local
one in the data folder - and each run merges both, so either restores the other.

Reading the kiosks' System log across the network (-RemoteEventLog in the
PowerShell collector) is not done here: it was off by default, and the agents'
own copies in the ledger carry the same records with the same EventIds.
"""
from __future__ import annotations

import argparse
import csv
import fcntl
import getpass
import io
import json
import os
import re
import socket
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

from .config import Settings, load_settings
from .kiosk_fs import KioskError, KioskFS
from .kiosklist import Kiosk, import_kiosk_list, is_power_bi, is_web
from .launchers import STATE_RANK, is_ng_version, ng_observation, pbi_observation, read_agent_ledger, sidecar_entry, web_observation
from .remote import test_host_reachable
from .timeutil import local_date, local_iso, parse_utc, utc_iso, utcnow

COLLECTOR_VERSION = "6.2-py"

COLUMNS = [
    "EventId", "EventTimeUtc", "EventTimeLocal", "EventDate",
    "Host", "Location", "KioskType", "RestartGroup",
    "EventCategory", "EventType", "Severity", "Outcome",
    "IsCanonicalReboot", "IsScriptReboot", "RebootTrigger",
    "WhitePercent", "StreakChecks", "DurationSeconds",
    "Reachable", "WatchdogRunning", "MinutesSinceLastLog",
    "AgentVersion", "BootTimeUtc", "UptimeHours",
    "Source", "ScanId", "CollectedUtc", "Detail",
]
COLUMN_SET = set(COLUMNS)

CATEGORY_BY_TYPE = {
    "RESTART_TRIGGERED": "REBOOT", "RESTART_CONFIRMED": "REBOOT", "RESTART_FAILED": "REBOOT",
    "REBOOT_SCRIPT": "REBOOT", "REBOOT_EXTERNAL": "REBOOT", "REBOOT_UNEXPECTED": "REBOOT", "BOOT": "REBOOT",
    "WHITE_EPISODE_START": "SCREEN", "WHITE_EPISODE_END": "SCREEN",
    "LOWWHITE_EPISODE_START": "SCREEN", "LOWWHITE_EPISODE_END": "SCREEN",
    "AGENT_START": "AGENT", "AGENT_STOP": "AGENT", "AGENT_ERROR": "AGENT", "AGENT_RECOVERED": "AGENT",
    "LOOP_GUARD_ENGAGED": "AGENT", "LOOP_GUARD_RELEASED": "AGENT",
    "MESSAGE_SHOWN": "AGENT", "MESSAGE_CLOSED": "AGENT", "MESSAGE_EXPIRED": "AGENT", "MESSAGE_REJECTED": "AGENT",
    "HOST_STATUS": "STATUS", "COLLECTOR_RUN": "COLLECTOR",
}

GUID_RX = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


# ---------------------------------------------------------------------------
# Value formatting: culture-invariant, TRUE/FALSE, "" for not applicable.
# ---------------------------------------------------------------------------
def fmt_number(value, decimals: int = 2) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        if not value.strip():
            return ""
        try:
            d = float(value.strip())
        except ValueError:
            return ""
    else:
        try:
            d = float(value)
        except (TypeError, ValueError):
            return ""
    r = round(d, decimals)
    if r == 0:
        return "0"  # never "-0"
    s = repr(r)
    return s[:-2] if s.endswith(".0") else s


def fmt_bool(value) -> str:
    if value is None:
        return ""
    return "TRUE" if value else "FALSE"


def new_row(values: dict) -> dict:
    """The only way a row is made: every column, unknown names refused, the
    category and the local-time columns derived."""
    row = {c: "" for c in COLUMNS}
    for k, v in values.items():
        if k not in COLUMN_SET:
            raise KeyError(f"new_row: unknown column '{k}'")
        row[k] = "" if v is None else str(v)
    if not row["EventCategory"] and row["EventType"] in CATEGORY_BY_TYPE:
        row["EventCategory"] = CATEGORY_BY_TYPE[row["EventType"]]
    if not row["IsCanonicalReboot"]:
        row["IsCanonicalReboot"] = "FALSE"
    if not row["IsScriptReboot"]:
        row["IsScriptReboot"] = "FALSE"
    # Local time always from UTC on this machine, so every row agrees on DST.
    t = parse_utc(row["EventTimeUtc"])
    if t:
        row["EventTimeLocal"] = local_iso(t)
        row["EventDate"] = local_date(t)
    detail = re.sub(r"[\r\n\t]+", " ", row["Detail"]).strip()
    row["Detail"] = detail[:1000]
    return row


# ---------------------------------------------------------------------------
# The CSV
# ---------------------------------------------------------------------------
@dataclass
class CsvRead:
    exists: bool = False
    error: str | None = None
    rows: list[dict] = field(default_factory=list)


def read_fleet_csv(path: Path | None) -> CsvRead:
    """A file that exists but is not one of ours (someone saved it from Excel,
    with semicolons) comes back with .error set, and must then be left alone
    rather than overwritten with a copy missing its history."""
    result = CsvRead()
    if not path or not path.exists():
        return result
    result.exists = True
    try:
        text = path.read_bytes().decode("utf-8-sig")
        if not text.strip():
            return result
        first = re.split(r"\r?\n", text, maxsplit=1)[0]
        header = [h.strip().strip('"') for h in first.split(",")]
        if "EventId" not in header or "EventTimeUtc" not in header or "EventType" not in header:
            result.error = f"Unrecognised layout (first line: '{first[:80]}'). Was it saved from Excel?"
            return result
        same = header == COLUMNS
        for r in csv.DictReader(io.StringIO(text)):
            if not (r.get("EventId") or "").strip():
                continue
            if same:
                result.rows.append({c: r.get(c) or "" for c in COLUMNS})
            else:
                result.rows.append(new_row({k: v for k, v in r.items() if k in COLUMN_SET}))
    except (OSError, UnicodeDecodeError, csv.Error) as e:
        result.error = str(e)
    return result


def _atomic_write(path: Path, data: bytes, attempts: int = 6) -> None:
    tmp = path.parent / f"~{path.stem}.{uuid.uuid4().hex[:8]}.tmp"
    try:
        tmp.write_bytes(data)
        last = None
        for i in range(1, attempts + 1):
            try:
                os.replace(tmp, path)
                return
            except OSError as e:
                last = e
                time.sleep(min(2 * i, 10) if attempts > 3 else 0.2 * i)
        # Some sync clients refuse a replace outright. Not atomic, but better than not publishing.
        try:
            path.write_bytes(data)
        except OSError as e:
            raise OSError(f"could not replace '{path}': {last} / {e}") from e
    finally:
        tmp.unlink(missing_ok=True)


def write_fleet_csv(rows: list[dict], path: Path) -> None:
    if not path.parent.exists():
        raise OSError(f"folder does not exist: {path.parent}")
    buf = io.StringIO()
    w = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
    w.writerow(COLUMNS)
    for r in rows:
        w.writerow([r.get(c, "") for c in COLUMNS])
    _atomic_write(path, b"\xef\xbb\xbf" + buf.getvalue().encode("utf-8"))


def write_status_sidecar(csv_path: Path, values: dict) -> None:
    """When the collector last RAN, which the CSV cannot say: it is only
    rewritten when something changed. Written on every run."""
    path = csv_path.with_suffix(".status.json")
    if not path.parent.exists():
        return
    try:
        _atomic_write(path, b"\xef\xbb\xbf" + json.dumps(values, separators=(",", ":")).encode("utf-8"), attempts=3)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Ledger rows and Windows events
# ---------------------------------------------------------------------------
def convert_reboot_event(record: dict, host: str, scan_id: str, collected: str) -> dict | None:
    """A Windows System-log record (1074, 6008, 6005) as a row."""
    utc = record["TimeCreated"]
    values = {
        "EventId": f"EVT-{host}-{record.get('RecordId')}-{utc.strftime('%Y%m%d%H%M%S')}",
        "EventTimeUtc": utc_iso(utc), "Host": host, "Source": "EventLog", "ScanId": scan_id, "CollectedUtc": collected,
    }
    props = [("" if p is None else str(p)) for p in record.get("Properties") or []]
    rid, provider = record.get("Id"), record.get("ProviderName")

    if rid == 1074 and provider == "User32":
        # "The process %1 has initiated the %5 of computer %2 on behalf of
        #  user %7 for the following reason: %3 ... Comment: %6"
        get = lambda i: props[i] if len(props) > i else ""  # noqa: E731
        process, reason, kind_txt, comment, user = get(0), get(2), get(4), get(5), get(6)
        joined = " | ".join(props)
        kind = token = None
        m = re.search(r"MWST-WATCHDOG\s+(LOWWHITE|WHITE|BROWSER)\b(?:\s+id=([0-9a-fA-F]{8}))?", joined, re.IGNORECASE)
        if m:
            kind = m.group(1).upper()
            token = m.group(2).lower() if m.group(2) else None
        elif re.search(r"KPI screen has been below", joined, re.IGNORECASE):
            kind = "LOWWHITE"
        elif re.search(r"KPI screen has been white", joined, re.IGNORECASE):
            kind = "WHITE"
        detail = f"Process={process}; User={user}; Type={kind_txt}; Reason={reason}; Comment={comment}"
        if kind:
            values.update(EventType="REBOOT_SCRIPT", Severity="CRITICAL", Outcome="REBOOT", RebootTrigger="WATCHDOG_" + kind,
                          Detail=f"id={token}; {detail}" if token else f"legacy-agent; {detail}")
        else:
            values.update(EventType="REBOOT_EXTERNAL", Severity="WARNING", Outcome="REBOOT", RebootTrigger="EXTERNAL", Detail=detail)
    elif rid == 6008 and provider == "EventLog":
        msg = record.get("Message") or ("Previous shutdown was unexpected. " + " ".join(props))
        values.update(EventType="REBOOT_UNEXPECTED", Severity="CRITICAL", Outcome="UNEXPECTED", RebootTrigger="UNEXPECTED", Detail=msg)
    elif rid == 6005 and provider == "EventLog":
        values.update(EventType="BOOT", Severity="INFO", Outcome="BOOT", Detail="System booted (event log service started).")
    else:
        return None
    return new_row(values)


def convert_ledger_winevent(row: dict, host: str, scan_id: str, collected: str) -> dict | None:
    """A System-log record the kiosk's agent copied into its ledger verbatim,
    rebuilt and classified by the same code as one read over the network."""
    try:
        payload = json.loads(row.get("Detail") or "")
    except ValueError:
        return None
    if not isinstance(payload, dict) or not payload.get("Id"):
        return None
    t = parse_utc(row.get("EventTimeUtc"))
    if not t:
        return None
    props = payload.get("Props")
    if props is None:
        props = []
    elif not isinstance(props, list):
        props = [props]
    try:
        rid = int(payload["Id"])
    except (TypeError, ValueError):
        return None
    record = {"Id": rid, "ProviderName": str(payload.get("Provider") or ""), "RecordId": payload.get("RecordId"),
              "TimeCreated": t, "Properties": props, "Message": str(payload.get("Msg") or "")}
    return convert_reboot_event(record, host, scan_id, collected)


def convert_ledger_row(row: dict, host: str, scan_id: str, collected: str) -> dict | None:
    etype = (row.get("EventType") or "").strip().upper()
    if etype == "WINEVENT":
        return convert_ledger_winevent(row, host, scan_id, collected)
    eid = row.get("EventId") or ""
    if not GUID_RX.match(eid):
        return None
    t = parse_utc(row.get("EventTimeUtc"))
    if not t or not etype:
        return None
    detail = row.get("Detail") or ""
    trigger = ""
    if etype in ("RESTART_TRIGGERED", "RESTART_CONFIRMED", "RESTART_FAILED"):
        m = re.match(r"^(?:Kind=)?(LOWWHITE|WHITE|BROWSER)\b", detail, re.IGNORECASE)
        trigger = "WATCHDOG_" + m.group(1).upper() if m else "WATCHDOG"
    boot = parse_utc(row.get("BootTimeUtc"))
    return new_row({
        "EventId": eid.lower(), "EventTimeUtc": utc_iso(t), "Host": host, "EventType": etype,
        "Severity": (row.get("Severity") or "").strip().upper(), "Outcome": (row.get("Outcome") or "").strip().upper(),
        "RebootTrigger": trigger, "WhitePercent": fmt_number(row.get("WhitePercent"), 2),
        "StreakChecks": fmt_number(row.get("StreakChecks"), 0), "DurationSeconds": fmt_number(row.get("DurationSeconds"), 0),
        "AgentVersion": (row.get("AgentVersion") or "").strip(), "BootTimeUtc": utc_iso(boot) if boot else "",
        "Source": "Agent", "ScanId": scan_id, "CollectedUtc": collected, "Detail": detail,
    })


# ---------------------------------------------------------------------------
# The upgrade cutoff
# ---------------------------------------------------------------------------
def _parse_version(text: str):
    if not re.match(r"^\d+(\.\d+){1,3}$", text.strip()):
        return None
    return tuple(int(p) for p in text.strip().split("."))


def trusted_agent_version(version: str, trusted_from: str) -> bool:
    if not (version or "").strip():
        return False
    if is_ng_version(version):
        return True
    v = _parse_version(version)
    if v is None:
        return False
    m = _parse_version(trusted_from)
    if m is None:
        return True
    n = max(len(v), len(m))
    return v + (0,) * (n - len(v)) >= m + (0,) * (n - len(m))


def upgrade_cutoffs(rows, trusted_from: str) -> dict[str, str]:
    """The moment each kiosk started running a trusted agent: its earliest
    AGENT_START at that version. Its rows from before then are dropped - the
    previous watchdog could reboot a kiosk every couple of minutes."""
    out: dict[str, str] = {}
    for r in rows:
        if r["EventType"] != "AGENT_START" or not r["Host"]:
            continue
        if not trusted_agent_version(r["AgentVersion"], trusted_from):
            continue
        if r["Host"] not in out or r["EventTimeUtc"] < out[r["Host"]]:
            out[r["Host"]] = r["EventTimeUtc"]
    return out


# ---------------------------------------------------------------------------
# Reboot reconciliation
# ---------------------------------------------------------------------------
def id_token(text: str) -> str | None:
    m = re.search(r"\bid=([0-9a-fA-F]{8})\b", text or "", re.IGNORECASE)
    return m.group(1).lower() if m else None


def update_reboot_flags(rows: list[dict], recompute_from: datetime, new_ids: set[str]) -> int:
    """Decides, per host, which row is THE row for each physical reboot.

    The unit is the boot interval: between two consecutive boots (6005) there
    was exactly one shutdown, however many records describe it. Windows alone
    writes two 1074s for one restart from the Start menu, and a feature update
    a burst of them. Each event-log record is assigned to the boot it led to,
    and within one interval exactly one wins:

      REBOOT_SCRIPT      first choice - the watchdog's shutdown.exe call as
                         Windows logged it, unless the agent later reported
                         that reboot as failed
      REBOOT_EXTERNAL    next - update, operator, other process
      REBOOT_UNEXPECTED  last - power loss or hard hang; a 6008 is written
                         just after the boot that follows, so it belongs to
                         the interval ending at that boot
    Ties go to the latest record. Agent rows:

      RESTART_TRIGGERED  counts only when no REBOOT_SCRIPT corroborates it
                         (matched by the id= token; by time for the previous
                         agent, which had none)
      RESTART_CONFIRMED  never counts; it corroborates
      RESTART_FAILED     never counts; no reboot happened

    And the safety net: a BOOT that nothing explains counts, as UNEXPLAINED -
    provided the previous boot is in the data too.

    Returns the number of field changes.
    """
    changed = 0
    new_lower = {i.lower() for i in new_ids}
    by_host: dict[str, list[tuple[dict, datetime]]] = {}
    for r in rows:
        if r["EventCategory"] != "REBOOT" or not r["Host"]:
            continue
        t = parse_utc(r["EventTimeUtc"])
        if not t:
            continue
        by_host.setdefault(r["Host"], []).append((r, t))

    priority = {"REBOOT_SCRIPT": 1, "REBOOT_EXTERNAL": 2, "REBOOT_UNEXPECTED": 3}
    for items in by_host.values():
        items.sort(key=lambda x: x[1])

        failed: set[str] = set()
        for r, _ in items:
            if r["EventType"] == "RESTART_FAILED":
                m = re.search(r"TriggerEventId=([0-9a-fA-F-]{36})", r["Detail"], re.IGNORECASE)
                if m:
                    failed.add(m.group(1).lower())

        boots = [t for r, t in items if r["EventType"] == "BOOT"]
        decision: dict[str, bool] = {}
        winners: dict[str, tuple[dict, datetime]] = {}
        explained: set[str] = set()

        for r, t in items:
            etype = r["EventType"]
            if etype not in priority:
                continue
            if etype == "REBOOT_SCRIPT":
                token = id_token(r["Detail"])
                if token and any(f.startswith(token) for f in failed):
                    decision[r["EventId"]] = False
                    continue
            key = None
            if etype == "REBOOT_UNEXPECTED":
                near = sorted((b for b in boots if abs((b - t).total_seconds()) <= 1800), key=lambda b: abs((b - t).total_seconds()))
                if near:
                    key = f"b{near[0].timestamp()}"
            if key is None:
                after = [b for b in boots if b > t]
                key = f"b{after[0].timestamp()}" if after else "open"
            explained.add(key)
            decision[r["EventId"]] = False
            cur = winners.get(key)
            if (cur is None or priority[etype] < priority[cur[0]["EventType"]]
                    or (priority[etype] == priority[cur[0]["EventType"]] and t >= cur[1])):
                winners[key] = (r, t)
        for r, _ in winners.values():
            decision[r["EventId"]] = True

        script_events = [(r, t) for r, t in items if r["EventType"] == "REBOOT_SCRIPT"]
        prev_boot = None
        for r, t in items:
            recompute = t >= recompute_from or r["EventId"].lower() in new_lower or not r["IsCanonicalReboot"]
            if recompute:
                etype = r["EventType"]
                trigger = r["RebootTrigger"]
                canonical = False
                if r["EventId"] in decision:
                    canonical = decision[r["EventId"]]
                elif etype == "RESTART_TRIGGERED":
                    rid = r["EventId"].lower()
                    if rid in failed:
                        canonical = False
                    else:
                        corroborated = False
                        for s, st in script_events:
                            token = id_token(s["Detail"])
                            if token:
                                if rid.startswith(token):
                                    corroborated = True
                                    break
                            elif abs((st - t).total_seconds()) <= 900:
                                corroborated = True
                                break
                        canonical = not corroborated
                elif etype == "BOOT":
                    is_explained = f"b{t.timestamp()}" in explained
                    if not is_explained:
                        for x, xt in items:
                            if x["EventType"] != "RESTART_TRIGGERED" or x["EventId"].lower() in failed:
                                continue
                            if xt <= t and (prev_boot is None or xt > prev_boot):
                                is_explained = True
                                break
                    canonical = (not is_explained) and prev_boot is not None
                    trigger = "UNEXPLAINED" if canonical else ""

                canon_text = "TRUE" if canonical else "FALSE"
                script_text = "TRUE" if canonical and trigger.upper().startswith("WATCHDOG") else "FALSE"
                if r["IsCanonicalReboot"] != canon_text:
                    r["IsCanonicalReboot"] = canon_text
                    changed += 1
                if r["IsScriptReboot"] != script_text:
                    r["IsScriptReboot"] = script_text
                    changed += 1
                if r["RebootTrigger"] != trigger:
                    r["RebootTrigger"] = trigger
                    changed += 1
            if r["EventType"] == "BOOT":
                prev_boot = t
    return changed


# ---------------------------------------------------------------------------
# Host status
# ---------------------------------------------------------------------------
@dataclass
class Obs:
    reachable: bool = False
    method: str | None = None
    share_ok: bool | None = None
    log_found: bool | None = None
    ledger_found: bool | None = None
    ledger_files: int = 0
    log_age_minutes: float | None = None
    event_log_ok: bool | None = None
    loop_guard: bool = False
    win_event_rows: int = 0
    pre_upgrade: int = 0
    agent_version: str = ""
    ledger_boot: datetime | None = None
    event_boot: datetime | None = None
    new_events: int = 0
    is_pbi: bool = False
    is_web: bool = False
    watchdog_found: bool = False
    pbi: dict | None = None
    web: dict | None = None
    ng: dict | None = None
    notes: list[str] = field(default_factory=list)


def host_status(kiosk: Kiosk, obs: Obs, stale_minutes: int) -> tuple[str, str]:
    """One status per host per scan, worst condition first:

      OFFLINE               no ping and no SMB                   CRITICAL
      NO_ACCESS             reachable, admin share not readable  WARNING
      NO_AGENT              watchdog expected, no trace of it    CRITICAL
      STALE                 mwst.log not written recently        CRITICAL
      LOOP_GUARD            has stopped restarting a screen      CRITICAL
      (a launcher's status)
      AGENT_OUTDATED        running, but no ledger (old agent)   WARNING
      EVENTLOG_UNAVAILABLE  one reboot witness missing           WARNING
      OK
    """
    if not obs.reachable:
        return "OFFLINE", "CRITICAL"
    launchers = [l for l in (obs.pbi, obs.web, obs.ng) if l and l.get("Status")]
    worst = None
    for l in launchers:
        rank = STATE_RANK.get(str(l["Status"]), 50)
        if worst is None or rank < worst[2]:
            worst = (l["Status"], l["Severity"], rank)

    if kiosk.runs_watchdog or obs.watchdog_found:
        if obs.share_ok is not True:
            return "NO_ACCESS", "WARNING"
        if not obs.log_found and not obs.ledger_found:
            return "NO_AGENT", "CRITICAL"
        if obs.log_age_minutes is None or obs.log_age_minutes > stale_minutes:
            return "STALE", "CRITICAL"
        if obs.loop_guard:
            return "LOOP_GUARD", "CRITICAL"
        if worst and worst[0] != "OK":
            return worst[0], worst[1]
        if not obs.ledger_found:
            return "AGENT_OUTDATED", "WARNING"
    elif obs.is_pbi or obs.is_web or launchers:
        if obs.share_ok is False:
            return "NO_ACCESS", "WARNING"
        if worst:
            return worst[0], worst[1]
    if obs.event_log_ok is False:
        return "EVENTLOG_UNAVAILABLE", "WARNING"
    return "OK", "INFO"


def status_signature(row: dict) -> str:
    """What counts as "the status changed": not the values that move on every scan."""
    m = re.search(r"eventlog=(ok|FAIL)", row["Detail"], re.IGNORECASE)
    ev = m.group(1) if m else ""
    return "|".join([row["Outcome"], row["Reachable"], row["WatchdogRunning"], row["AgentVersion"], row["BootTimeUtc"], ev])


def status_row_needed(row: dict, previous: dict | None, now: datetime, keepalive_hours: int) -> bool:
    if not previous:
        return True
    prev = parse_utc(previous["EventTimeUtc"])
    fresh = prev is not None and (now - prev).total_seconds() / 3600 < keepalive_hours
    return not (fresh and status_signature(previous) == status_signature(row))


# ---------------------------------------------------------------------------
# Reading the kiosks, several at once
# ---------------------------------------------------------------------------
@dataclass
class Fetch:
    host: str
    reachable: bool = False
    method: str | None = None
    share_ok: bool | None = None
    log_found: bool | None = None
    log_age_minutes: float | None = None
    ledger: dict | None = None
    ng: dict | None = None
    pbi: dict | None = None
    web: dict | None = None
    pbi_share_ok: bool | None = None
    notes: list[str] = field(default_factory=list)
    fatal: str | None = None
    timed_out: bool = False
    started: float | None = None
    seconds: float = 0.0


def fetch_kiosk(f: Fetch, kiosk: Kiosk, fs: KioskFS, settings: Settings, now: datetime) -> None:
    """Only reading happens here; what the rows mean is decided later, in list order."""
    f.started = time.monotonic()
    try:
        h = f.host
        reach = test_host_reachable(h, settings)
        f.reachable, f.method = reach.ok, reach.method
        if not reach.ok:
            f.notes.append(reach.error or "unreachable")
            return
        root = fs.root(h)
        folder = fs.public_docs(h)
        try:
            fs.backend.connect(h, settings)
            f.pbi_share_ok = (root / "Users").is_dir()
            if f.pbi_share_ok:
                f.pbi = pbi_observation(root, now, settings.launcher_stale_minutes, h)
                if f.pbi["Error"]:
                    f.notes.append(f"PBI Launcher: {f.pbi['Error']}")
                f.web = web_observation(root, now, settings.launcher_stale_minutes, h)
                if f.web["Error"]:
                    f.notes.append(f"Web Launcher: {f.web['Error']}")
            elif is_power_bi(kiosk.type) or is_web(kiosk.type):
                f.notes.append(f"Cannot open {root}")

            # Mach2 Launcher NG, where installed - it is the watchdog as well,
            # so its ledger is read even on a kiosk the list calls Power BI.
            if folder.is_dir():
                f.ng = ng_observation(folder, now, settings.launcher_stale_minutes)
                if f.ng["Error"]:
                    f.notes.append(f"Launcher: {f.ng['Error']}")

            if kiosk.runs_watchdog or (f.ng and f.ng["Installed"]):
                f.share_ok = folder.is_dir()
                if not f.share_ok:
                    f.notes.append(f"Cannot open {folder}")
                else:
                    log = folder / "mwst.log"
                    mt = log.mtime()
                    f.log_found = mt is not None
                    if mt:
                        f.log_age_minutes = (now - mt).total_seconds() / 60.0
                    f.ledger = read_agent_ledger(folder)
                    f.notes.extend(f.ledger["Errors"])
        except (KioskError, OSError) as e:
            f.share_ok = False
            f.pbi_share_ok = False
            f.notes.append(f"Share: {e}")
    except Exception as e:  # noqa: BLE001 - one kiosk must never stop a scan
        f.fatal = str(e)
    finally:
        f.seconds = round(time.monotonic() - (f.started or time.monotonic()), 1)


def fetch_all(kiosks: list[Kiosk], fs: KioskFS, settings: Settings, now: datetime, progress=None) -> dict[str, Fetch]:
    """A kiosk that is given up on still reports how far it got. Workers that
    hang in an SMB call are left behind (daemon threads), not waited for."""
    parallel = max(1, settings.parallel_hosts)
    limit = settings.host_timeout_seconds
    slots = threading.Semaphore(parallel)
    results: dict[str, Fetch] = {}
    threads: list[tuple[Fetch, threading.Thread]] = []

    def run(f: Fetch, k: Kiosk):
        with slots:
            fetch_kiosk(f, k, fs, settings, now)

    for k in kiosks:
        f = Fetch(host=k.host.upper())
        results[f.host] = f
        t = threading.Thread(target=run, args=(f, k), daemon=True, name=f"fetch-{f.host}")
        threads.append((f, t))
        t.start()

    hard_stop = time.monotonic() + limit * (-(-len(threads) // parallel) + 1)
    pending = list(threads)
    done = 0
    while pending:
        time.sleep(0.1)
        out_of_time = time.monotonic() > hard_stop
        still = []
        for f, t in pending:
            late = f.started is not None and time.monotonic() - f.started > limit
            if t.is_alive() and not late and not out_of_time:
                still.append((f, t))
                continue
            if t.is_alive():
                f.notes.append(f"Gave up reading this kiosk after {limit}s" if f.started else "Never got its turn: the scan ran out of time")
                f.timed_out = True
                if f.started and not f.seconds:
                    f.seconds = round(time.monotonic() - f.started, 1)
            done += 1
            if progress:
                progress("scanning", done, len(threads), f.host)
        pending = still
    return results


# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------
class Log:
    def __init__(self, path: Path):
        self.path = path

    def __call__(self, message: str, level: str = "INFO") -> None:
        line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{level}] {message}"
        try:
            if self.path.exists() and self.path.stat().st_size >= 5 * 1024 * 1024:
                prev = self.path.with_name(self.path.name + ".1")
                prev.unlink(missing_ok=True)
                self.path.rename(prev)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
        print(line, flush=True)


def runner_name() -> str:
    try:
        user = getpass.getuser()
    except Exception:  # noqa: BLE001
        user = "unknown"
    return f"{user}@{socket.gethostname()}"


def run_scan(settings: Settings, progress_file: Path | None = None, dry_run: bool = False) -> int:
    settings.ensure_dirs()
    log = Log(settings.log_dir / "collector.log")

    def progress(phase, index, total, host=""):
        if not progress_file:
            return
        try:
            progress_file.write_text(json.dumps({"Pid": os.getpid(), "Phase": phase, "Index": index, "Total": total, "Host": host}))
        except OSError:
            pass

    # One collector at a time; the lock goes with the process if it dies.
    lock_path = settings.data_dir / "collector.lock"
    lock = open(lock_path, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("Another collector run is in progress; exiting without scanning.", "WARN")
        lock.close()
        return 0

    try:
        return _scan(settings, log, progress, dry_run)
    except Exception as e:  # noqa: BLE001
        log(f"Scan failed: {e}", "ERROR")
        return 1
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def _scan(settings: Settings, log: Log, progress, dry_run: bool) -> int:
    exit_code = 0
    start = time.monotonic()
    now = utcnow().replace(microsecond=0)
    scan_id = now.strftime("%Y%m%dT%H%M%SZ")
    collected = utc_iso(now)
    retention_cutoff = utc_iso(now - timedelta(days=settings.retention_days))
    run_cutoff = utc_iso(now - timedelta(days=settings.run_row_retention_days))
    runner = runner_name()

    log(f"Scan {scan_id} starting (collector v{COLLECTOR_VERSION}, run by {runner}{', DRY RUN' if dry_run else ''}).")
    if settings.uses_smb and not settings.has_credential:
        log("No kiosk-admin credential (KIOSK_ADMIN_USER / KIOSK_ADMIN_PASSWORD): kiosks will be read as this container's identity.", "WARN")

    list_path = settings.resolve_kiosk_list()
    if not list_path:
        raise RuntimeError("No kiosk list: upload one in Settings, or set KFW_KIOSK_LIST.")
    kiosks, stats_list = import_kiosk_list(list_path, settings.kiosk_list_sheet, settings.include_all_hosts)
    if not kiosks:
        raise RuntimeError(f"Kiosk list '{list_path}' yielded no hosts.")
    watchdog_count = sum(1 for k in kiosks if k.runs_watchdog)
    log(f"{len(kiosks)} host(s) from {list_path}: {watchdog_count} run the watchdog, {len(kiosks) - watchdog_count} ping-only.")
    if stats_list.inactive:
        log(f"{stats_list.inactive} kiosk(s) skipped: ACTIVE is set to something other than Y in the list.", "WARN")

    output = Path(settings.publish_csv) if settings.publish_csv else settings.local_csv
    local = settings.local_csv
    same_path = output.resolve() == local.resolve()

    known: set[str] = set()
    all_rows: list[dict] = []
    dirty = False

    primary = read_fleet_csv(output)
    primary_writable = not primary.error
    if primary.error:
        log(f"Published CSV could not be read and will NOT be overwritten this run: {primary.error}", "ERROR")
        exit_code = 1
    for r in primary.rows:
        if r["EventId"].lower() not in known:
            known.add(r["EventId"].lower())
            all_rows.append(r)

    local_writable = True
    if not same_path:
        loc = read_fleet_csv(local)
        if loc.error:
            log(f"Local CSV could not be read and will NOT be overwritten this run: {loc.error}", "ERROR")
            local_writable = False
        restored = 0
        for r in loc.rows:
            if r["EventId"].lower() not in known:
                known.add(r["EventId"].lower())
                all_rows.append(r)
                restored += 1
        if restored:
            log(f"Merged {restored} row(s) from the local copy that were missing from the published CSV.")
            dirty = True
        if not primary.exists and loc.exists:
            dirty = True

    last_status: dict[str, dict] = {}
    last_run_iso = None
    for r in all_rows:
        if r["EventType"] == "HOST_STATUS":
            prev = last_status.get(r["Host"])
            if prev is None or r["EventTimeUtc"] > prev["EventTimeUtc"]:
                last_status[r["Host"]] = r
        elif r["EventType"] == "COLLECTOR_RUN":
            if last_run_iso is None or r["EventTimeUtc"] > last_run_iso:
                last_run_iso = r["EventTimeUtc"]

    log(f"Loaded {len(all_rows)} existing row(s). Scanning {len(kiosks)} kiosk(s), {settings.parallel_hosts} at a time...")

    new_ids: set[str] = set()
    new_rows: list[dict] = []
    host_results = []
    pbi_details, web_details, ng_details = {}, {}, {}
    stats = {"Reachable": 0, "LedgersRead": 0, "EventLogsRead": 0, "HostErrors": 0, "InvalidLedgerRows": 0}

    fs = KioskFS(settings)
    read_start = time.monotonic()
    fetched = fetch_all(kiosks, fs, settings, now, progress)
    slow = sorted((f for f in fetched.values() if f.seconds >= 10), key=lambda f: -f.seconds)
    log(f"Read {len(kiosks)} kiosk(s) in {time.monotonic() - read_start:.0f}s"
        + ("; slowest " + ", ".join(f"{f.host} {f.seconds:.0f}s" for f in slow[:3]) if slow else "") + ".")

    def is_known(eid: str) -> bool:
        return eid.lower() in known or eid.lower() in new_ids

    for k in kiosks:
        h = k.host.upper()
        fetch = fetched[h]
        obs = Obs(is_pbi=is_power_bi(k.type), is_web=is_web(k.type))
        try:
            obs.reachable, obs.method = fetch.reachable, fetch.method
            if obs.reachable:
                stats["Reachable"] += 1
            obs.notes.extend(fetch.notes)
            if fetch.fatal:
                stats["HostErrors"] += 1
                obs.notes.append(f"Scan error: {fetch.fatal}")
                log(f"{h}: {fetch.fatal}", "WARN")
            elif fetch.timed_out:
                stats["HostErrors"] += 1
                log(f"{h}: gave up reading it after {settings.host_timeout_seconds}s", "WARN")

            if fetch.ng and fetch.ng["Installed"]:
                obs.ng = fetch.ng
                obs.watchdog_found = True
                ng_details[h] = sidecar_entry(fetch.ng)

            if obs.reachable and (k.runs_watchdog or obs.watchdog_found):
                obs.share_ok = fetch.share_ok
                if obs.share_ok:
                    obs.log_found = fetch.log_found
                    obs.log_age_minutes = fetch.log_age_minutes
                    latest = None
                    if fetch.ledger:
                        ledger = fetch.ledger
                        obs.ledger_files = ledger["Files"]
                        obs.ledger_found = ledger["Files"] > 0
                        if obs.ledger_found:
                            stats["LedgersRead"] += 1
                        converted = []
                        guard = None
                        for lr in ledger["Rows"]:
                            row = convert_ledger_row(lr, h, scan_id, collected)
                            if not row:
                                stats["InvalidLedgerRows"] += 1
                                continue
                            # The loop guard holds if its last row (in file order) says so.
                            if row["EventType"].startswith("LOOP_GUARD_"):
                                guard = row
                            if row["Source"] == "EventLog":
                                obs.win_event_rows += 1
                            if row["EventType"] == "BOOT":
                                bt = parse_utc(row["EventTimeUtc"])
                                if bt and (obs.event_boot is None or bt > obs.event_boot):
                                    obs.event_boot = bt
                            if row["BootTimeUtc"] and (latest is None or row["EventTimeUtc"] >= latest["EventTimeUtc"]):
                                latest = row
                            converted.append(row)

                        cutoff = None
                        if not settings.keep_pre_upgrade_history:
                            cutoff = upgrade_cutoffs(converted, settings.trusted_from_agent_version).get(h)
                        for row in converted:
                            if cutoff and row["EventTimeUtc"] < cutoff:
                                obs.pre_upgrade += 1
                                continue
                            if is_known(row["EventId"]):
                                continue
                            if row["EventTimeUtc"] < retention_cutoff:
                                continue
                            new_ids.add(row["EventId"].lower())
                            new_rows.append(row)
                            obs.new_events += 1
                        obs.loop_guard = bool(guard and guard["EventType"] == "LOOP_GUARD_ENGAGED")
                    if latest:
                        obs.agent_version = latest["AgentVersion"]
                        obs.ledger_boot = parse_utc(latest["BootTimeUtc"])
                    elif obs.log_found:
                        obs.agent_version = "legacy"

            if obs.reachable:
                if obs.share_ok is None and (obs.is_pbi or obs.is_web):
                    obs.share_ok = fetch.pbi_share_ok
                if fetch.pbi_share_ok and fetch.pbi and (obs.is_pbi or fetch.pbi["Installed"] or fetch.pbi["Screens"]):
                    obs.pbi = fetch.pbi
                    pbi_details[h] = sidecar_entry(fetch.pbi)
                if fetch.pbi_share_ok and fetch.web and (obs.is_web or fetch.web["Installed"] or fetch.web["Screens"]):
                    obs.web = fetch.web
                    web_details[h] = sidecar_entry(fetch.web)
        except Exception as e:  # noqa: BLE001
            stats["HostErrors"] += 1
            obs.notes.append(f"Scan error: {e}")
            log(f"{h}: {e}", "WARN")

        # The ledger's boot time is authoritative once the agent has run since
        # the latest boot; if it has not, the System log's newer boot wins.
        boot = obs.ledger_boot
        if obs.event_boot and (boot is None or obs.event_boot > boot + timedelta(minutes=10)):
            boot = obs.event_boot
        if boot is None and obs.pbi and obs.pbi.get("PcBootUtc"):
            boot = obs.pbi["PcBootUtc"]
        if boot is None and obs.web and obs.web.get("PcBootUtc"):
            boot = obs.web["PcBootUtc"]
        if not obs.watchdog_found or not obs.agent_version:
            if obs.pbi and obs.pbi.get("LauncherVersion"):
                obs.agent_version = f"pbi-{obs.pbi['LauncherVersion']}"
            elif obs.web and obs.web.get("LauncherVersion"):
                obs.agent_version = f"web-{obs.web['LauncherVersion']}"

        watchdog_running = None
        if (k.runs_watchdog or obs.watchdog_found) and obs.reachable and obs.share_ok:
            watchdog_running = obs.log_age_minutes is not None and obs.log_age_minutes <= settings.agent_stale_minutes

        status, severity = host_status(k, obs, settings.agent_stale_minutes)

        checks = ["reach=" + (obs.method if obs.reachable else "FAIL")]
        if obs.share_ok is not None:
            checks.append("share=" + ("ok" if obs.share_ok else "FAIL"))
        if obs.log_found is not None:
            checks.append("log=" + (fmt_number(obs.log_age_minutes, 1) + "m" if obs.log_found else "missing"))
        if obs.ledger_found is not None:
            checks.append("ledger=" + (f"ok({obs.ledger_files})" if obs.ledger_found else "missing"))
        if obs.loop_guard:
            checks.append("loopguard=HOLD")
        if obs.event_log_ok is not None:
            checks.append("eventlog=" + ("ok" if obs.event_log_ok else "FAIL"))
        elif (k.runs_watchdog or obs.watchdog_found) and obs.share_ok:
            checks.append(f"eventlog=agent({obs.win_event_rows})")
        for l in (obs.pbi, obs.web, obs.ng):
            if l and l.get("Summary"):
                checks.append(l["Summary"])
        checks.append(f"new={obs.new_events}")
        detail = " ".join(checks)
        if obs.notes:
            detail += " | " + " | ".join(obs.notes)

        status_row = new_row({
            "EventId": f"STAT-{h}-{scan_id}", "EventTimeUtc": collected, "Host": h, "EventType": "HOST_STATUS",
            "Severity": severity, "Outcome": status, "Reachable": fmt_bool(obs.reachable),
            "WatchdogRunning": fmt_bool(watchdog_running), "MinutesSinceLastLog": fmt_number(obs.log_age_minutes, 1),
            "AgentVersion": obs.agent_version, "BootTimeUtc": utc_iso(boot) if boot else "",
            "UptimeHours": fmt_number((now - boot).total_seconds() / 3600, 1) if boot else "",
            "Source": "Collector", "ScanId": scan_id, "CollectedUtc": collected, "Detail": detail,
        })
        # (A second scan within the same second would reuse the EventId: skipped.)
        if not is_known(status_row["EventId"]) and status_row_needed(status_row, last_status.get(h), now, settings.keepalive_hours):
            new_ids.add(status_row["EventId"].lower())
            new_rows.append(status_row)

        launcher_txt = ",".join(f"{i['Screen']}:{i['State']}" for i in sorted(
            (i for l in (obs.pbi, obs.web, obs.ng) if l for i in l["Instances"]), key=lambda i: i["Screen"]))
        host_results.append({
            "Host": h, "Type": k.type, "Location": k.location, "Status": status,
            "Watchdog": "" if watchdog_running is None else ("running" if watchdog_running else "DEAD"),
            "LogAgeMin": fmt_number(obs.log_age_minutes, 1), "Agent": obs.agent_version, "Launcher": launcher_txt,
            "NewEvents": obs.new_events, "PreUpgrade": obs.pre_upgrade, "Notes": " | ".join(obs.notes),
        })
    progress("saving", len(kiosks), len(kiosks))

    # Kiosks deliberately not scanned get a status of their own, so their last
    # real status does not stay on the dashboard for ever.
    for dead in stats_list.inactive_rows:
        dh = dead.host.upper()
        row = new_row({
            "EventId": f"STAT-{dh}-{scan_id}", "EventTimeUtc": collected, "Host": dh, "Location": dead.location,
            "KioskType": dead.type, "RestartGroup": dead.restart_group, "EventType": "HOST_STATUS", "Severity": "INFO",
            "Outcome": "INACTIVE", "Source": "Collector", "ScanId": scan_id, "CollectedUtc": collected,
            "Detail": f"not scanned: ACTIVE is '{dead.active}' in the kiosk list",
        })
        if not is_known(row["EventId"]) and status_row_needed(row, last_status.get(dh), now, settings.keepalive_hours):
            new_ids.add(row["EventId"].lower())
            new_rows.append(row)

    if stats["InvalidLedgerRows"]:
        log(f"{stats['InvalidLedgerRows']} ledger row(s) were malformed and skipped.", "WARN")

    # --- Merge ---
    for r in new_rows:
        known.add(r["EventId"].lower())
        all_rows.append(r)
    event_rows = sum(1 for r in new_rows if r["EventType"] != "HOST_STATUS")
    if new_rows:
        dirty = True

    # Kiosk attributes follow the current list across their whole history.
    meta = {k.host.upper(): (k.location, k.type, k.restart_group) for k in kiosks}
    for dead in stats_list.inactive_rows:
        meta.setdefault(dead.host.upper(), (dead.location, dead.type, dead.restart_group))
    meta_changes = 0
    for r in all_rows:
        m = meta.get(r["Host"]) if r["Host"] else None
        if not m:
            continue
        for col, val in zip(("Location", "KioskType", "RestartGroup"), m):
            if r[col] != (val or ""):
                r[col] = val or ""
                meta_changes += 1
    if meta_changes:
        dirty = True

    flag_changes = update_reboot_flags(all_rows, now - timedelta(days=settings.reconcile_days), new_ids)
    if flag_changes:
        dirty = True

    # --- Retention ---
    cutoffs = {} if settings.keep_pre_upgrade_history else upgrade_cutoffs(all_rows, settings.trusted_from_agent_version)
    kept = []
    pre_upgrade_pruned = 0
    for r in all_rows:
        t = r["EventTimeUtc"]
        if t:
            if t < retention_cutoff:
                continue
            if r["EventType"] == "COLLECTOR_RUN" and t < run_cutoff:
                continue
            if r["Host"] and r["Host"] in cutoffs and t < cutoffs[r["Host"]]:
                pre_upgrade_pruned += 1
                continue
        kept.append(r)
    pruned = len(all_rows) - len(kept)
    if pruned:
        dirty = True
    if pre_upgrade_pruned:
        log(f"Dropped {pre_upgrade_pruned} row(s) from before kiosks upgraded to agent {settings.trusted_from_agent_version}.", "WARN")

    heartbeat_due = True
    if last_run_iso:
        lr = parse_utc(last_run_iso)
        if lr and (now - lr).total_seconds() / 60 < settings.heartbeat_minutes:
            heartbeat_due = False

    script_new = sum(1 for r in new_rows if r["EventType"] in ("RESTART_TRIGGERED", "REBOOT_SCRIPT"))
    summary = (f"hosts={len(kiosks)} reachable={stats['Reachable']} watchdog_hosts={watchdog_count} "
               f"ledgers_read={stats['LedgersRead']} eventlogs_read={stats['EventLogsRead']} new_events={event_rows} "
               f"status_rows={len(new_rows) - event_rows} flag_changes={flag_changes} pruned={pruned} "
               f"pre_upgrade_skipped={sum(x['PreUpgrade'] for x in host_results)} host_errors={stats['HostErrors']}")

    elapsed = time.monotonic() - start
    data_changed = False
    if dirty or heartbeat_due:
        partial = stats["HostErrors"] > 0 or not primary_writable
        kept.append(new_row({
            "EventId": f"RUN-{scan_id}", "EventTimeUtc": collected, "EventType": "COLLECTOR_RUN",
            "Severity": "WARNING" if partial else "INFO", "Outcome": "PARTIAL" if partial else "OK",
            "DurationSeconds": fmt_number(elapsed, 0), "Source": "Collector", "ScanId": scan_id, "CollectedUtc": collected,
            "Detail": f"v{COLLECTOR_VERSION}; {summary}; list={list_path}; runner={runner}",
        }))
        kept.sort(key=lambda r: (r["EventTimeUtc"], r["EventId"].lower()))
        if dry_run:
            log(f"DRY RUN: would write {len(kept)} row(s) to {output}")
        else:
            if primary_writable:
                try:
                    write_fleet_csv(kept, output)
                    data_changed = True
                    log(f"Wrote {len(kept)} row(s) to {output}")
                except OSError as e:
                    log(f"Could not write the published CSV: {e}", "ERROR")
                    exit_code = 1
            if not same_path and local_writable:
                try:
                    write_fleet_csv(kept, local)
                except OSError as e:
                    log(f"Could not write the local CSV: {e}", "ERROR")
                    exit_code = 1
    else:
        log("Nothing new; CSV left untouched.")

    if not dry_run:
        sidecar = {
            "LastRunUtc": collected, "LastRunLocal": local_iso(now), "DurationSeconds": int(elapsed),
            "Hosts": len(kiosks), "Reachable": stats["Reachable"], "WatchdogHosts": watchdog_count,
            "NeedsAttention": sum(1 for x in host_results if x["Status"] != "OK"), "NewEvents": event_rows,
            "DataChanged": data_changed, "HostErrors": stats["HostErrors"], "SkippedInactive": stats_list.inactive,
            "CollectorVersion": COLLECTOR_VERSION, "Runner": runner,
            "PbiLaunchers": pbi_details, "Mach2Launchers": ng_details, "WebLaunchers": web_details,
        }
        if primary_writable:
            write_status_sidecar(output, sidecar)
        if not same_path and local_writable:
            write_status_sidecar(local, sidecar)

    log(f"Scan {scan_id} done in {time.monotonic() - start:.1f}s. {summary}")
    if script_new:
        log(f"{script_new} new watchdog reboot record(s) collected this run.", "WARN")

    # A summary table for whoever is watching the output.
    order = sorted(host_results, key=lambda x: (x["Status"] == "OK", x["Host"]))
    cols = ["Host", "Type", "Location", "Status", "Watchdog", "LogAgeMin", "Agent", "Launcher", "NewEvents"]
    widths = {c: max(len(c), *(len(str(x[c])) for x in order)) if order else len(c) for c in cols}
    print()
    print("  ".join(c.ljust(widths[c]) for c in cols))
    print("  ".join("-" * widths[c] for c in cols))
    for x in order:
        print("  ".join(str(x[c]).ljust(widths[c]) for c in cols))
    by_type: dict[str, int] = {}
    for r in new_rows:
        if r["EventType"] != "HOST_STATUS":
            by_type[r["EventType"]] = by_type.get(r["EventType"], 0) + 1
    if by_type:
        print("\nNew events this run:")
        for t in sorted(by_type):
            print(f"  {t:<24} {by_type[t]}")
    sys.stdout.flush()
    return exit_code


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="kfw scan", description="One scan of the kiosk fleet.")
    p.add_argument("--progress-file")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    return run_scan(load_settings(), Path(a.progress_file) if a.progress_file else None, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
