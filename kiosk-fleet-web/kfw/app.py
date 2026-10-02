"""The web app: the page, signing in, and the API behind it.

Everyone signs in with an account of this app (no Windows / AD sign-in).
Sessions are an HttpOnly, SameSite=Strict cookie, Secure over HTTPS; every
change also needs the session's CSRF token in X-Fleet-Csrf and, from a
browser, the page's own origin. Roles are checked here on every request, so a
hand-made request gets 403 and an audit entry, not an action.
"""
from __future__ import annotations

import csv
import hmac
import io
import ipaddress
import json
import re
import shutil
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse

from . import __version__, auth
from .actions import CONFIG_REQUIRED, DEPLOY_PRODUCTS, ActionContext, deploy_command, snapshot_path
from .config import Settings, load_settings
from .fleetstate import KIND_OF_SCREEN_LAUNCHER, TAB_KINDS, freshness
from .kiosk_fs import clean_host
from .kiosklist import import_kiosk_list
from .services import AppState

COOKIE = "kfw_session"
MAX_BODY = 256 * 1024

CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; "
       "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

KIOSK_ACTIONS = {
    "live": {"perm": "live", "label": "reading", "launcher": True, "job": "live"},
    "snapshot": {"perm": "snapshot", "label": "taking a screenshot", "launcher": True, "job": "snapshot"},
    "reload": {"perm": "reload", "label": "reloading the page", "launcher": True, "job": "control", "file": "refresh.txt"},
    "relaunch": {"perm": "relaunch", "label": "restarting the browser", "launcher": True, "job": "control", "file": "relaunch.txt"},
    "hold": {"perm": "hold", "label": "holding", "launcher": True, "job": "control", "file": "hold.txt"},
    "resume": {"perm": "resume", "label": "carrying on", "launcher": True, "job": "control", "file": "hold.txt", "remove": True},
    "stop": {"perm": "stop", "label": "stopping the launcher", "launcher": True, "job": "control", "file": "kill.txt"},
    "log": {"perm": "log", "label": "reading the log", "launcher": True, "job": "log"},
    "password": {"perm": "password", "label": "setting the password", "launcher": True, "job": "password"},
    "restart": {"perm": "restart", "label": "restarting", "job": "restart"},
    "message": {"perm": "message", "label": "sending a message", "job": "message"},
    "config-read": {"perm": "config", "label": "reading the config", "any_host": True, "job": "config-read"},
    "config-write": {"perm": "config", "label": "writing the config", "any_host": True, "job": "config-write"},
    "test": {"perm": "settings", "label": "testing the connection", "any_host": True, "job": "test"},
}


class BadRequest(HTTPException):
    def __init__(self, detail: str, status: int = 400):
        super().__init__(status_code=status, detail=detail)


def create_app(settings: Settings | None = None, background: bool = True) -> FastAPI:
    settings = settings or load_settings()
    state = AppState(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        state.bootstrap(lambda s: print(s, flush=True))
        if background:
            state.start_background()
        state.db.audit(action="server-start", result="ok", detail=f"Kiosk Fleet Web {__version__}")
        yield
        state.stop_background()
        state.db.audit(action="server-stop", result="ok")

    app = FastAPI(title="Kiosk Fleet Web", version=__version__, lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.kfw = state
    web = settings.web_dir

    # --- plumbing ---------------------------------------------------------
    def is_https(req: Request) -> bool:
        if settings.trust_proxy:
            proto = req.headers.get("x-forwarded-proto", "").split(",")[0].strip().lower()
            if proto:
                return proto == "https"
        return req.url.scheme == "https"

    def client_ip(req: Request) -> str:
        if settings.trust_proxy:
            fwd = req.headers.get("x-forwarded-for", "")
            if fwd:
                return fwd.split(",")[0].strip()
        return req.client.host if req.client else ""

    def is_local(req: Request) -> bool:
        try:
            return ipaddress.ip_address(client_ip(req)).is_loopback
        except ValueError:
            return False

    def same_origin(req: Request) -> bool:
        origin = req.headers.get("origin")
        if not origin:
            return True
        host = req.headers.get("x-forwarded-host") if settings.trust_proxy and req.headers.get("x-forwarded-host") else req.headers.get("host", "")
        m = re.match(r"^https?://([^/]+)$", origin.strip())
        return bool(m) and m.group(1).lower() == host.split(",")[0].strip().lower()

    def secure_cookie(req: Request) -> bool:
        if settings.secure_cookies == "true":
            return True
        if settings.secure_cookies == "false":
            return False
        return is_https(req)

    def set_cookie(resp: Response, req: Request, token: str) -> None:
        resp.set_cookie(COOKIE, token, httponly=True, samesite="strict", secure=secure_cookie(req), path="/")

    def get_session(req: Request) -> dict | None:
        return state.db.session(req.cookies.get(COOKIE, ""), settings.idle_minutes, settings.session_hours)

    def need_session(req: Request) -> dict:
        s = get_session(req)
        if not s:
            raise BadRequest("Sign in first.", 401)
        if req.method not in ("GET", "HEAD"):
            if not same_origin(req):
                raise BadRequest("wrong origin", 403)
            sent = req.headers.get("x-fleet-csrf", "")
            if not sent or not hmac.compare_digest(sent, s["csrf"]):
                raise BadRequest("The page is out of date - reload it.", 403)
        return s

    def need(req: Request, s: dict, perm: str, action: str = "", target: str = "") -> None:
        if not auth.allowed(s["role"], perm):
            state.db.audit(s["user"], s["role"], client_ip(req), action or perm, target, "refused", "not allowed for this role")
            raise BadRequest("Your role cannot do that.", 403)

    async def body(req: Request) -> dict:
        raw = await req.body()
        if not raw:
            return {}
        if len(raw) > MAX_BODY:
            raise BadRequest("too large")
        if not req.headers.get("content-type", "").startswith("application/json"):
            raise BadRequest("send JSON")
        try:
            data = json.loads(raw)
        except ValueError:
            raise BadRequest("that is not JSON")
        if not isinstance(data, dict):
            raise BadRequest("send a JSON object")
        return data

    def text(b: dict, name: str, maxlen: int = 400) -> str:
        v = b.get(name)
        if v is None:
            return ""
        v = str(v)
        if len(v) > maxlen:
            raise BadRequest(f"{name} is too long")
        return v

    def flag(b: dict, name: str) -> bool:
        return b.get(name) is True

    def integer(b: dict, name: str, default: int, lo: int, hi: int, say: str) -> int:
        v = b.get(name)
        if v is None or str(v).strip() == "":
            return default
        try:
            n = int(str(v).strip())
        except ValueError:
            raise BadRequest(say)
        if n < lo or n > hi:
            raise BadRequest(say)
        return n

    def me(s: dict | None, req: Request) -> dict:
        return {
            "user": s["user"] if s else None, "role": s["role"] if s else None, "csrf": s["csrf"] if s else None,
            "allowed": auth.allowed_actions(s["role"]) if s else [], "mustChange": bool(s and s.get("must_change")),
            "methods": {"windows": False, "local": True}, "setup": state.setup_token is not None,
            "insecure": not is_https(req) and not is_local(req), "version": __version__, "idleMinutes": settings.idle_minutes,
        }

    @app.exception_handler(HTTPException)
    async def http_error(req: Request, exc: HTTPException):
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)

    @app.middleware("http")
    async def headers(req: Request, call_next):
        resp = await call_next(req)
        h = resp.headers
        h.setdefault("X-Content-Type-Options", "nosniff")
        h.setdefault("X-Frame-Options", "DENY")
        h.setdefault("Referrer-Policy", "no-referrer")
        h.setdefault("Content-Security-Policy", CSP)
        h.setdefault("Cache-Control", "no-store")
        if is_https(req):
            h.setdefault("Strict-Transport-Security", "max-age=31536000")
        return resp

    # --- the page ---------------------------------------------------------
    def static(name: str, kind: str):
        return FileResponse(web / name, media_type=kind, headers={"Cache-Control": "no-cache"})

    @app.get("/")
    @app.get("/index.html")
    @app.get("/setup")
    def index():
        return static("index.html", "text/html; charset=utf-8")

    @app.get("/app.js")
    def app_js():
        return static("app.js", "text/javascript; charset=utf-8")

    @app.get("/app.css")
    def app_css():
        return static("app.css", "text/css; charset=utf-8")

    @app.get("/favicon.ico")
    def favicon():
        return Response(status_code=204)

    @app.get("/healthz")
    def healthz():
        return {"ok": True, "version": __version__, "fleet": bool(state.cache.state and state.cache.state.get("Ok"))}

    # --- signing in and out -----------------------------------------------
    @app.post("/api/login")
    async def login(req: Request):
        if not same_origin(req):
            raise BadRequest("wrong origin", 403)
        b = await body(req)
        name = text(b, "user", 64).strip()
        password = text(b, "password", 256)
        ip = client_ip(req)
        ukey, ikey = "u:" + name.lower(), "ip:" + ip
        if state.db.locked(ukey) or state.db.locked(ikey):
            state.db.audit(name, "", ip, "sign-in", "", "refused", "locked out for now")
            raise BadRequest("Too many wrong passwords. Try again in 15 minutes.", 429)
        u = state.db.check_login(name, password) if name and password else None
        if not u:
            state.db.add_failure(ukey, 5)
            state.db.add_failure(ikey, 20)
            state.db.audit(name, "", ip, "sign-in", "", "failed")
            raise BadRequest("That name and password do not match.", 401)
        state.db.clear_failures(ukey)
        token, _ = state.db.new_session(u["name"], ip, req.headers.get("user-agent", ""))
        s = state.db.session(token, settings.idle_minutes, settings.session_hours)
        state.db.audit(u["name"], u["role"], ip, "sign-in", "", "ok")
        resp = JSONResponse(me(s, req))
        set_cookie(resp, req, token)
        return resp

    @app.post("/api/setup")
    async def setup(req: Request):
        """The first admin account, with the one-time link from the server's log."""
        if not same_origin(req):
            raise BadRequest("wrong origin", 403)
        b = await body(req)
        if state.setup_token is None or state.db.user_count() > 0:
            raise BadRequest("Setup is done already. Sign in.", 409)
        if not hmac.compare_digest(text(b, "token", 100), state.setup_token):
            state.db.audit("", "", client_ip(req), "setup", "", "refused", "wrong setup token")
            raise BadRequest("That setup link is not right. Use the one in the server's log.", 403)
        name, p1, p2 = text(b, "user", 64).strip(), text(b, "password", 256), text(b, "password2", 256)
        if not auth.valid_user_name(name):
            raise BadRequest("An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.")
        if p1 != p2:
            raise BadRequest("The two passwords did not match.")
        problem = auth.password_problem(p1, name)
        if problem:
            raise BadRequest(f"The password needs {problem}.")
        state.db.add_user(name, "admin", p1)
        state.setup_token = None
        ip = client_ip(req)
        state.db.audit(name, "admin", ip, "setup", name, "ok", "first admin account")
        token, _ = state.db.new_session(name, ip, req.headers.get("user-agent", ""))
        resp = JSONResponse(me(state.db.session(token, settings.idle_minutes, settings.session_hours), req))
        set_cookie(resp, req, token)
        return resp

    @app.get("/api/me")
    def get_me(req: Request):
        s = get_session(req)
        return JSONResponse(me(s, req), status_code=200 if s else 401)

    @app.post("/api/logout")
    def logout(req: Request):
        s = get_session(req)
        if s and hmac.compare_digest(req.headers.get("x-fleet-csrf", ""), s["csrf"]):
            state.db.end_session(s["token_hash"])
            state.db.audit(s["user"], s["role"], client_ip(req), "sign-out", "", "ok")
        resp = JSONResponse({"ok": True})
        resp.delete_cookie(COOKIE, path="/")
        return resp

    @app.post("/api/me/password")
    async def change_own_password(req: Request):
        s = need_session(req)
        b = await body(req)
        current, p1, p2 = text(b, "current", 256), text(b, "password", 256), text(b, "password2", 256)
        if not state.db.check_login(s["user"], current):
            state.db.audit(s["user"], s["role"], client_ip(req), "password-change", s["user"], "failed", "current password wrong")
            raise BadRequest("The current password is not right.")
        if p1 != p2:
            raise BadRequest("The two new passwords did not match.")
        problem = auth.password_problem(p1, s["user"])
        if problem:
            raise BadRequest(f"The new password needs {problem}.")
        state.db.set_password(s["user"], p1)
        state.db.end_sessions_of(s["user"], except_hash=s["token_hash"])
        state.db.audit(s["user"], s["role"], client_ip(req), "password-change", s["user"], "ok")
        return {"ok": True}

    # --- the fleet --------------------------------------------------------
    @app.get("/api/state")
    def get_state(req: Request, since: str = ""):
        s = need_session(req)
        if s.get("must_change"):
            raise BadRequest("Change your password first.", 428)
        cache = state.cache
        fresh = freshness(cache.state, settings.stale_minutes)
        jobs, r = state.jobs, state.runner
        dyn = {
            "stamp": cache.stamp,
            "fresh": {"text": fresh["text"], "stale": fresh["stale"], "lastRun": fresh["lastRun"]},
            "busy": dict(jobs.busy), "live": dict(jobs.live), "hold": dict(jobs.hold), "snapshots": dict(jobs.snapshots),
            "configWritten": sorted(jobs.config_written), "run": r.status_json(), "lastRun": r.last,
            "autoscan": {"on": r.autoscan_on, "minutes": settings.autoscan_minutes, "nextIn": state.next_scan_minutes()},
            "credential": {"ok": not state.credential_note, "note": state.credential_note},
            "kioskList": bool(settings.resolve_kiosk_list()),
            "clock": datetime.now().strftime("%a %d %b  %H:%M:%S"),
            "restart": {"message": settings.restart_message, "seconds": settings.restart_warning_seconds},
            "remoteControl": settings.sccm_site_server.strip().strip("\\"),
            "rootTemplate": settings.root_template, "csv": str(settings.events_csv),
        }
        fleet = "null" if since and since == cache.stamp and cache.state else cache.view_json
        return Response('{"fleet":' + fleet + ',"live":' + json.dumps(dyn, default=str) + "}", media_type="application/json")

    def resolve_target(k: dict, screen: str, kind: str) -> tuple[str, str]:
        if screen:
            if not re.match(r"^S\d{1,2}$", screen) or kind not in ("NG", "PBI", "WEB"):
                raise BadRequest("pick a screen like S1 and its launcher")
            if not any(sc["Screen"] == screen and KIND_OF_SCREEN_LAUNCHER[sc["Launcher"]] == kind for sc in k.get("Screens") or []):
                raise BadRequest(f"{k['Host']} has no {kind} screen {screen}")
            return screen, kind
        if k.get("Screens") or k.get("Ng") or k.get("Pbi") or k.get("Web"):
            return "", "ALL"
        return "", TAB_KINDS.get(k.get("Tab") or "", "")

    @app.post("/api/kiosks/{host}/{action}")
    async def kiosk_action(req: Request, host: str, action: str):
        s = need_session(req)
        spec = KIOSK_ACTIONS.get(action)
        if not spec:
            raise BadRequest("no such action", 404)
        need(req, s, spec["perm"], action, host)
        name = clean_host(host)
        if not name:
            raise BadRequest("that is not a kiosk name")
        k = state.cache.kiosk(name)
        if k:
            name = k["Host"]
        elif not spec.get("any_host"):
            raise BadRequest(f"{name} is not in the last scan", 404)
        if name in state.jobs.busy:
            raise BadRequest(f"{name} is busy: {state.jobs.busy[name]}", 409)
        if settings.uses_smb and not settings.has_credential and action != "test":
            raise BadRequest(f"The server cannot reach kiosks: {state.credential_note}", 503)

        b = await body(req)
        ctx = ActionContext(settings=settings, fs=state.fs, target=name, who=f"{s['user']} ({s['role']})")
        detail = ""
        if spec.get("launcher"):
            screen, kind = resolve_target(k, text(b, "screen", 4), text(b, "kind", 4))
            if not kind:
                raise BadRequest(f"{name} has no launcher")
            ctx.screen, ctx.kind = screen, kind
            detail = f"{screen} {kind}" if screen else "all screens"
        if spec.get("file"):
            ctx.params.update(file=spec["file"], remove=bool(spec.get("remove")))
        if action == "log":
            ctx.params["lines"] = 60
        elif action == "password":
            if ctx.kind == "WEB":
                raise BadRequest("a web page screen signs in to nothing")
            p1, p2 = text(b, "password", 256), text(b, "password2", 256)
            if not p1:
                raise BadRequest("Type the password first.")
            if p1 != p2:
                raise BadRequest("The two did not match. Nothing was changed.")
            ctx.secret = p1
        elif action == "restart":
            secs = integer(b, "seconds", settings.restart_warning_seconds, 0, 3600, "The countdown has to be a whole number of seconds, 0 to 3600.")
            ctx.params.update(seconds=secs, message=text(b, "message", 500).strip())
            detail = f"countdown {secs}s"
        elif action == "message":
            if not (k.get("Ng") or k.get("Tab") == "Mach2"):
                raise BadRequest("Only Mach2 kiosks have a watchdog to show a message.")
            msg = text(b, "text", 1000).strip()
            if not msg:
                raise BadRequest("Type the message first.")
            ctx.params.update(text=msg, seconds=integer(b, "seconds", 60, 5, 900, "Between 5 and 900 seconds."))
            detail = msg
        elif action in ("config-read", "config-write"):
            kind = text(b, "kind", 4)
            if kind not in ("NG", "PBI", "WEB"):
                raise BadRequest("which launcher: NG, PBI or WEB")
            instance = text(b, "instance", 4).strip().upper()
            if action == "config-write" and not re.match(r"^S\d{1,2}$", instance):
                raise BadRequest("A screen folder is named like S1 or S2.")
            if instance and not re.match(r"^S\d{1,2}$", instance):
                raise BadRequest("A screen folder is named like S1 or S2.")
            ctx.kind = kind
            ctx.params["instance"] = instance
            detail = f"{instance} {kind}"
            if action == "config-write":
                values = {}
                for key, v in (b.get("values") or {}).items():
                    if not re.match(r"^[A-Za-z][A-Za-z0-9_]{0,63}$", str(key)):
                        raise BadRequest(f"'{key}' is not a setting")
                    v = "" if v is None else str(v)
                    if len(v) > 4000:
                        raise BadRequest(f"{key} is too long")
                    values[key] = v.strip()
                missing = [m for m in CONFIG_REQUIRED[kind] if m in values and not values[m]]
                if missing:
                    raise BadRequest("Still empty: " + ", ".join(missing) + ".")
                p1, p2 = text(b, "password", 256), text(b, "password2", 256)
                if p1 != p2:
                    raise BadRequest("The two passwords did not match. Nothing was saved.")
                if p1 and kind != "WEB":
                    ctx.secret = p1
                ctx.params["values"] = values
                detail = f"{instance} {kind}; " + ", ".join(f"{key}={values[key]}" for key in sorted(values)) + ("; new sign-in password" if ctx.secret else "")

        job = state.jobs.start(spec["job"], spec["label"], name, ctx, s, client_ip(req), action)
        state.db.audit(s["user"], s["role"], client_ip(req), action, name, "started", detail)
        return JSONResponse({"job": job.id, "label": spec["label"]}, status_code=202)

    @app.get("/api/jobs/{job_id}")
    def get_job(req: Request, job_id: str):
        s = need_session(req)
        job = state.jobs.get(job_id) if re.match(r"^[A-Za-z0-9_-]{10,40}$", job_id) else None
        if not job or (job.user.lower() != s["user"].lower() and s["role"] != "admin"):
            raise BadRequest("no such job", 404)
        return state.jobs.to_json(job)

    @app.get("/api/snapshots/{name}")
    def get_snapshot(req: Request, name: str):
        need_session(req)
        p = snapshot_path(settings, name)
        if not p:
            raise BadRequest("no such picture", 404)
        return FileResponse(p, media_type="image/png")

    # --- scans and the Activity view ---------------------------------------
    @app.get("/api/run")
    def get_run(req: Request):
        need_session(req)
        try:
            frm = int(req.query_params.get("from", "0"))
        except ValueError:
            frm = 0
        return state.runner.read_log(frm)

    @app.post("/api/scan")
    def scan(req: Request):
        s = need_session(req)
        need(req, s, "scan")
        why = state.runner.start_scan(session=s)
        state.db.audit(s["user"], s["role"], client_ip(req), "scan", "", "refused" if why else "started", why or "")
        if why:
            raise BadRequest(why, 409)
        return JSONResponse({"ok": True}, status_code=202)

    @app.post("/api/autoscan")
    async def autoscan(req: Request):
        s = need_session(req)
        need(req, s, "autoscan")
        on = flag(await body(req), "on")
        why = state.runner.enable_autoscan() if on else None
        if not on:
            state.runner.autoscan_on = False
        state.db.audit(s["user"], s["role"], client_ip(req), "autoscan", "on" if on else "off", "refused" if why else "ok", why or "")
        if why:
            raise BadRequest(why, 409)
        return {"on": state.runner.autoscan_on}

    @app.post("/api/run/stop")
    def stop_run(req: Request):
        s = need_session(req)
        need(req, s, "stoprun")
        title = state.runner.run.title if state.runner.run else ""
        why = state.runner.stop(s)
        if why:
            raise BadRequest(why, 409)
        state.db.audit(s["user"], s["role"], client_ip(req), "stop-run", title, "ok")
        return {"ok": True}

    @app.get("/api/reports")
    def reports(req: Request):
        need_session(req)
        rows = [{"name": p.name, "when": datetime.fromtimestamp(p.stat().st_mtime).strftime("%a %d %b %H:%M"),
                 "kind": "Scan output", "size": p.stat().st_size} for p in state.runner.reports()]
        return {"reports": rows}

    @app.get("/api/reports/{name}")
    def report(req: Request, name: str):
        need_session(req)
        p = next((x for x in state.runner.reports() if x.name == name), None)
        if not p:
            raise BadRequest("no such report", 404)
        return FileResponse(p, media_type="text/plain; charset=utf-8", filename=p.name)

    # --- deploy: the command for the PowerShell deploy scripts --------------
    @app.get("/api/deploy/products")
    def products(req: Request):
        s = need_session(req)
        need(req, s, "deploy")
        return {"products": [{"id": k, "name": v["Name"], "tab": v["Tab"], "note": v["Note"]} for k, v in DEPLOY_PRODUCTS.items()]}

    @app.post("/api/deploy/preview")
    async def deploy_preview(req: Request):
        s = need_session(req)
        need(req, s, "deploy")
        b = await body(req)
        hosts = b.get("hosts") or []
        if not isinstance(hosts, list) or len(hosts) > 500:
            raise BadRequest("too many kiosks at once")
        try:
            d = deploy_command(
                text(b, "product", 10), [str(h) for h in hosts], rollback=flag(b, "rollback"), restart=flag(b, "restart"),
                warn_seconds=integer(b, "warnSeconds", settings.restart_warning_seconds, 0, 600, "The countdown has to be 0 to 600 seconds."),
                verify_minutes=integer(b, "verifyMinutes", 12, 2, 60, "The wait has to be 2 to 60 minutes."),
                force=flag(b, "force"), update_config=flag(b, "updateConfig"), keep_legacy=flag(b, "keepLegacy"),
                keep_watchdog=flag(b, "keepWatchdog"), register_task=flag(b, "registerTask"),
                kiosk_user=text(b, "kioskUser", 104).strip(), dry_run=flag(b, "dryRun"))
        except ValueError as e:
            raise BadRequest(str(e))
        return {"command": d["Command"], "preview": d["Preview"], "title": d["Title"], "hosts": d["Hosts"]}

    # --- audit --------------------------------------------------------------
    @app.get("/api/audit")
    def audit(req: Request, q: str = ""):
        s = need_session(req)
        need(req, s, "audit")
        return {"entries": state.db.audit_entries(400, q[:100])}

    @app.get("/api/audit.csv")
    def audit_csv(req: Request):
        s = need_session(req)
        need(req, s, "audit")

        def rows():
            buf = io.StringIO()
            w = csv.writer(buf)
            w.writerow(["Time", "User", "Role", "Ip", "Action", "Target", "Result", "Detail"])
            yield "﻿" + buf.getvalue()
            for r in state.db.audit_all():
                buf.seek(0)
                buf.truncate()
                w.writerow(list(r))
                yield buf.getvalue()
        return StreamingResponse(rows(), media_type="text/csv; charset=utf-8",
                                 headers={"Content-Disposition": 'attachment; filename="kiosk-fleet-audit.csv"'})

    # --- users ----------------------------------------------------------------
    @app.get("/api/users")
    def users(req: Request):
        s = need_session(req)
        need(req, s, "users")
        sessions = state.db.active_sessions()
        out = []
        for u in state.db.users():
            out.append({"name": u["name"], "role": u["role"], "disabled": bool(u["disabled"]), "mustChange": bool(u["must_change"]),
                        "created": u["created"], "lastLogin": u["last_login"] or "",
                        "sessions": next((n for k, n in sessions.items() if k.lower() == u["name"].lower()), 0)})
        return {"users": out}

    def check_new_password(p1: str, p2: str, name: str) -> None:
        if p1 != p2:
            raise BadRequest("The two passwords did not match.")
        problem = auth.password_problem(p1, name)
        if problem:
            raise BadRequest(f"The password needs {problem}.")

    @app.post("/api/users")
    async def add_user(req: Request):
        s = need_session(req)
        need(req, s, "users", "user-add")
        b = await body(req)
        name, role = text(b, "name", 64).strip(), text(b, "role", 10)
        if not auth.valid_user_name(name):
            raise BadRequest("An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.")
        if role not in auth.ROLE_RANK:
            raise BadRequest("The role is operator or admin.")
        if state.db.user(name):
            raise BadRequest(f"There is an account called {name} already.", 409)
        p1, p2 = text(b, "password", 256), text(b, "password2", 256)
        check_new_password(p1, p2, name)
        state.db.add_user(name, role, p1, must_change=flag(b, "mustChange"))
        state.db.audit(s["user"], s["role"], client_ip(req), "user-add", name, "ok", role)
        return {"ok": True}

    @app.post("/api/users/{name}")
    async def change_user(req: Request, name: str):
        s = need_session(req)
        need(req, s, "users", "user-change", name)
        u = state.db.user(name)
        if not u:
            raise BadRequest("no such account", 404)
        name = u["name"]
        b = await body(req)
        changes = []
        last_admin = u["role"] == "admin" and not u["disabled"] and state.db.user_count(active_admins_only=True) <= 1
        if "role" in b:
            role = text(b, "role", 10)
            if role not in auth.ROLE_RANK:
                raise BadRequest("The role is operator or admin.")
            if role != u["role"]:
                if last_admin:
                    raise BadRequest("That is the last admin. Make another admin first.", 409)
                state.db.set_role(name, role)
                changes.append(f"role={role}")
        if "disabled" in b:
            dis = flag(b, "disabled")
            if dis != bool(u["disabled"]):
                if dis and last_admin:
                    raise BadRequest("That is the last admin. Make another admin first.", 409)
                if dis and name.lower() == s["user"].lower():
                    raise BadRequest("You cannot disable your own account.", 409)
                state.db.set_disabled(name, dis)
                if dis:
                    state.db.end_sessions_of(name)
                changes.append("disabled" if dis else "enabled")
        if b.get("password"):
            p1, p2 = text(b, "password", 256), text(b, "password2", 256)
            check_new_password(p1, p2, name)
            state.db.set_password(name, p1, must_change=flag(b, "mustChange"))
            state.db.end_sessions_of(name, except_hash=s["token_hash"] if name.lower() == s["user"].lower() else None)
            changes.append("new password" + (", to be changed at next sign-in" if flag(b, "mustChange") else ""))
        if b.get("signOut"):
            state.db.end_sessions_of(name, except_hash=s["token_hash"] if name.lower() == s["user"].lower() else None)
            changes.append("signed out everywhere")
        state.db.audit(s["user"], s["role"], client_ip(req), "user-change", name, "ok", "; ".join(changes) or "nothing changed")
        return {"ok": True, "changed": changes}

    @app.delete("/api/users/{name}")
    def delete_user(req: Request, name: str):
        s = need_session(req)
        need(req, s, "users", "user-remove", name)
        u = state.db.user(name)
        if not u:
            raise BadRequest("no such account", 404)
        if u["name"].lower() == s["user"].lower():
            raise BadRequest("You cannot remove your own account.", 409)
        if u["role"] == "admin" and not u["disabled"] and state.db.user_count(active_admins_only=True) <= 1:
            raise BadRequest("That is the last admin.", 409)
        state.db.remove_user(u["name"])
        state.db.audit(s["user"], s["role"], client_ip(req), "user-remove", u["name"], "ok")
        return {"ok": True}

    # --- settings -------------------------------------------------------------
    def kiosk_list_info() -> dict:
        p = settings.resolve_kiosk_list()
        if not p:
            return {"path": "", "exists": False}
        info = {"path": str(p), "exists": p.exists(), "uploaded": p.parent == settings.data_dir and p.name.startswith("kiosk-list.")}
        if p.exists():
            info["modified"] = datetime.fromtimestamp(p.stat().st_mtime).strftime("%a %d %b %Y %H:%M")
            try:
                kiosks, stats = import_kiosk_list(p, settings.kiosk_list_sheet, settings.include_all_hosts)
                info.update(rows=stats.rows, included=stats.included, inactive=stats.inactive, notFlagged=stats.not_flagged,
                            watchdog=sum(1 for k in kiosks if k.runs_watchdog),
                            sample=[{"host": k.host, "location": k.location, "type": k.type} for k in kiosks[:500]])
            except Exception as e:  # noqa: BLE001 - shown to the admin as it is
                info["error"] = str(e)
        return info

    @app.get("/api/settings")
    def get_settings(req: Request):
        s = need_session(req)
        need(req, s, "settings")
        st = settings
        return {
            "kioskList": kiosk_list_info(),
            "kioskListFixed": bool(st.kiosk_list),
            "kiosks": {"rootTemplate": st.root_template, "smb": st.uses_smb, "user": st.kiosk_user,
                       "credential": st.has_credential, "auth": st.smb_auth},
            "data": {"dir": str(st.data_dir), "csv": str(st.local_csv), "published": st.publish_csv},
            "collector": {"autoscanDefault": st.autoscan, "minutes": st.autoscan_minutes, "parallel": st.parallel_hosts,
                          "hostTimeout": st.host_timeout_seconds, "retentionDays": st.retention_days,
                          "trustedFrom": st.trusted_from_agent_version},
            "sessions": {"idleMinutes": st.idle_minutes, "hours": st.session_hours, "secureCookies": st.secure_cookies,
                         "trustProxy": st.trust_proxy},
            "version": __version__,
        }

    @app.post("/api/settings/kiosk-list")
    async def upload_kiosk_list(req: Request, file: UploadFile):
        s = need_session(req)
        need(req, s, "settings", "kiosk-list")
        if settings.kiosk_list:
            raise BadRequest("The kiosk list is set by KFW_KIOSK_LIST on the server; change it there.", 409)
        name = (file.filename or "").lower()
        ext = Path(name).suffix
        if ext not in (".xlsx", ".csv", ".txt"):
            raise BadRequest("Upload an .xlsx, .csv or .txt kiosk list.")
        data = await file.read(10 * 1024 * 1024 + 1)
        if len(data) > 10 * 1024 * 1024:
            raise BadRequest("That file is over 10 MB.")
        tmp = settings.data_dir / f"kiosk-list.upload{ext}"
        tmp.write_bytes(data)
        try:
            kiosks, stats = import_kiosk_list(tmp, settings.kiosk_list_sheet, settings.include_all_hosts)
        except Exception as e:  # noqa: BLE001
            tmp.unlink(missing_ok=True)
            raise BadRequest(f"That list could not be read: {e}")
        if not kiosks:
            tmp.unlink(missing_ok=True)
            raise BadRequest(f"That list has no kiosks to scan ({stats.rows} rows, {stats.inactive} not active, {stats.not_flagged} not flagged).")
        for old in settings.data_dir.glob("kiosk-list.*"):
            if old != tmp and not old.name.startswith("kiosk-list.upload"):
                old.unlink(missing_ok=True)
        shutil.move(str(tmp), str(settings.data_dir / f"kiosk-list{ext}"))
        state.db.audit(s["user"], s["role"], client_ip(req), "kiosk-list", file.filename or "", "ok",
                       f"{len(kiosks)} kiosks of {stats.rows} rows")
        return {"ok": True, "kiosks": len(kiosks), "rows": stats.rows}

    @app.get("/api/settings/kiosk-list")
    def download_kiosk_list(req: Request):
        s = need_session(req)
        need(req, s, "settings")
        p = settings.resolve_kiosk_list()
        if not p or not p.exists():
            raise BadRequest("no kiosk list", 404)
        return FileResponse(p, filename=p.name)

    @app.get("/api/{rest:path}")
    @app.post("/api/{rest:path}")
    def not_here(rest: str):
        raise BadRequest("not here", 404)

    return app

