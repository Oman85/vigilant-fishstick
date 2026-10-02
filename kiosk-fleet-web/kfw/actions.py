"""What can be done to a kiosk, without any front end.

Each action takes an ActionContext and returns a dict with Ok and Detail at
least; progress lines go to ctx.say. The web app runs them on worker threads
and the page follows them by job id.

Launchers are driven through files in their screen folders, as they always
were: refresh.txt, relaunch.txt, hold.txt, kill.txt, snapshot.txt, and
password.seed (which the launcher encrypts for the kiosk account and deletes).
"""
from __future__ import annotations

import csv
import io
import json
import re
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import urlsplit

from .config import Settings
from .fleetstate import LAUNCHER_FOLDERS, LAUNCHER_NAMES
from .kiosk_fs import KioskError, KioskFS, KPath, clean_host
from .launchers import ng_observation, pbi_observation, web_observation
from .remote import send_kiosk_restart, test_host_reachable
from .timeutil import format_minutes, utc_iso, utcnow

LIVE_STALE_MINUTES = 5


@dataclass
class ActionContext:
    settings: Settings
    fs: KioskFS
    target: str
    who: str = "Kiosk Fleet Web"
    say: Callable[[str], None] = lambda s: None
    kind: str = "ALL"            # NG, PBI, WEB or ALL
    screen: str = ""             # S1, S2 ... or "" for every screen
    params: dict = field(default_factory=dict)
    secret: str | None = None    # a password; dropped as soon as it is written


def fail(detail: str, **kw) -> dict:
    return {"Ok": False, "Detail": detail, **kw}


def _row(label, value, sev="", wrap=False) -> dict:
    return {"Label": label, "Value": "" if value is None else str(value), "Sev": sev, "Wrap": wrap}


def open_share(ctx: ActionContext) -> KPath:
    """The kiosk's C: drive with the fleet credential, or KioskError."""
    if ctx.settings.uses_smb:
        reach = test_host_reachable(ctx.target, ctx.settings)
        if not reach.ok:
            raise KioskError(f"offline: {reach.error}")
    return ctx.fs.connect(ctx.target)


@dataclass
class LauncherDir:
    kind: str
    instance: str
    dir: KPath

    @property
    def status(self) -> KPath:
        return self.dir / "Status"


def launcher_dirs(root: KPath, kind: str, host: str, screen: str = "") -> list[LauncherDir]:
    """Where a kiosk's launchers keep their control files: each screen folder
    holding <HOST>.json - and PBI Launcher's own folder, from before the
    screen folders, as its S1."""
    kinds = list(LAUNCHER_FOLDERS) if kind in ("ALL", "", None) else [kind]
    docs = root / "Users\\Public\\Documents"
    out: list[LauncherDir] = []
    for k in kinds:
        base = docs / LAUNCHER_FOLDERS[k]
        entries = base.iterdir()
        if not entries:
            continue
        mine = []
        for d in entries:
            if d.is_dir and re.match(r"^S\d+$", d.name, re.IGNORECASE) and (d.path / f"{host}.json").exists():
                mine.append(LauncherDir(k, d.name.upper(), d.path))
        if k == "PBI" and not any(m.instance == "S1" for m in mine) and any(e.name.lower() == f"{host.lower()}.json" for e in entries):
            mine.append(LauncherDir(k, "S1", base))
        out += mine
    if screen:
        out = [d for d in out if d.instance == screen.upper()]
    return sorted(out, key=lambda d: (d.instance, d.kind))


def screen_dir(root: KPath, kind: str, instance: str, host: str) -> KPath:
    base = root / "Users\\Public\\Documents" / LAUNCHER_FOLDERS[kind]
    if kind == "PBI" and instance == "S1" and not (base / "S1" / f"{host}.json").exists() and (base / f"{host}.json").exists():
        return base
    return base / instance


def read_json(p: KPath):
    try:
        v = json.loads(p.read_text())
        return v[0] if isinstance(v, list) and v else v
    except (OSError, ValueError):
        return None


def wait_taken(p: KPath, seconds: float = 20, poll: float = 0.4) -> bool:
    """The launcher deletes a control file when it acts on it; hold.txt is
    meant to stay, so it is never waited for."""
    if p.name.lower() == "hold.txt":
        return True
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not p.exists():
            return True
        time.sleep(poll)
    return False


def write_password_seed(d: KPath, plain: str) -> KPath:
    seed = d / "password.seed"
    seed.write_text(plain)
    return seed


def _stamp(ctx: ActionContext) -> str:
    return f"{datetime.now().strftime('%Y-%m-%dT%H:%M:%S')} by {ctx.who} from Kiosk Fleet Web"


def _password_state(dirs: list[LauncherDir]) -> str:
    signs_in = [d for d in dirs if d.kind != "WEB"]
    if not signs_in:
        return "none needed (a web page)"
    state = "none stored - signing in needs a person"
    for d in signs_in:
        if (d.dir / "password.seed").exists():
            return "a new one is waiting for the launcher"
        if d.dir.files("*.cred"):
            state = "stored, encrypted for the kiosk account"
    return state


# ---------------------------------------------------------------------------
# The actions
# ---------------------------------------------------------------------------
def live_read(ctx: ActionContext) -> dict:
    root = open_share(ctx)
    now = utcnow()
    parts = []
    if ctx.kind in ("ALL", "NG"):
        parts.append(ng_observation(ctx.fs.public_docs(ctx.target), now, LIVE_STALE_MINUTES))
    if ctx.kind in ("ALL", "PBI"):
        parts.append(pbi_observation(root, now, LIVE_STALE_MINUTES, ctx.target))
    if ctx.kind in ("ALL", "WEB"):
        parts.append(web_observation(root, now, LIVE_STALE_MINUTES, ctx.target))
    installed = any(p["Installed"] for p in parts)
    instances = [i for p in parts for i in p["Instances"] if not ctx.screen or i["Screen"] == ctx.screen]
    error = "; ".join(p["Error"] for p in parts if p["Error"])

    dirs = launcher_dirs(root, ctx.kind, ctx.target, ctx.screen)
    lines = []
    hold = False
    config = None
    if not installed:
        lines.append(_row("Installed", "no", "WARNING"))
    for d in dirs:
        if config is None:
            config = read_json(d.dir / f"{ctx.target}.json")
        if (d.dir / "hold.txt").exists():
            hold = True
            lines.append(_row(f"{d.instance} {d.kind}", "on hold (hold.txt) - no checks, no reloads", "WARNING", True))
        if (d.dir / "kill.txt").exists():
            lines.append(_row(d.instance, "kill.txt is waiting - the launcher stops when it sees it", "WARNING", True))
    for i in instances:
        as_ = f" as {i['SignedInAs']}" if i.get("SignedInAs") else ""
        label = f"{i['Screen']} {i['Launcher']}" if i.get("Screen") else i["Instance"]
        lines.append(_row(label, f"{i['State']}{as_}, {format_minutes(i['AgeMinutes'])} old", "CRITICAL" if i["Severity"] == "CRITICAL" else "DIM", True))
        if i.get("Detail"):
            lines.append(_row("", i["Detail"], "DIM", True))
    if isinstance(config, dict):
        url = config.get("DisplayURL") or config.get("URL") or ""
        if url:
            lines.append(_row("Shows", url, "DIM", True))
        if config.get("UserName"):
            lines.append(_row("Signs in as", config["UserName"], "DIM"))
    lines.append(_row("Password", _password_state(dirs), "DIM"))
    if error:
        lines.append(_row("Error", error, "WARNING", True))
    return {"Ok": True, "Detail": "read just now", "Hold": hold, "Lines": lines,
            "Instances": [d.instance for d in dirs], "Installed": installed}


def send_control(ctx: ActionContext) -> dict:
    """Drops a control file in each of the kiosk's launcher folders (or
    removes it, for remove=True) and waits for the launcher to take it."""
    root = open_share(ctx)
    dirs = launcher_dirs(root, ctx.kind, ctx.target, ctx.screen)
    if not dirs:
        return fail("the launcher is not installed here")
    name = ctx.params["file"]
    sent = taken = 0
    for d in dirs:
        p = d.dir / name
        if ctx.params.get("remove"):
            p.unlink()
            sent += 1
            taken += 1
            continue
        p.write_text(_stamp(ctx))
        sent += 1
        ctx.say(f"{d.instance} {d.kind}: {name} written")
        if wait_taken(p, ctx.params.get("wait", 20)):
            taken += 1
    detail = "the launcher has taken it" if taken >= sent else "not taken within 20 s - it stays, and the launcher acts on it when it next looks"
    return {"Ok": True, "Detail": detail, "Sent": sent, "Taken": taken, "Waiting": taken < sent, "Instances": [d.instance for d in dirs]}


def snapshot(ctx: ActionContext) -> dict:
    root = open_share(ctx)
    dirs = launcher_dirs(root, ctx.kind, ctx.target, ctx.screen)
    if not dirs:
        return fail("the launcher is not installed here")
    before = {}
    for d in dirs:
        for f in d.status.files("*.snapshot.json"):
            before[f.path] = f.mtime
        (d.dir / "snapshot.txt").write_text(_stamp(ctx))
    ctx.say("asked the launcher for a picture")

    deadline = time.monotonic() + ctx.params.get("wait", 45)
    info = where = None
    while info is None and time.monotonic() < deadline:
        for d in dirs:
            for f in d.status.files("*.snapshot.json"):
                was = before.get(f.path)
                if was is not None and f.mtime is not None and f.mtime <= was:
                    continue
                j = read_json(f.path)
                if isinstance(j, dict):
                    info, where = j, d
                    break
            if info:
                break
        if info is None:
            time.sleep(0.5)
    if info is None:
        return fail("no screenshot came back within 45 s")

    out = {"Ok": True, "Detail": "screenshot saved", "File": "", "State": str(info.get("State") or ""),
           "Url": str(info.get("Url") or ""), "Title": str(info.get("Title") or ""), "Instance": where.instance}
    if info.get("Error") or not info.get("Image"):
        out.update(Ok=False, Detail=str(info.get("Error") or "the launcher saved no picture"))
        return out
    # Only a file name the launcher wrote into its own Status folder.
    leaf = re.split(r"[\\/]", str(info["Image"]))[-1]
    src = where.status / leaf
    if not src.exists():
        out.update(Ok=False, Detail=f"the picture is missing: {src}")
        return out
    name = f"{ctx.target}_{where.instance}_{datetime.now().strftime('%Y%m%d-%H%M%S')}.png"
    src.copy_to_local(ctx.settings.snapshot_dir / name)
    out["File"] = name
    return out


LOG_RX = re.compile(r'<!\[LOG\[(?P<m>.*?)\]LOG\]!><time="(?P<t>\d\d:\d\d:\d\d)[^"]*" date="(?P<d>[^"]*)"[^>]*?type="(?P<ty>\d)"', re.DOTALL)


def read_log(ctx: ActionContext) -> dict:
    root = open_share(ctx)
    dirs = launcher_dirs(root, ctx.kind, ctx.target, ctx.screen)
    if not dirs:
        return fail("the launcher is not installed here")
    d = dirs[0]
    config = read_json(d.dir / f"{ctx.target}.json")
    log_dir = d.dir / "Logs"
    name = ""
    if isinstance(config, dict):
        lp = str(config.get("LogPath") or "")
        m = re.match(r"^([A-Za-z]):\\?(.*)$", lp)
        if m:
            if m.group(1).upper() == "C":
                log_dir = root / m.group(2)
            else:
                return fail(f"the log is on drive {m.group(1).upper()}: of the kiosk, which this server does not open")
        if config.get("LogName"):
            name = re.split(r"[\\/]", str(config["LogName"]))[-1]
    path = log_dir / name if name else None
    if path is None or not path.exists():
        logs = sorted(log_dir.files("*.log"), key=lambda e: e.mtime or datetime.min.astimezone(), reverse=True)
        if not logs:
            return fail(f"no log in {log_dir}")
        path = logs[0].path

    text = path.read_text(tail=262144)
    entries = list(LOG_RX.finditer(text))
    count = int(ctx.params.get("lines") or 60)
    out = []
    for e in entries[-count:]:
        date = e.group("d")
        m = re.match(r"^(\d\d)-(\d\d)-\d{4}$", date)
        if m:
            date = f"{m.group(2)}.{m.group(1)}."
        mark = {"3": "!", "2": "*"}.get(e.group("ty"), " ")
        msg = re.sub(r"\r?\n", " ", e.group("m").rstrip())
        out.append(f"{mark} {date:<7}{e.group('t')}  {msg}")
    if not entries:
        out.append("(no entries)")
    return {"Ok": True, "Detail": str(path), "Path": str(path), "Lines": out}


def set_password(ctx: ActionContext) -> dict:
    root = open_share(ctx)
    try:
        # A web page signs in to nothing.
        dirs = [d for d in launcher_dirs(root, ctx.kind, ctx.target, ctx.screen) if d.kind != "WEB"]
        if not dirs:
            return fail("no launcher that signs in on this screen")
        seeds = [write_password_seed(d.dir, ctx.secret or "") for d in dirs]
    finally:
        ctx.secret = None
    ctx.say("written - waiting for the launcher to store it")
    deadline = time.monotonic() + ctx.params.get("wait", 30)
    while time.monotonic() < deadline:
        if not any(s.exists() for s in seeds):
            return {"Ok": True, "Detail": "stored; the launcher uses it from the next sign-in on"}
        time.sleep(0.5)
    return {"Ok": True, "Detail": "not taken yet - the launcher stores it when it next starts", "Waiting": True}


# ---------------------------------------------------------------------------
# The kiosk's own settings
# ---------------------------------------------------------------------------
CONFIG_PRIMARY = {
    "NG": ["DisplayURL", "LoginURL", "UserName", "ScreenSelect"],
    "PBI": ["DisplayURL", "UserName", "ScreenSelect"],
    "WEB": ["DisplayURL", "TargetMatch", "ScreenSelect"],
}
CONFIG_REQUIRED = {"NG": ["DisplayURL", "UserName"], "PBI": ["DisplayURL", "UserName"], "WEB": ["DisplayURL"]}
CONFIG_BOOLS = {"EnableRefresh", "KioskMode", "UsePriScreen", "ScheduledRestartEnabled", "DisableStartup",
                "DebugLogging", "Watchdog", "StopOldLauncher", "InPrivate", "StaySignedIn", "BackButton"}
CONFIG_LABELS = {
    "NG": {
        "DisplayURL": ("Dashboard URL", "The station page this screen shows."),
        "LoginURL": ("Sign-in URL", "Left empty, it becomes the dashboard URL's host plus /prelogin?clear=true."),
        "UserName": ("Station user", "The Niagara account the launcher signs in as."),
        "ScreenSelect": ("Screen", "1 is the first screen. A second screen (S2) usually shows 2."),
    },
    "PBI": {
        "DisplayURL": ("Report URL", "The Power BI report this screen shows."),
        "UserName": ("Power BI account", "The account the launcher signs in as."),
        "ScreenSelect": ("Screen", "1 is the first screen."),
    },
    "WEB": {
        "DisplayURL": ("Page URL", "The web page this screen shows. No sign-in: the launcher shows the page as it comes."),
        "TargetMatch": ("Stays on", "path (the page and the pages under it), host (anywhere on the site) or exact (only this address)."),
        "ScreenSelect": ("Screen", "1 is the first screen. A second screen (S2) usually shows 2."),
    },
}


def config_template(settings: Settings, kind: str, host: str, instance: str = "S1") -> list[tuple[str, str]]:
    """EXAMPLE.json as it ships, in file order, with the kiosk's own name where it had one."""
    path = settings.templates_dir / LAUNCHER_FOLDERS[kind] / "EXAMPLE.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return []
    pairs = []
    for key, value in data.items():
        value = "" if value is None else str(value)
        if key == "LogName":
            suffix = f"_{instance}" if instance and instance != "S1" else ""
            value = {"NG": f"{host}{suffix}_Mach2LauncherNG.log", "PBI": f"PbiLauncher_{host}{suffix}.log"}.get(kind, f"WebLauncher_{host}{suffix}.log")
        elif key in ("DisplayURL", "LoginURL", "UserName"):
            value = ""
        pairs.append((key, value))
    return pairs


def config_fields(kind: str, pairs: list[tuple[str, str]], is_new: bool) -> list[dict]:
    """The editor: the few that matter first, the password, then everything
    else in the file as advanced settings."""
    values = dict(pairs)
    labels = CONFIG_LABELS[kind]
    fields = []
    for key in CONFIG_PRIMARY[kind]:
        label, hint = labels.get(key, (key, ""))
        fields.append({"Key": key, "Label": label, "Value": values.get(key, ""), "Hint": hint, "Kind": "text", "Advanced": False})
    if kind != "WEB":
        fields.append({"Key": "__password", "Label": "Sign-in password", "Value": "", "Kind": "password", "Advanced": False,
                       "Hint": "Handed to the launcher as password.seed; it encrypts it for the kiosk account." if is_new
                       else "Leave both empty to keep the password already stored on the kiosk."})
    for key, value in pairs:
        if key in CONFIG_PRIMARY[kind]:
            continue
        fields.append({"Key": key, "Label": key, "Value": value, "Hint": "", "Kind": "bool" if key in CONFIG_BOOLS else "text", "Advanced": True})
    return fields


def _pairs_of(obj) -> list[tuple[str, str]]:
    return [(k, "" if v is None else str(v)) for k, v in obj.items()]


def config_read(ctx: ActionContext) -> dict:
    root = open_share(ctx)
    kind = ctx.kind
    dirs = launcher_dirs(root, kind, ctx.target)
    instances = [d.instance for d in dirs]
    instance = ctx.params.get("instance") or (instances[0] if instances else "S1")
    # Which launcher has which screen, so a new config does not land on one another launcher shows.
    taken = {d.instance: d.kind for d in launcher_dirs(root, "ALL", ctx.target) if d.kind != kind}

    pairs: list[tuple[str, str]] = []
    exists = False
    password = "none stored"
    d = next((x for x in dirs if x.instance == instance), None)
    if d:
        cfg = read_json(d.dir / f"{ctx.target}.json")
        if isinstance(cfg, dict):
            exists = True
            pairs = _pairs_of(cfg)
        if (d.dir / "password.seed").exists():
            password = "a new one is waiting for the launcher"
        elif d.dir.files("*.cred"):
            password = "stored, encrypted for the kiosk account"
    if not exists:
        pairs = config_template(ctx.settings, kind, ctx.target, instance)
    return {"Ok": True, "Detail": "", "Kind": kind, "Exists": exists, "IsNew": not exists, "Instance": instance,
            "Instances": instances, "Password": password, "Taken": taken, "Fields": config_fields(kind, pairs, not exists)}


def config_write(ctx: ActionContext) -> dict:
    """Saves one screen's config. The file is read again here rather than
    trusting what came back from the editor: its keys and their order are the
    file's (or EXAMPLE.json's), and only those - plus the few every config
    needs - can be set. The old file is kept as <HOST>.json.bak-<time>."""
    try:
        root = open_share(ctx)
        kind, instance = ctx.kind, ctx.params["instance"]
        d = screen_dir(root, kind, instance, ctx.target)
        other = [x for x in launcher_dirs(root, "ALL", ctx.target, instance) if x.kind != kind]
        if other:
            return fail(f"{instance} already has a config for {LAUNCHER_NAMES[other[0].kind]} - one launcher per screen")

        path = d / f"{ctx.target}.json"
        existing = read_json(path)
        is_new = not isinstance(existing, dict)
        pairs = _pairs_of(existing) if not is_new else config_template(ctx.settings, kind, ctx.target, instance)
        values = dict(pairs)
        for key in CONFIG_PRIMARY[kind]:
            values.setdefault(key, "")
        typed = ctx.params.get("values") or {}
        for key in list(values):
            if key in typed:
                values[key] = str(typed[key])
        missing = [k for k in CONFIG_REQUIRED[kind] if not values.get(k)]
        if missing:
            return fail("still empty: " + ", ".join(missing))

        if not d.is_dir():
            d.mkdir()
            ctx.say(f"created {d}")
        # Only the kiosk's first Mach2 screen is the watchdog: two on one PC
        # would both want to restart it.
        if kind == "NG" and is_new and "Watchdog" in values:
            others = [x for x in launcher_dirs(root, "NG", ctx.target) if x.instance != instance]
            first = not any(_screen_no(x.instance) < _screen_no(instance) for x in others)
            values["Watchdog"] = "1" if first else "0"
            ctx.say("the first Mach2 screen here, so it is the watchdog" if first else "not the first Mach2 screen here, so it is not the watchdog")
        if kind == "NG" and "LoginURL" in values and not values["LoginURL"] and values.get("DisplayURL"):
            u = urlsplit(values["DisplayURL"])
            if u.scheme and u.netloc:
                values["LoginURL"] = f"{u.scheme}://{u.netloc}/prelogin?clear=true"
                ctx.say(f"sign-in URL: {values['LoginURL']}")

        if path.exists():
            backup = d / f"{path.name}.bak-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
            path.copy(backup)
            ctx.say(f"the old one is kept as {backup.name}")
        path.write_text(json.dumps(values, indent=2, ensure_ascii=False))
        ctx.say(f"saved {path}")

        out = {"Ok": True, "IsNew": is_new, "Path": str(path), "Password": "",
               "Detail": f"Written. The kiosk can be deployed to now: {LAUNCHER_NAMES[kind]}, on {instance}." if is_new
               else "Saved. The launcher reads it again within seconds."}
        if ctx.secret and kind != "WEB":
            seed = write_password_seed(d, ctx.secret)
            ctx.secret = None
            ctx.say("password.seed written")
            deadline = time.monotonic() + ctx.params.get("wait", 20)
            while time.monotonic() < deadline and seed.exists():
                time.sleep(0.5)
            out["Password"] = "waiting for the launcher to store it" if seed.exists() else "stored by the launcher"
            ctx.say(f"password: {out['Password']}")
        return out
    finally:
        ctx.secret = None


def _screen_no(instance: str) -> int:
    m = re.match(r"^S(\d+)$", instance, re.IGNORECASE)
    return int(m.group(1)) if m else 0


def restart(ctx: ActionContext) -> dict:
    """Over WMI/DCOM. A countdown of 0 restarts at once, with nothing on screen."""
    secs = int(ctx.params.get("seconds", 0))
    comment = ctx.params.get("message", "") if secs > 0 else ""
    ctx.say(f"restarting {ctx.target} ...")
    if not ctx.settings.uses_smb:
        # The local stand-in has no Windows to restart; it records the request.
        marker = ctx.fs.root(ctx.target) / "restart-requested.txt"
        marker.write_text(f"{_stamp(ctx)}\ncountdown {secs}s\n{comment}")
        return {"Ok": True, "Detail": "recorded (local test kiosk)"}
    r = send_kiosk_restart(ctx.target, ctx.settings, secs, comment)
    if r.sent:
        return {"Ok": True, "Detail": f"sent over {r.via} - the kiosk restarts and comes back on its own"}
    return fail(r.detail or "it did not go through")


# ---------------------------------------------------------------------------
# A message on the screen, through the kiosk's watchdog (V7.0+ or NG)
# ---------------------------------------------------------------------------
def _message_rows(ledger: KPath, mid: str) -> list[dict]:
    """This message's rows in the kiosk's ledger. Only the tail is read: the
    rows are seconds old, and the ledger can be 8 MB."""
    try:
        head = ledger.read_text(head=4096)
        tail = ledger.read_text(tail=262144)
    except OSError:
        return []
    header = head.splitlines()[0] if head else ""
    if not header:
        return []
    hits = [line for line in tail.splitlines() if f"MessageId={mid}" in line]
    if not hits:
        return []
    return list(csv.DictReader(io.StringIO("\n".join([header] + hits))))


def send_message(ctx: ActionContext) -> dict:
    """Sends one message and follows it. Every outcome is a Status a person can act on:

      NOT_SENT       offline, share unreadable, or no inbox (no V7.0+ watchdog)
      NOT_DELIVERED  nobody picked it up in time; it was withdrawn
      SHOWN          on screen now
      ACKNOWLEDGED   OK was pressed;  TIMEOUT  its countdown ran out
      EXPIRED, REJECTED  the watchdog dropped it; Detail says why
      PICKED_UP      taken from the inbox, but no ledger row yet
    """
    text = ctx.params["text"]
    secs = int(ctx.params.get("seconds", 60))
    wait = int(ctx.params.get("wait", 45))
    expire = 10
    status, detail = "NOT_SENT", ""
    try:
        open_share(ctx)
    except KioskError as e:
        return {"Ok": False, "Status": status, "Detail": f"NOT_SENT: {e}"}
    folder = ctx.fs.public_docs(ctx.target)
    inbox = folder / "mwst_inbox"
    if not inbox.is_dir():
        return {"Ok": False, "Status": status, "Detail": "NOT_SENT: no message inbox - this kiosk has never run a V7.0 or later watchdog"}

    now = utcnow()
    mid = str(uuid.uuid4())
    payload = {"Id": mid, "Title": ctx.params.get("title") or "Message from IT", "Text": text, "Seconds": secs,
               "From": f"{ctx.who} via Kiosk Fleet Web", "SentUtc": utc_iso(now), "ExpiresUtc": utc_iso(now + timedelta(minutes=expire))}
    name = f"msg_{now.strftime('%Y%m%d%H%M%S%f')[:17]}_{mid[:8]}.json"
    f = inbox / name
    f.write_text(json.dumps(payload, separators=(",", ":")))
    status = "QUEUED"
    ctx.say("queued - waiting for the watchdog to pick it up")

    ledger = folder / "mwst_events.csv"
    deadline = time.monotonic() + wait
    extended = False
    while True:
        rows = _message_rows(ledger, mid)
        final = [r for r in rows if r.get("EventType") in ("MESSAGE_CLOSED", "MESSAGE_EXPIRED", "MESSAGE_REJECTED")]
        if final:
            status = final[-1].get("Outcome") or "CLOSED"
            detail = re.sub(r"^MessageId=[^;]*;\s*", "", final[-1].get("Detail") or "")
            break
        if any(r.get("EventType") == "MESSAGE_SHOWN" for r in rows):
            if status != "SHOWN":
                status, detail = "SHOWN", f"on screen for up to {secs} s"
                ctx.say("on screen")
            if not ctx.params.get("wait_for_close"):
                break
            if not extended:
                deadline = time.monotonic() + secs + 30
                extended = True
                ctx.say(f"waiting for it to be closed (up to {secs} s)")
        elif status == "QUEUED" and not f.exists():
            status = "PICKED_UP"
            ctx.say("picked up")
        if time.monotonic() >= deadline:
            if status == "QUEUED":
                try:
                    f.unlink(missing_ok=False)
                    status, detail = "NOT_DELIVERED", f"not picked up within {wait} s, so withdrawn - is the V7.0 watchdog running there?"
                except OSError:
                    if f.exists():
                        status, detail = "NOT_DELIVERED", "not picked up, and could not be withdrawn: it will be dropped if still unseen in 10 minutes"
                    else:
                        status, detail = "PICKED_UP", "picked up at the last moment; no ledger row seen yet"
            elif status == "PICKED_UP":
                detail = "taken from the inbox, but no MESSAGE_SHOWN row appeared - check mwst.log on the kiosk"
            elif status == "SHOWN":
                detail = "shown, but its closing was not recorded within the wait"
            break
        time.sleep(ctx.params.get("poll", 2))
    ok = status in ("SHOWN", "ACKNOWLEDGED", "TIMEOUT")
    return {"Ok": ok, "Status": status, "Detail": f"{status}: {detail}", "Waiting": status == "TIMEOUT"}


def test_connection(ctx: ActionContext) -> dict:
    """Can this server reach a kiosk and read its share? For setting up."""
    lines = []
    if ctx.settings.uses_smb:
        reach = test_host_reachable(ctx.target, ctx.settings)
        lines.append(_row("Network", f"reachable ({reach.method})" if reach.ok else f"not reachable: {reach.error}", "OK" if reach.ok else "CRITICAL"))
        if not reach.ok:
            return {"Ok": False, "Detail": f"{ctx.target} does not answer", "Lines": lines}
        lines.append(_row("Credential", ctx.settings.kiosk_user or "none - using no credential", "DIM" if ctx.settings.kiosk_user else "WARNING"))
    root = ctx.fs.connect(ctx.target)
    lines.append(_row("Share", f"{root} opened", "OK"))
    found = []
    docs = ctx.fs.public_docs(ctx.target)
    for kind, folder in LAUNCHER_FOLDERS.items():
        if (docs / folder).is_dir():
            found.append(LAUNCHER_NAMES[kind])
    if (docs / "mwst.log").exists():
        found.append("MWST watchdog")
    lines.append(_row("Found", ", ".join(found) or "no launcher, no watchdog", "DIM"))
    return {"Ok": True, "Detail": f"{ctx.target}: the share opens", "Lines": lines}


ACTIONS = {
    "test": test_connection,
    "live": live_read,
    "control": send_control,
    "snapshot": snapshot,
    "log": read_log,
    "password": set_password,
    "config-read": config_read,
    "config-write": config_write,
    "restart": restart,
    "message": send_message,
}


def run_action(name: str, ctx: ActionContext) -> dict:
    fn = ACTIONS.get(name)
    if not fn:
        return fail(f"unknown action '{name}'")
    try:
        return fn(ctx)
    except KioskError as e:
        return fail(str(e))
    except OSError as e:
        return fail(f"{type(e).__name__}: {e}")
    finally:
        ctx.secret = None


# ---------------------------------------------------------------------------
# Deploy command lines - for the PowerShell deploy scripts, run on Windows
# ---------------------------------------------------------------------------
DEPLOY_PRODUCTS = {
    "NG": {"Name": "Mach2 Launcher NG", "Tab": "Mach2", "Script": "Deploy-Mach2LauncherNG.ps1",
           "Note": "The launcher and the watchdog in one. Carries the settings over from Mach2Launcher.exe, and retires that and the MWST watchdog. Roll back puts both of them back."},
    "PBI": {"Name": "PBI Launcher", "Tab": "PBI", "Script": "Deploy-PbiLauncher.ps1",
            "Note": "Replaces PowerBILauncher.exe, carrying its settings over. Roll back puts the old launcher back."},
    "WEB": {"Name": "Web Launcher", "Tab": "*", "Script": "Deploy-WebLauncher.ps1",
            "Note": "One web page on a screen, full screen, kept there - no sign-in. Any kiosk can have one on a free screen: write its config first (Config... on the kiosk), then install. Roll back removes it and puts back any old launcher it replaced."},
    "WATCHDOG": {"Name": "MWST watchdog", "Tab": "Mach2", "Script": "Deploy-MWSTAgent.ps1",
                 "Note": "The old white-screen watchdog on its own, for Mach2 kiosks not moved to the NG launcher yet. It has no roll back."},
}


def deploy_command(product: str, hosts: list[str], rollback=False, restart=False, warn_seconds=60, verify_minutes=12,
                   force=False, update_config=False, keep_legacy=False, keep_watchdog=False, register_task=False,
                   kiosk_user="", dry_run=False) -> dict:
    """The deploy command line, built from checked values only, so what is
    copied is exactly what was previewed. Raises ValueError."""
    if product not in DEPLOY_PRODUCTS:
        raise ValueError(f"unknown product '{product}'")
    names = []
    for h in hosts:
        n = clean_host(h)
        if not n:
            raise ValueError(f"'{h}' is not a kiosk name")
        names.append(n)
    names = sorted(set(names), key=str.lower)
    if not names:
        raise ValueError("no kiosks ticked")
    if not 0 <= warn_seconds <= 600:
        raise ValueError("the countdown has to be 0 to 600 seconds")
    if not 2 <= verify_minutes <= 60:
        raise ValueError("the wait has to be 2 to 60 minutes")
    if kiosk_user and not re.match(r"^[A-Za-z0-9][A-Za-z0-9 ._@\\-]{0,103}$", kiosk_user):
        raise ValueError("that is not a Windows account name")
    wd = product == "WATCHDOG"
    q = lambda s: "'" + s.replace("'", "''") + "'"  # noqa: E731
    args = ["-Hosts " + ",".join(q(n) for n in names)]
    if rollback and not wd:
        args.append("-Rollback")
    if restart:
        if wd:
            args += ["-RebootAndVerify", f"-RebootWarningSeconds {warn_seconds}"]
        else:
            args += ["-Restart", f"-RestartWarningSeconds {warn_seconds}", f"-VerifyMinutes {verify_minutes}"]
    if force:
        args.append("-Force")
    if not wd:
        if update_config and not rollback and product != "WEB":
            args.append("-UpdateConfig")
        if keep_legacy and not rollback:
            args.append("-KeepLegacy")
        if product == "NG" and keep_watchdog and not rollback:
            args.append("-KeepWatchdog")
        if kiosk_user:
            args.append(f"-KioskUser {q(kiosk_user)}")
    elif register_task:
        args.append("-RegisterLauncherTask")
    if dry_run:
        args.append("-WhatIf")
    script = ".\\" + DEPLOY_PRODUCTS[product]["Script"]
    title = f"Roll back {DEPLOY_PRODUCTS[product]['Name']}" if rollback and not wd else f"Install / update {DEPLOY_PRODUCTS[product]['Name']}"
    return {"Product": product, "Hosts": names, "Arguments": args, "Command": f"& '{script}' " + " ".join(args),
            "Preview": script + " " + "\n    ".join(args), "Title": title}


def snapshot_path(settings: Settings, name: str) -> Path | None:
    if not re.match(r"^[A-Za-z0-9._-]{1,120}\.png$", name):
        return None
    p = settings.snapshot_dir / name
    return p if p.is_file() else None
