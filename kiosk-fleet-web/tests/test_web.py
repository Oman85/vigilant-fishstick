"""The web app: signing in, what each role may and may not do, the fleet it
serves, what its buttons do to a kiosk, the config editor, accounts, settings
and the audit log."""
from __future__ import annotations

import json
import time

from fastapi.testclient import TestClient

from conftest import ADMIN_PASS, OP_PASS, Api, docs


def audit(api, q=""):
    return api.get("/api/audit", params={"q": q}).json()["entries"]


# ---------------------------------------------------------------------------
# The page and signing in
# ---------------------------------------------------------------------------
def test_page_and_headers(app_for):
    _, c = app_for()
    r = c.get("/")
    assert r.status_code == 200 and "<title>Kiosk Fleet</title>" in r.text
    assert "default-src 'self'" in r.headers["content-security-policy"]
    assert r.headers["x-frame-options"] == "DENY"
    assert c.get("/app.js").headers["content-type"].startswith("text/javascript")
    assert c.get("/healthz").json()["ok"] is True
    me = c.get("/api/me")
    assert me.status_code == 401 and me.json()["methods"] == {"windows": False, "local": True}
    assert c.get("/api/state").status_code == 401
    assert c.post("/api/kiosks/MWEB1/reload", json={}).status_code == 401
    assert c.get("/../kfw/app.py").status_code == 404
    assert c.get("/api/nothing-here").status_code == 401 or c.get("/api/nothing-here").status_code == 404


def test_sign_in_and_lockout(app_for):
    _, c = app_for()
    a = Api(c)
    bad = a.login("webop", "wrong-password")
    ghost = a.login("nobody", "whatever-it-is")
    assert bad.status_code == 401 and ghost.status_code == 401 and bad.json() == ghost.json()
    for _ in range(4):
        a.login("webop", "wrong-again")
    locked = a.login("webop", OP_PASS)
    assert locked.status_code == 429, "five wrong passwords lock the name"
    ok = a.login("webadmin", ADMIN_PASS)
    assert ok.status_code == 200 and ok.json()["role"] == "admin"
    cookie = ok.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie


def test_csrf_and_origin(admin):
    r = admin.post("/api/scan", csrf=False)
    assert r.status_code == 403 and "out of date" in r.json()["error"]
    r = admin.post("/api/kiosks/MWEB1/reload", {}, headers={"Origin": "http://evil.example"})
    assert r.status_code == 403 and r.json()["error"] == "wrong origin"
    assert admin.c.post("/api/login", json={"user": "webadmin", "password": ADMIN_PASS}, headers={"Origin": "http://evil.example"}).status_code == 403


def test_sign_out(admin):
    assert admin.post("/api/logout").status_code == 200
    assert admin.get("/api/state").status_code == 401


def test_first_admin_setup(work):
    from kfw.app import create_app
    app = create_app(work["settings"], background=False)
    with TestClient(app) as c:
        token = app.state.kfw.setup_token
        assert token, "with no accounts the server makes a one-time setup link"
        me = c.get("/api/me").json()
        assert me["setup"] is True
        assert c.post("/api/setup", json={"token": "wrong", "user": "boss", "password": ADMIN_PASS, "password2": ADMIN_PASS}).status_code == 403
        assert c.post("/api/setup", json={"token": token, "user": "boss", "password": "short", "password2": "short"}).status_code == 400
        r = c.post("/api/setup", json={"token": token, "user": "boss", "password": ADMIN_PASS, "password2": ADMIN_PASS})
        assert r.status_code == 200 and r.json()["role"] == "admin"
        again = c.post("/api/setup", json={"token": token, "user": "boss2", "password": ADMIN_PASS, "password2": ADMIN_PASS})
        assert again.status_code == 409, "the link works once"


def test_bootstrap_admin_from_environment(work):
    from kfw.app import create_app
    work["settings"].bootstrap_admin = "envadmin"
    work["settings"].bootstrap_password = ADMIN_PASS
    app = create_app(work["settings"], background=False)
    with TestClient(app) as c:
        assert app.state.kfw.setup_token is None
        assert Api(c).login("envadmin", ADMIN_PASS).status_code == 200


# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------
def test_operator_is_refused_admin_things(operator):
    me = operator.get("/api/me").json()
    assert me["role"] == "operator" and "restart" not in me["allowed"] and "live" in me["allowed"]
    for action in ("restart", "hold", "stop", "password", "config-read", "config-write"):
        r = operator.post(f"/api/kiosks/MWEB1/{action}", {"kind": "NG"})
        assert r.status_code == 403, action
    for path in ("/api/audit", "/api/users", "/api/settings", "/api/deploy/products"):
        assert operator.get(path).status_code == 403, path
    assert operator.post("/api/autoscan", {"on": True}).status_code == 403
    assert operator.post("/api/users", {"name": "x1", "role": "admin", "password": ADMIN_PASS, "password2": ADMIN_PASS}).status_code == 403
    refused = [e for e in operator.app.state.kfw.db.audit_entries() if e["Result"] == "refused" and e["User"] == "webop"]
    assert len(refused) >= 6, "every refusal is in the audit log"


def test_operator_can_do_safe_things(operator):
    r, j = operator.job("MWEB1", "reload")
    assert r.status_code == 202 and j["ok"], j


# ---------------------------------------------------------------------------
# The fleet
# ---------------------------------------------------------------------------
def test_state(admin):
    d = admin.get("/api/state").json()
    f = d["fleet"]
    assert f["Ok"] and f["Total"] == 7
    assert f["Attention"] == 3 and f["Critical"] == 3
    hosts = {k["Host"]: k for k in f["Kiosks"]}
    assert f["Kiosks"][0]["Status"] in ("OFFLINE", "STALE", "WRONG_ACCOUNT"), "trouble first"
    assert hosts["MWEB2"]["Reboots"] == "2 (1)" and sum(hosts["MWEB2"]["Days"]) == 3
    assert hosts["PWEB1"]["Launchers"]["PBI"]["Account"] == "kiosk@contoso.test"
    assert hosts["MWEB1"]["Launchers"]["Mach2"]["Screen"] == "72%"
    assert hosts["MWEB1"]["MessageOk"] and not hosts["MWEB3"]["MessageOk"], "messages need V7.0 or NG"
    assert hosts["OWEB1"]["Tab"] == "Other"
    assert not d["live"]["fresh"]["stale"]
    again = admin.get("/api/state", params={"since": d["live"]["stamp"]}).json()
    assert again["fleet"] is None, "an unchanged fleet is not sent again"


def test_kiosk_names_are_checked(admin):
    assert admin.post("/api/kiosks/..%2F..%2Fetc/live", {}).status_code in (400, 404)
    assert admin.post("/api/kiosks/bad$name/live", {}).status_code == 400
    assert admin.post("/api/kiosks/NOSUCH1/live", {}).status_code == 404
    assert admin.post("/api/kiosks/MWEB1/format-disk", {}).status_code == 404


# ---------------------------------------------------------------------------
# Doing things to a kiosk
# ---------------------------------------------------------------------------
def test_control_files(admin, fleet):
    ng = fleet["dirs"]["ng"]
    for action, file in (("reload", "refresh.txt"), ("relaunch", "relaunch.txt"), ("stop", "kill.txt")):
        r, j = admin.job("MWEB1", action, {"screen": "S1", "kind": "NG"})
        assert j and j["ok"] and "taken" in j["detail"], (action, j)
        taken = (ng / f"taken.{file}").read_text()
        assert "webadmin (admin)" in taken, "control files say who asked"
    r, j = admin.job("MWEB1", "hold", {"screen": "S1", "kind": "NG"})
    assert j["ok"] and (ng / "hold.txt").exists(), "hold.txt stays"
    assert admin.get("/api/state").json()["live"]["hold"]["MWEB1"] is True
    r, j = admin.job("MWEB1", "resume", {"screen": "S1", "kind": "NG"})
    assert j["ok"] and not (ng / "hold.txt").exists()


def test_live_read(admin):
    r, j = admin.job("PWEB1", "live")
    assert j["ok"], j
    lines = {l["Label"]: l["Value"] for l in j["result"]["lines"]}
    assert any("SHOWING as kiosk@contoso.test" in v for v in lines.values())
    assert lines["Shows"] == "https://app.powerbi.test/report"
    assert admin.get("/api/state").json()["live"]["live"]["PWEB1"]["Lines"], "the reading is shared"


def test_screenshot(admin):
    r, j = admin.job("MWEB1", "snapshot", {"screen": "S1", "kind": "NG"})
    assert j["ok"], j
    name = j["result"]["file"]
    img = admin.get(f"/api/snapshots/{name}")
    assert img.status_code == 200 and img.headers["content-type"] == "image/png" and img.content[:4] == b"\x89PNG"
    assert admin.get("/api/snapshots/..%2Fkfw.sqlite3").status_code == 404


def test_log(admin):
    r, j = admin.job("MWEB1", "log", {"screen": "S1", "kind": "NG"})
    assert j["ok"], j
    assert any("The dashboard is on screen." in l for l in j["result"]["lines"])


def test_password_hand_over(admin, fleet):
    secret = "Kiosk-Pass-9876!"
    r = admin.post("/api/kiosks/PWEB1/password", {"password": secret, "password2": "different"})
    assert r.status_code == 400
    r, j = admin.job("PWEB1", "password", {"password": secret, "password2": secret})
    assert j["ok"] and "stored" in j["detail"], j
    assert (fleet["dirs"]["pbi"] / "taken.seed").read_text() == secret
    blob = json.dumps(admin.app.state.kfw.db.audit_entries())
    assert secret not in blob, "a password is never in the audit log"
    assert secret not in (fleet["data"] / "kfw.sqlite3").read_bytes().decode("latin-1")


def test_config_editor(admin, fleet):
    r, j = admin.job("MWEB1", "config-read", {"kind": "NG", "instance": "S1"})
    assert j["ok"] and not j["result"]["isNew"]
    fields = {f["Key"]: f for f in j["result"]["fields"]}
    assert fields["DisplayURL"]["Value"] == "http://station:302/ord/dashboard" and not fields["DisplayURL"]["Advanced"]

    r, j = admin.job("MWEB1", "config-write", {"kind": "NG", "instance": "S1", "values": {"DisplayURL": "http://station:302/ord/other", "UserName": "operator", "Sneaky": "x"}})
    assert j["ok"], j
    saved = json.loads((fleet["dirs"]["ng"] / "MWEB1.json").read_text())
    assert saved["DisplayURL"] == "http://station:302/ord/other"
    assert "Sneaky" not in saved, "only the file's own keys can be set"
    assert list(fleet["dirs"]["ng"].glob("MWEB1.json.bak-*")), "the old one is kept"

    # A new kiosk: the config comes from EXAMPLE.json.
    r, j = admin.job("NEWWEB1", "config-read", {"kind": "WEB", "instance": ""})
    assert j["ok"] and j["result"]["isNew"], j
    r, j = admin.job("NEWWEB1", "config-write", {"kind": "WEB", "instance": "S1", "values": {"DisplayURL": "https://intranet.test/board"}})
    assert j["ok"] and j["result"]["isNew"], j
    cfg = json.loads((docs(fleet["root"], "NEWWEB1") / "WebLauncher" / "S1" / "NEWWEB1.json").read_text())
    assert cfg["DisplayURL"] == "https://intranet.test/board" and cfg["LogName"] == "WebLauncher_NEWWEB1.log"

    # One launcher per screen.
    r, j = admin.job("MWEB1", "config-write", {"kind": "PBI", "instance": "S1", "values": {"DisplayURL": "https://x", "UserName": "y"}})
    assert not j["ok"] and "one launcher per screen" in j["detail"]


def test_message(admin):
    r, j = admin.job("MWEB1", "message", {"text": "Lunch in five", "seconds": 30}, timeout=30)
    assert j and j["ok"] and j["result"]["status"] == "ACKNOWLEDGED", j
    r = admin.post("/api/kiosks/PWEB1/message", {"text": "hi"})
    assert r.status_code == 400, "only Mach2 kiosks show messages"


def test_restart(admin, fleet):
    r, j = admin.job("MWEB1", "restart", {"seconds": 30, "message": "Back in a minute"})
    assert j["ok"], j
    assert "Back in a minute" in (fleet["root"] / "MWEB1" / "restart-requested.txt").read_text()
    assert admin.post("/api/kiosks/MWEB1/restart", {"seconds": 99999}).status_code == 400


def test_busy(admin):
    r1 = admin.post("/api/kiosks/MWEB1/message", {"text": "one", "seconds": 30})
    assert r1.status_code == 202
    r2 = admin.post("/api/kiosks/MWEB1/reload", {})
    assert r2.status_code == 409 and "busy" in r2.json()["error"]
    jid = r1.json()["job"]
    for _ in range(100):
        if admin.get(f"/api/jobs/{jid}").json()["done"]:
            break
        time.sleep(0.1)


def test_jobs_are_private(admin, operator):
    r, j = operator.job("MWEB1", "reload")
    assert admin.get(f"/api/jobs/{j['id']}").status_code == 200, "an admin sees everyone's"
    r, j = admin.job("MWEB1", "reload")
    assert operator.get(f"/api/jobs/{j['id']}").status_code == 404, "an operator sees their own"


def test_connection_test(admin):
    r, j = admin.job("MWEB1", "test")
    assert j["ok"], j
    assert any("Mach2 Launcher NG" in l["Value"] for l in j["result"]["lines"])


# ---------------------------------------------------------------------------
# The deploy command builder
# ---------------------------------------------------------------------------
def test_deploy_command(admin):
    assert len(admin.get("/api/deploy/products").json()["products"]) == 4
    r = admin.post("/api/deploy/preview", {"product": "NG", "hosts": ["MWEB2", "MWEB1"], "restart": True, "warnSeconds": 30, "dryRun": True})
    d = r.json()
    assert d["command"] == "& '.\\Deploy-Mach2LauncherNG.ps1' -Hosts 'MWEB1','MWEB2' -Restart -RestartWarningSeconds 30 -VerifyMinutes 12 -WhatIf"
    bad = admin.post("/api/deploy/preview", {"product": "NG", "hosts": ["MWEB1'; Remove-Item C:\\ -Recurse; '"]})
    assert bad.status_code == 400 and "not a kiosk name" in bad.json()["error"]
    assert admin.post("/api/deploy/preview", {"product": "NG", "hosts": ["MWEB1"], "kioskUser": "x'; evil"}).status_code == 400


# ---------------------------------------------------------------------------
# Accounts
# ---------------------------------------------------------------------------
def test_users(admin):
    weak = admin.post("/api/users", {"name": "nightshift", "role": "operator", "password": "short", "password2": "short"})
    assert weak.status_code == 400
    r = admin.post("/api/users", {"name": "nightshift", "role": "operator", "password": "Night-Shift-2026!", "password2": "Night-Shift-2026!", "mustChange": True})
    assert r.status_code == 200
    assert admin.post("/api/users", {"name": "NightShift", "role": "operator", "password": "Night-Shift-2026!", "password2": "Night-Shift-2026!"}).status_code == 409
    names = {u["name"]: u for u in admin.get("/api/users").json()["users"]}
    assert names["nightshift"]["mustChange"]

    # They must choose their own password before anything else.
    n = Api(TestClient(admin.app))
    assert n.login("nightshift", "Night-Shift-2026!").json()["mustChange"]
    assert n.get("/api/state").status_code == 428
    assert n.post("/api/me/password", {"current": "wrong", "password": "Own-Choice-2026?", "password2": "Own-Choice-2026?"}).status_code == 400
    assert n.post("/api/me/password", {"current": "Night-Shift-2026!", "password": "Own-Choice-2026?", "password2": "Own-Choice-2026?"}).status_code == 200
    assert n.get("/api/state").status_code == 200

    # A role change or disabling takes effect at once.
    assert admin.post("/api/users/nightshift", {"role": "admin"}).status_code == 200
    assert n.get("/api/me").json()["role"] == "admin"
    assert admin.post("/api/users/nightshift", {"disabled": True}).status_code == 200
    assert n.get("/api/state").status_code == 401
    assert Api(TestClient(admin.app)).login("nightshift", "Own-Choice-2026?").status_code == 401

    assert admin.delete("/api/users/nightshift").status_code == 200
    assert "nightshift" not in {u["name"] for u in admin.get("/api/users").json()["users"]}
    acts = {e["Action"] for e in audit(admin)}
    assert {"user-add", "user-change", "user-remove", "password-change"} <= acts


def test_last_admin_is_kept(admin):
    assert admin.post("/api/users/webadmin", {"role": "operator"}).status_code == 409
    assert admin.post("/api/users/webadmin", {"disabled": True}).status_code == 409
    assert admin.delete("/api/users/webadmin").status_code == 409


def test_import_powershell_accounts(admin, tmp_path):
    from kfw.auth import hash_password
    from kfw.db import import_web_users
    rec = hash_password("Imported-Pass-11!")
    f = tmp_path / "web-users.json"
    f.write_text(json.dumps({"Version": 1, "Users": [dict(rec, Name="oldtimer", Role="operator", Disabled=False)]}))
    assert import_web_users(admin.app.state.kfw.db, f) == ["oldtimer"]
    assert Api(TestClient(admin.app)).login("oldtimer", "Imported-Pass-11!").status_code == 200


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
def test_kiosk_list_upload(admin, fleet):
    s = admin.get("/api/settings").json()
    assert not s["kioskList"]["exists"]
    assert admin.get("/api/state").json()["live"]["kioskList"] is False
    bad = admin.c.post("/api/settings/kiosk-list", files={"file": ("list.exe", b"MZ")}, headers={"X-Fleet-Csrf": admin.csrf})
    assert bad.status_code == 400
    body = b"Host,Location,Type,HasMwst,Active\nMWEB1,LINE1,Mach2,Y,\nPWEB1,APU1,PBI,,\nOLD1,X,Mach2,Y,N\n"
    r = admin.c.post("/api/settings/kiosk-list", files={"file": ("kiosks.csv", body)}, headers={"X-Fleet-Csrf": admin.csrf})
    assert r.status_code == 200 and r.json()["kiosks"] == 2, r.text
    s = admin.get("/api/settings").json()["kioskList"]
    assert s["included"] == 2 and s["inactive"] == 1
    assert admin.get("/api/settings/kiosk-list").content == body


def test_audit_search_and_csv(admin):
    admin.job("MWEB1", "reload")
    hits = audit(admin, "reload")
    assert hits and all("reload" in json.dumps(h).lower() for h in hits)
    csv_text = admin.get("/api/audit.csv").text
    assert csv_text.startswith("\ufeffTime,User,Role") and "reload" in csv_text
