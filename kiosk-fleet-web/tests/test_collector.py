"""The collector: reboot counting, host statuses, a whole scan of fake kiosks,
the kiosk list readers, and a scan started from the page."""
from __future__ import annotations

import csv
import json
import time
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from conftest import docs
from kfw.collector import new_row, read_fleet_csv, run_scan, update_reboot_flags
from kfw.kiosklist import import_kiosk_list
from kfw.timeutil import utc_iso

T0 = datetime(2026, 9, 1, 8, 0, tzinfo=timezone.utc)


def row(etype, minutes, detail="", eid=None, **kw):
    return new_row({"EventId": eid or str(uuid.uuid4()), "EventTimeUtc": utc_iso(T0 + timedelta(minutes=minutes)),
                    "Host": "K1", "EventType": etype, "Detail": detail, **kw})


def flags(rows):
    update_reboot_flags(rows, T0 - timedelta(days=30), set())
    return [(r["EventType"], r["IsCanonicalReboot"], r["IsScriptReboot"], r["RebootTrigger"]) for r in rows]


# ---------------------------------------------------------------------------
# One boot is one reboot, however many records describe it
# ---------------------------------------------------------------------------
def test_watchdog_reboot_with_three_witnesses_counts_once():
    trig_id = str(uuid.uuid4())
    rows = [
        row("BOOT", 0),
        row("RESTART_TRIGGERED", 60, "Kind=WHITE", eid=trig_id),
        row("REBOOT_SCRIPT", 61, f"id={trig_id[:8]}; Process=shutdown.exe", RebootTrigger="WATCHDOG_WHITE"),
        row("BOOT", 63),
        row("RESTART_CONFIRMED", 65, "Kind=WHITE"),
    ]
    f = flags(rows)
    canonical = [x for x in f if x[1] == "TRUE"]
    assert len(canonical) == 1 and canonical[0][0] == "REBOOT_SCRIPT" and canonical[0][2] == "TRUE"


def test_two_1074s_for_one_restart_count_once():
    rows = [row("BOOT", 0), row("REBOOT_EXTERNAL", 30, RebootTrigger="EXTERNAL"), row("REBOOT_EXTERNAL", 30.5, RebootTrigger="EXTERNAL"), row("BOOT", 32)]
    canonical = [x for x in flags(rows) if x[1] == "TRUE"]
    assert len(canonical) == 1 and canonical[0][2] == "FALSE"


def test_trigger_without_event_log_still_counts():
    rows = [row("BOOT", 0), row("RESTART_TRIGGERED", 60, "Kind=LOWWHITE", RebootTrigger="WATCHDOG_LOWWHITE"), row("BOOT", 62)]
    f = flags(rows)
    assert f[1][1:] == ("TRUE", "TRUE", "WATCHDOG_LOWWHITE")
    assert f[2][1] == "FALSE", "the boot after it is explained"


def test_failed_trigger_does_not_count():
    trig = str(uuid.uuid4())
    rows = [row("BOOT", 0), row("RESTART_TRIGGERED", 60, "Kind=WHITE", eid=trig), row("RESTART_FAILED", 70, f"TriggerEventId={trig}")]
    assert all(x[1] == "FALSE" for x in flags(rows))


def test_unexplained_boot_counts_only_with_history():
    rows = [row("BOOT", 0), row("BOOT", 600)]
    f = flags(rows)
    assert f[0][1] == "FALSE", "the first boot's interval began before the data does"
    assert f[1][1:] == ("TRUE", "FALSE", "UNEXPLAINED")


def test_unexpected_shutdown_belongs_to_the_boot_it_was_written_at():
    rows = [row("BOOT", 0), row("BOOT", 600), row("REBOOT_UNEXPECTED", 600.2, RebootTrigger="UNEXPECTED")]
    f = flags(rows)
    assert [x[0] for x in f if x[1] == "TRUE"] == ["REBOOT_UNEXPECTED"]


# ---------------------------------------------------------------------------
# A whole scan
# ---------------------------------------------------------------------------
def kiosk_list(work, text):
    p = work["data"] / "kiosk-list.csv"
    p.write_text(text)
    return p


def scan(work) -> list[dict]:
    time.sleep(max(0.0, 1.05 - (time.time() % 1)))  # a scan id is to the second
    assert run_scan(work["settings"]) == 0
    return read_fleet_csv(work["settings"].local_csv).rows


def test_scan_end_to_end(work, capsys):
    root = work["root"]
    now = datetime.now(timezone.utc)
    # The agent's ledger: a reboot it asked for, and Windows' own records of it.
    trig = str(uuid.uuid4())
    payload_1074 = json.dumps({"Id": 1074, "Provider": "User32", "RecordId": 4711,
                               "Props": ["C:\\Windows\\system32\\shutdown.exe", "MWEB1", "No title", "0x80000000", "restart", f"MWST-WATCHDOG WHITE id={trig[:8]}", "NT AUTHORITY\\SYSTEM"]})
    payload_6005 = json.dumps({"Id": 6005, "Provider": "EventLog", "RecordId": 4712, "Props": []})
    t_trig, t_1074, t_boot = now - timedelta(hours=2), now - timedelta(hours=2) + timedelta(seconds=5), now - timedelta(hours=2) + timedelta(minutes=2)
    ledger = docs(root, "MWEB1") / "mwst_events.csv"
    with open(ledger, "a", newline="") as fh:
        w = csv.writer(fh, lineterminator="\r\n")
        w.writerow([trig, utc_iso(t_trig), "", "MWEB1", "RESTART_TRIGGERED", "CRITICAL", "TRIGGERED", "97.5", "12", "", "1.00NG", utc_iso(now - timedelta(hours=9)), "Kind=WHITE white for 60s"])
        w.writerow(["x", utc_iso(t_1074), "", "MWEB1", "WINEVENT", "", "", "", "", "", "", "", payload_1074])
        w.writerow(["y", utc_iso(t_boot), "", "MWEB1", "WINEVENT", "", "", "", "", "", "", "", payload_6005])
        w.writerow([str(uuid.uuid4()), utc_iso(now - timedelta(hours=1)), "", "MWEB1", "WHITE_EPISODE_START", "WARNING", "WHITE", "99", "", "", "1.00NG", utc_iso(t_boot), "page white"])
        fh.write(f"{uuid.uuid4()},{utc_iso(now)},,MWEB1,AGENT_STOP,INFO,STOPPED,,,,1.00NG,")  # mid-append: no newline yet

    docs(root, "NEWWEB1").mkdir(parents=True)
    kiosk_list(work, "Host,Location,Type,HasMwst,Active\nMWEB1,LINE1,Mach2,Y,\nPWEB1,APU1,PBI,,\nNEWWEB1,LAB,Mach2,Y,\nGONE1,OLD,Mach2,Y,N\nGHOST1,NOWHERE,PBI,,\n")
    rows = scan(work)
    out = capsys.readouterr().out
    assert "Scan" in out and "done" in out

    by_type = {}
    for r in rows:
        by_type.setdefault(r["EventType"], []).append(r)
    status = {r["Host"]: r for r in by_type["HOST_STATUS"]}
    assert status["MWEB1"]["Outcome"] == "OK", status["MWEB1"]["Detail"]
    assert status["MWEB1"]["WatchdogRunning"] == "TRUE" and status["MWEB1"]["AgentVersion"] == "1.00NG"
    assert "launcher=S1:SHOWING" in status["MWEB1"]["Detail"] and "ledger=ok(1)" in status["MWEB1"]["Detail"]
    assert status["PWEB1"]["Outcome"] == "OK" and status["PWEB1"]["AgentVersion"] == "pbi-2.0.0"
    assert status["NEWWEB1"]["Outcome"] == "NO_AGENT", "watchdog expected, no trace of it"
    assert status["GONE1"]["Outcome"] == "INACTIVE"
    assert status["GHOST1"]["Outcome"] == "NO_ACCESS", "a kiosk whose share cannot be opened"

    reboots = [r for r in rows if r["IsCanonicalReboot"] == "TRUE"]
    assert len(reboots) == 1 and reboots[0]["EventType"] == "REBOOT_SCRIPT" and reboots[0]["IsScriptReboot"] == "TRUE"
    assert reboots[0]["EventId"].startswith("EVT-MWEB1-4711-")
    assert not any(r["EventType"] == "AGENT_STOP" for r in rows), "a row mid-append is not taken"
    assert by_type["COLLECTOR_RUN"][0]["Outcome"] == "OK"
    assert all(r["Location"] == "LINE1" for r in rows if r["Host"] == "MWEB1"), "kiosk attributes follow the list"

    sidecar = json.loads(work["settings"].local_csv.with_suffix(".status.json").read_text(encoding="utf-8-sig"))
    assert sidecar["Hosts"] == 4 and sidecar["SkippedInactive"] == 1 and sidecar["Mach2Launchers"]["MWEB1"]["Instances"][0]["State"] == "SHOWING"
    assert sidecar["PbiLaunchers"]["PWEB1"]["Instances"][0]["SignedInAs"] == "kiosk@contoso.test"

    # The file the Power BI report binds to: the same columns, quoted, with a BOM.
    raw = work["settings"].local_csv.read_bytes()
    assert raw.startswith(b"\xef\xbb\xbf\"EventId\",\"EventTimeUtc\"")

    # A second scan right after adds nothing: the same EventIds, no new status rows.
    count = len(rows)
    rows2 = scan(work)
    assert len(rows2) == count, "nothing new is a no-op"
    assert len({r["EventId"] for r in rows2}) == len(rows2)

    # A kiosk going quiet is a status change, and gets a row.
    (docs(root, "MWEB1") / "mwst.log").unlink()
    rows3 = scan(work)
    latest = max((r for r in rows3 if r["Host"] == "MWEB1" and r["EventType"] == "HOST_STATUS"), key=lambda r: r["EventTimeUtc"] + r["EventId"])
    assert latest["Outcome"] == "STALE"


def test_scan_fills_the_dashboard(work):
    kiosk_list(work, "Host,Location,Type,HasMwst\nMWEB1,LINE1,Mach2,Y\nPWEB1,APU1,PBI,\n")
    scan(work)
    from kfw.fleetstate import fleet_view, read_fleet_state
    v = fleet_view(read_fleet_state(work["settings"].local_csv))
    hosts = {k["Host"]: k for k in v["Kiosks"]}
    assert v["Ok"] and v["Total"] == 2 and v["Attention"] == 0
    assert hosts["MWEB1"]["Launchers"]["Mach2"]["State"] == "SHOWING"
    assert hosts["PWEB1"]["Screens"][0]["Kind"] == "PBI"


def test_excel_saved_csv_is_left_alone(work):
    kiosk_list(work, "Host,Type,HasMwst\nMWEB1,Mach2,Y\n")
    work["settings"].local_csv.write_text("EventId;EventTimeUtc;EventType\n1;2;3\n")
    assert run_scan(work["settings"]) == 1
    assert work["settings"].local_csv.read_text().startswith("EventId;"), "never overwritten with a copy missing its history"


def test_published_copy_is_restored_from_the_local_one(work, tmp_path):
    kiosk_list(work, "Host,Type,HasMwst\nMWEB1,Mach2,Y\n")
    pub = tmp_path / "sharepoint" / "MWST_FleetEvents.csv"
    pub.parent.mkdir()
    work["settings"].publish_csv = str(pub)
    scan(work)
    n = len(read_fleet_csv(pub).rows)
    pub.unlink()
    scan(work)
    assert len(read_fleet_csv(pub).rows) >= n


# ---------------------------------------------------------------------------
# Kiosk lists
# ---------------------------------------------------------------------------
def make_xlsx(path: Path, rows: list[list[str]]) -> None:
    shared, index = [], {}

    def si(v):
        if v not in index:
            index[v] = len(shared)
            shared.append(v)
        return index[v]

    def col(i):
        s = ""
        i += 1
        while i:
            i, r = divmod(i - 1, 26)
            s = chr(65 + r) + s
        return s
    sheet_rows = []
    for rn, r in enumerate(rows, start=2):  # a title row above the table
        cells = "".join(f'<c r="{col(ci)}{rn}" t="s"><v>{si(v)}</v></c>' for ci, v in enumerate(r) if v)
        sheet_rows.append(f'<row r="{rn}">{cells}</row>')
    ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xl/workbook.xml", f'<workbook {ns} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="KIOSKS" sheetId="1" r:id="rId1"/></sheets></workbook>')
        z.writestr("xl/_rels/workbook.xml.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>')
        z.writestr("xl/sharedStrings.xml", f'<sst {ns}>' + "".join(f"<si><t>{s}</t></si>" for s in shared) + "</sst>")
        z.writestr("xl/worksheets/sheet1.xml", f'<worksheet {ns}><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Kiosks</t></is></c></row>{"".join(sheet_rows)}</sheetData></worksheet>')


def test_xlsx_kiosk_list(tmp_path):
    p = tmp_path / "MASTER_KIOSK LIST.xlsx"
    make_xlsx(p, [["NAME", "LOCATION", "TYPE", "HAS MWST", "ACTIVE", "RESTART GROUP"],
                  ["MWEB1", "LINE1", "Mach2", "Y", "", "A"],
                  ["PWEB1", "APU1", "PBI - SR", "", "", ""],
                  ["WWEB1", "HALL", "Web board", "", "", ""],
                  ["OLD1", "X", "Mach2", "Y", "N", ""],
                  ["MISC1", "Y", "Signage", "", "", ""],
                  ["mweb1", "dup", "Mach2", "Y", "", ""]])
    kiosks, stats = import_kiosk_list(p)
    assert [k.host for k in kiosks] == ["MWEB1", "PWEB1", "WWEB1"]
    assert kiosks[0].runs_watchdog and kiosks[0].restart_group == "A"
    assert kiosks[1].ping_only and not kiosks[1].runs_watchdog
    assert stats.inactive == 1 and stats.not_flagged == 1 and stats.inactive_rows[0].host == "OLD1"


def test_txt_kiosk_list(tmp_path):
    p = tmp_path / "kiosks.txt"
    p.write_text("# the line\nMWEB1\n\nMWEB2\n")
    kiosks, _ = import_kiosk_list(p)
    assert [k.host for k in kiosks] == ["MWEB1", "MWEB2"] and all(k.runs_watchdog for k in kiosks)


# ---------------------------------------------------------------------------
# A scan from the page
# ---------------------------------------------------------------------------
def test_scan_from_the_page(admin, fleet):
    kiosk_list(fleet, "Host,Location,Type,HasMwst\nMWEB1,LINE1,Mach2,Y\nPWEB1,APU1,PBI,\n")
    st = admin.app.state.kfw
    r = admin.post("/api/scan")
    assert r.status_code == 202, r.text
    assert admin.post("/api/scan").status_code == 409, "one run at a time"
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        st.tick()
        if st.runner.run is None:
            break
        time.sleep(0.2)
    assert st.runner.last and st.runner.last["Code"] == 0, st.runner.log
    out = admin.get("/api/run", params={"from": 0}).json()
    assert "Fleet scan" in out["text"] and "finished with code 0" in out["text"] and "MWEB1" in out["text"]
    reports = admin.get("/api/reports").json()["reports"]
    assert reports and admin.get(f"/api/reports/{reports[0]['name']}").status_code == 200
    f = admin.get("/api/state").json()["fleet"]
    assert f["Collector"]["Hosts"] == 2 and f["Collector"]["Version"] == "6.2-py", "the dashboard reads the new scan"
    acts = [e["Action"] for e in st.db.audit_entries()]
    assert "scan" in acts and "scan-finished" in acts


def test_stop_a_run(admin, fleet):
    kiosk_list(fleet, "Host,Type,HasMwst\nMWEB1,Mach2,Y\n")
    st = admin.app.state.kfw
    import sys
    st.runner._start("Slow thing", "scan", [sys.executable, "-c", "import time; print('working', flush=True); time.sleep(30)"], quiet=False, session={"user": "webadmin", "role": "admin"})
    time.sleep(0.5)
    assert admin.post("/api/run/stop").status_code == 200
    deadline = time.monotonic() + 10
    while st.runner.run and time.monotonic() < deadline:
        st.tick()
        time.sleep(0.1)
    assert st.runner.run is None and st.runner.last["Code"] != 0
