"""The moving parts behind the page: the fleet as last read, kiosk actions on
worker threads, and long runs (the collector) as child processes whose output
the Activity view follows.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from . import auth
from .actions import ActionContext, run_action
from .config import Settings, settings_json
from .db import Database
from .fleetstate import fleet_view, freshness, read_fleet_state
from .kiosk_fs import KioskFS


def _stamp(path: Path) -> str:
    parts = []
    for p in (path, path.with_suffix(".status.json")):
        try:
            st = p.stat()
            parts.append(f"{st.st_mtime_ns}|{st.st_size}")
        except OSError:
            parts.append("none")
    return ";".join(parts)


class FleetCache:
    """The fleet as last read from the CSV, read again when the file changes."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self.lock = threading.Lock()
        self.stamp = ""
        self.state: dict | None = None
        self.view_json = "null"

    def refresh(self, force: bool = False) -> bool:
        path = self.settings.events_csv
        stamp = _stamp(path)
        if not force and stamp == self.stamp and self.state is not None:
            return False
        state = read_fleet_state(path)
        view = json.dumps(fleet_view(state), separators=(",", ":"), default=str)
        with self.lock:
            self.stamp, self.state, self.view_json = stamp, state, view
        return True

    def kiosk(self, host: str) -> dict | None:
        st = self.state
        if not st or not st.get("Ok"):
            return None
        return next((k for k in st["Hosts"] if k["Host"].lower() == host.lower()), None)


@dataclass
class Job:
    id: str
    action: str
    label: str
    target: str
    user: str
    role: str
    ip: str
    audit_action: str
    ctx: ActionContext
    started: float = field(default_factory=time.time)
    finished: float | None = None
    done: bool = False
    ok: bool | None = None
    detail: str = ""
    result: dict | None = None
    lines: list[str] = field(default_factory=list)


class Jobs:
    """Anything that touches a kiosk takes seconds, or half a minute when it
    is off: it runs on a worker thread and the page asks for it by id. One
    thing at a time per kiosk, for everyone."""

    def __init__(self, app_state: "AppState"):
        self.s = app_state
        self.pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="kiosk")
        self.lock = threading.Lock()
        self.jobs: dict[str, Job] = {}
        self.busy: dict[str, str] = {}
        self.live: dict[str, dict] = {}
        self.hold: dict[str, bool] = {}
        self.snapshots: dict[str, dict] = {}
        self.config_written: set[str] = set()

    def start(self, action: str, label: str, target: str, ctx: ActionContext, session: dict | None, ip: str, audit_action: str) -> Job:
        job = Job(id=uuid.uuid4().hex[:22], action=action, label=label, target=target,
                  user=(session or {}).get("user", ""), role=(session or {}).get("role", ""), ip=ip, audit_action=audit_action, ctx=ctx)
        ctx.say = job.lines.append
        with self.lock:
            self.jobs[job.id] = job
            if target:
                self.busy[target] = label
        self.pool.submit(self._run, job)
        return job

    def _run(self, job: Job) -> None:
        try:
            r = run_action(job.action, job.ctx)
        except Exception as e:  # noqa: BLE001 - a job always finishes with an answer
            r = {"Ok": False, "Detail": f"{type(e).__name__}: {e}"}
        job.result = r
        job.ok = bool(r.get("Ok"))
        job.detail = str(r.get("Detail") or "")
        job.finished = time.time()
        self._after(job)
        with self.lock:
            job.done = True
            self.busy.pop(job.target, None)
        if job.audit_action:
            result = ("waiting" if r.get("Waiting") else "ok") if job.ok else "failed"
            self.s.db.audit(job.user, job.role, job.ip, job.audit_action, job.target, result, job.detail)

    def _after(self, job: Job) -> None:
        r, t = job.result or {}, job.target
        if not r.get("Ok"):
            return
        if job.action == "live":
            self.live[t] = {"At": datetime.now().strftime("%H:%M:%S"), "Lines": r.get("Lines") or []}
            self.hold[t] = bool(r.get("Hold"))
        elif job.action == "control" and job.ctx.params.get("file") == "hold.txt":
            self.hold[t] = not job.ctx.params.get("remove")
        elif job.action == "snapshot" and r.get("File"):
            self.snapshots[t] = {"File": r["File"], "Caption": f"{r.get('Instance')} {datetime.now().strftime('%H:%M:%S')}  |  {r.get('State')}  |  {r.get('Url')}"}
        elif job.action == "config-write":
            self.config_written.add(t)
            self.live.pop(t, None)

    def get(self, job_id: str) -> Job | None:
        return self.jobs.get(job_id)

    def sweep(self) -> None:
        cutoff = time.time() - 15 * 60
        with self.lock:
            for jid in [j.id for j in self.jobs.values() if j.done and (j.finished or 0) < cutoff]:
                self.jobs.pop(jid, None)

    def to_json(self, job: Job) -> dict:
        r = job.result or {}
        extra = None
        if job.done and job.action == "test" and r.get("Lines"):
            extra = {"lines": r["Lines"]}
        elif job.done and r:
            a = job.action
            if a == "live":
                extra = {"lines": r.get("Lines") or [], "hold": bool(r.get("Hold"))}
            elif a == "log":
                extra = {"lines": r.get("Lines") or [], "path": r.get("Path") or ""}
            elif a == "snapshot":
                extra = {"file": r.get("File") or "", "instance": r.get("Instance") or "", "state": r.get("State") or "", "url": r.get("Url") or ""}
            elif a == "config-read":
                extra = {"kind": r.get("Kind"), "isNew": bool(r.get("IsNew")), "instance": r.get("Instance"), "instances": r.get("Instances") or [],
                         "password": r.get("Password"), "taken": r.get("Taken") or {}, "fields": r.get("Fields") or []}
            elif a == "config-write":
                extra = {"isNew": bool(r.get("IsNew")), "path": r.get("Path") or "", "password": r.get("Password") or ""}
            elif a == "message":
                extra = {"status": r.get("Status") or ""}
        return {"id": job.id, "action": job.action, "target": job.target, "done": job.done, "ok": job.ok,
                "waiting": bool(r.get("Waiting")), "detail": job.detail, "lines": list(job.lines), "result": extra}


@dataclass
class Run:
    serial: int
    title: str
    kind: str
    proc: subprocess.Popen
    out: Path
    started: float
    quiet: bool
    who: str
    user: str
    role: str
    pos: int = 0


class Runner:
    """Long runs - a scan - as a child process, one at a time for everyone.
    Output is kept for the Activity view and in logs/run/ for later."""

    LOG_LIMIT = 2 * 1024 * 1024

    def __init__(self, app_state: "AppState"):
        self.s = app_state
        self.lock = threading.Lock()
        self.run: Run | None = None
        self.serial = 0
        self.log = ""
        self.log_base = 0
        self.last: dict | None = None
        self.progress: dict | None = None
        self.autoscan_on = False
        self.next_scan_at: float | None = None

    @property
    def progress_file(self) -> Path:
        return self.s.settings.log_dir / "autoscan.progress.json"

    def _add(self, text: str) -> None:
        self.log += text
        if len(self.log) > self.LOG_LIMIT:
            drop = len(self.log) - int(self.LOG_LIMIT * 0.75)
            self.log = self.log[drop:]
            self.log_base += drop

    def read_log(self, frm: int) -> dict:
        with self.lock:
            start = max(0, frm - self.log_base)
            text = self.log[start:] if start < len(self.log) else ""
            return {"from": max(frm, self.log_base), "next": self.log_base + len(self.log), "text": text,
                    "running": self.run is not None, "last": self.last}

    def start_scan(self, auto: bool = False, session: dict | None = None) -> str | None:
        st = self.s.settings
        if st.resolve_kiosk_list() is None:
            return "there is no kiosk list yet - upload one in Settings"
        if auto and st.uses_smb and not st.has_credential:
            # Without the credential every kiosk comes back NO_ACCESS, and
            # those false outages would be written into the history.
            return "auto-scan needs the kiosk-admin credential (KIOSK_ADMIN_USER / KIOSK_ADMIN_PASSWORD)"
        cmd = [sys.executable, "-m", "kfw.collector", "--progress-file", str(self.progress_file)]
        return self._start("Fleet scan", "scan", cmd, quiet=auto, session=session)

    def _start(self, title: str, kind: str, cmd: list[str], quiet: bool, session: dict | None) -> str | None:
        with self.lock:
            if self.run:
                return f"{self.run.title} is still running"
            run_dir = self.s.settings.run_dir
            run_dir.mkdir(parents=True, exist_ok=True)
            cutoff = time.time() - 14 * 86400
            for old in run_dir.iterdir():
                try:
                    if old.stat().st_mtime < cutoff:
                        old.unlink()
                except OSError:
                    pass
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            out_path = run_dir / f"{kind}-{stamp}.out.txt"
            who = f"{session['user']} ({session['role']})" if session else "auto-scan"
            fh = open(out_path, "wb")
            fh.write(f"# Kiosk Fleet Web, {datetime.now():%Y-%m-%d %H:%M:%S} - {title} - for {who}\n".encode())
            fh.flush()
            # The child reads the same settings as this process, whatever set them.
            env = dict(os.environ, PYTHONUNBUFFERED="1", KFW_SETTINGS_JSON=settings_json(self.s.settings))
            try:
                proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env,
                                        start_new_session=True)
            except OSError as e:
                fh.close()
                return f"could not start it: {e}"
            finally:
                fh.close()
            self.serial += 1
            self.run = Run(self.serial, title, kind, proc, out_path, time.time(), quiet, who,
                           (session or {}).get("user", ""), (session or {}).get("role", ""))
            if kind == "scan":
                self.progress = None
                try:
                    self.progress_file.unlink()
                except OSError:
                    pass
            if not quiet:
                self._add(f"\n===== {title}  {datetime.now():%H:%M:%S}  ({who}) =====\n")
            return None

    def stop(self, session: dict) -> str | None:
        with self.lock:
            r = self.run
            if not r:
                return "nothing is running"
            try:
                os.killpg(r.proc.pid, signal.SIGTERM)
            except OSError as e:
                return f"could not stop it: {e}"
            self._add(f"\n===== stopped by {session['user']} =====\n")
        return None

    def poll(self) -> None:
        with self.lock:
            r = self.run
            if not r:
                return
            text = self._read_new(r)
            if text and not r.quiet:
                self._add(text)
            if r.kind == "scan":
                try:
                    p = json.loads(self.progress_file.read_text())
                    if p.get("Pid") == r.proc.pid:
                        self.progress = p
                except (OSError, ValueError):
                    pass
            code = r.proc.poll()
            if code is None:
                return
            text = self._read_new(r)
            if text and not r.quiet:
                self._add(text)
            secs = int(time.time() - r.started)
            if not r.quiet:
                self._add(f"\n===== {r.title}: finished with code {code} after {secs}s =====\n")
            self.last = {"Title": r.title, "Kind": r.kind, "Code": code, "Seconds": secs,
                         "Finished": datetime.now().strftime("%H:%M:%S"), "Who": r.who}
            self.run = None
            if r.kind == "scan":
                self.progress = None
                self.next_scan_at = time.time() + self.s.settings.autoscan_minutes * 60
        self.s.db.audit(r.user, r.role, "", "scan-finished", r.title, "ok" if code == 0 else "failed", f"exit code {code} after {secs}s")
        if r.kind == "scan":
            self.s.cache.refresh(force=True)

    def _read_new(self, r: Run) -> str:
        try:
            with open(r.out, "rb") as f:
                f.seek(r.pos)
                data = f.read()
        except OSError:
            return ""
        if not data:
            return ""
        r.pos += len(data)
        return data.decode("utf-8", errors="replace")

    def enable_autoscan(self) -> str | None:
        st = self.s.settings
        if st.uses_smb and not st.has_credential:
            return "auto-scan needs the kiosk-admin credential (KIOSK_ADMIN_USER / KIOSK_ADMIN_PASSWORD)"
        self.autoscan_on = True
        nxt = time.time()
        f = freshness(self.s.cache.state, st.stale_minutes)
        if f["minutes"] is not None:
            nxt = max(nxt, time.time() + (st.autoscan_minutes - f["minutes"]) * 60)
        self.next_scan_at = nxt
        return None

    def status_json(self) -> dict | None:
        r = self.run
        if not r:
            return None
        el = int(time.time() - r.started)
        scan = None
        if r.kind == "scan":
            p = self.progress
            pct, text = 0, "starting"
            if p and p.get("Total"):
                if p.get("Phase") == "saving":
                    pct, text = 100, "saving"
                else:
                    pct = int(100 * max(0, int(p.get("Index", 0)) - 1) / float(p["Total"]))
                    text = f"{p.get('Index')}/{p.get('Total')} {p.get('Host')}"
            scan = {"pct": pct, "text": text}
        return {"serial": r.serial, "title": r.title, "kind": r.kind, "who": r.who, "quiet": r.quiet,
                "elapsed": f"{el // 60}:{el % 60:02d}", "scan": scan}

    def reports(self) -> list[Path]:
        d = self.s.settings.run_dir
        if not d.exists():
            return []
        files = [p for p in d.iterdir() if p.is_file() and p.name.endswith(".out.txt")]
        return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)[:60]


class AppState:
    def __init__(self, settings: Settings):
        settings.ensure_dirs()
        self.settings = settings
        self.db = Database(settings.db_path)
        self.fs = KioskFS(settings)
        self.cache = FleetCache(settings)
        self.jobs = Jobs(self)
        self.runner = Runner(self)
        self.setup_token: str | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.next_state_check = 0.0
        self.next_sweep = 0.0

    @property
    def credential_note(self) -> str:
        st = self.settings
        if not st.uses_smb:
            return ""
        if not st.has_credential:
            return "no kiosk-admin credential: set KIOSK_ADMIN_USER and KIOSK_ADMIN_PASSWORD (or KIOSK_ADMIN_PASSWORD_FILE)"
        return ""

    def bootstrap(self, log=print) -> None:
        """The first admin: from KFW_ADMIN_USER / KFW_ADMIN_PASSWORD, or - with
        no accounts at all - a one-time setup link printed in the log."""
        st = self.settings
        if st.bootstrap_admin and st.bootstrap_password and not self.db.user(st.bootstrap_admin):
            if not auth.valid_user_name(st.bootstrap_admin):
                log(f"KFW_ADMIN_USER '{st.bootstrap_admin}' is not a usable account name; ignored.")
            elif self.db.user_count() == 0:
                problem = auth.password_problem(st.bootstrap_password, st.bootstrap_admin)
                if problem:
                    log(f"KFW_ADMIN_PASSWORD is not good enough ({problem}); no account was made from it.")
                else:
                    self.db.add_user(st.bootstrap_admin, "admin", st.bootstrap_password)
                    self.db.audit(action="user-add", target=st.bootstrap_admin, result="ok", detail="admin, from KFW_ADMIN_USER")
                    log(f"Made the admin account '{st.bootstrap_admin}' from KFW_ADMIN_USER.")
        if self.db.user_count() == 0:
            self.setup_token = auth.new_token(24)
            log("=" * 72)
            log("No accounts yet. Make the first admin account here (the link works once):")
            log(f"    http://<this server>:<port>/setup?token={self.setup_token}")
            log("=" * 72)

    def start_background(self) -> None:
        self.cache.refresh(force=True)
        st = self.settings
        if st.autoscan:
            why = self.runner.enable_autoscan()
            if why:
                print(f"auto-scan: {why}", flush=True)
        self._thread = threading.Thread(target=self._loop, name="housekeeping", daemon=True)
        self._thread.start()

    def stop_background(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.wait(0.5):
            try:
                self.tick()
            except Exception as e:  # noqa: BLE001 - housekeeping must keep going
                print(f"housekeeping: {type(e).__name__}: {e}", flush=True)

    def tick(self) -> None:
        now = time.time()
        self.runner.poll()
        if now >= self.next_state_check:
            self.cache.refresh()
            self.next_state_check = now + self.settings.refresh_seconds
        r = self.runner
        if r.autoscan_on and r.run is None and r.next_scan_at and now >= r.next_scan_at:
            why = r.start_scan(auto=True)
            if why:
                r.next_scan_at = now + self.settings.autoscan_minutes * 60
        if now >= self.next_sweep:
            self.next_sweep = now + 30
            self.db.sweep_sessions(self.settings.idle_minutes, self.settings.session_hours)
            self.db.sweep_failures()
            self.jobs.sweep()

    def next_scan_minutes(self) -> int:
        r = self.runner
        if not r.autoscan_on or not r.next_scan_at:
            return 0
        return max(0, int(-(-(r.next_scan_at - time.time()) // 60)))

