"""kfw: the server, a scan, and accounts from the command line.

    kfw serve                         the web app (what the container runs)
    kfw serve --demo                  the same, with a pretend fleet to try it on
    kfw scan [--dry-run]              one scan of the fleet
    kfw user list
    kfw user add NAME --role admin    asks for the password twice
    kfw user passwd NAME
    kfw user role NAME operator
    kfw user disable NAME | enable NAME | remove NAME
    kfw user import web-users.json    accounts from the PowerShell server, hashes and all

In the container: docker compose exec kfw kfw user add alice --role admin
"""
from __future__ import annotations

import argparse
import getpass
import os
import sys
from pathlib import Path

from . import __version__, auth
from .config import load_settings


def _db():
    from .db import Database
    s = load_settings()
    s.ensure_dirs()
    return Database(s.db_path)


def _ask_password(name: str) -> str:
    env = os.environ.get("KFW_NEW_PASSWORD")
    if env:
        p1 = p2 = env
    else:
        p1 = getpass.getpass(f"Password for {name}: ")
        p2 = getpass.getpass("Again: ")
    if p1 != p2:
        raise SystemExit("The two did not match. Nothing was changed.")
    problem = auth.password_problem(p1, name)
    if problem:
        raise SystemExit(f"The password needs {problem}.")
    return p1


def cmd_serve(a) -> int:
    import uvicorn

    from .app import create_app
    s = load_settings()
    if a.demo or os.environ.get("KFW_DEMO", "").lower() in ("1", "true", "yes"):
        from .demo import seed
        root, _ = seed(s.data_dir)
        s.root_template = str(root / "{0}")
        print(f"DEMO: a pretend fleet in {root}; nothing here touches a real kiosk.", flush=True)
    proxy = {"proxy_headers": True, "forwarded_allow_ips": "*"} if s.trust_proxy else {"proxy_headers": False}
    uvicorn.run(create_app(s), host=a.host, port=a.port, log_level="info", access_log=a.access_log,
                ssl_certfile=a.ssl_certfile, ssl_keyfile=a.ssl_keyfile, **proxy)
    return 0


def cmd_scan(a) -> int:
    from .collector import run_scan
    return run_scan(load_settings(), Path(a.progress_file) if a.progress_file else None, a.dry_run)


def cmd_user(a) -> int:
    db = _db()
    if a.action == "list":
        users = db.users()
        if not users:
            print("No accounts.")
        for u in users:
            state = "disabled" if u["disabled"] else ("must change password" if u["must_change"] else "active")
            print(f"{u['name']:<32} {u['role']:<9} {state:<22} last sign-in {u['last_login'] or 'never'}")
        return 0
    if a.action == "import":
        from .db import import_web_users
        done = import_web_users(db, Path(a.name))
        print(f"Imported {len(done)} account(s): {', '.join(done) or '-'}")
        return 0
    if not a.name:
        raise SystemExit("Which account?")
    u = db.user(a.name)
    if a.action == "add":
        if u:
            raise SystemExit(f"There is an account called {a.name} already.")
        if not auth.valid_user_name(a.name):
            raise SystemExit("An account name is 2 to 64 letters, digits, dots, dashes, underscores or @.")
        role = a.role or "operator"
        if role not in auth.ROLE_RANK:
            raise SystemExit("The role is operator or admin.")
        db.add_user(a.name, role, _ask_password(a.name), must_change=a.must_change)
        db.audit(action="user-add", target=a.name, result="ok", detail=f"{role}, from the command line")
        print(f"Added {a.name} ({role}).")
        return 0
    if not u:
        raise SystemExit(f"No account called {a.name}.")
    name = u["name"]
    last_admin = u["role"] == "admin" and not u["disabled"] and db.user_count(active_admins_only=True) <= 1
    if a.action == "passwd":
        db.set_password(name, _ask_password(name), must_change=a.must_change)
        db.end_sessions_of(name)
        detail = "new password"
    elif a.action == "role":
        if a.role not in auth.ROLE_RANK:
            raise SystemExit("The role is operator or admin.")
        if last_admin and a.role != "admin":
            raise SystemExit("That is the last admin.")
        db.set_role(name, a.role)
        detail = f"role={a.role}"
    elif a.action in ("disable", "enable"):
        if a.action == "disable" and last_admin:
            raise SystemExit("That is the last admin.")
        db.set_disabled(name, a.action == "disable")
        if a.action == "disable":
            db.end_sessions_of(name)
        detail = a.action + "d"
    elif a.action == "remove":
        if last_admin:
            raise SystemExit("That is the last admin.")
        db.remove_user(name)
        detail = "removed"
    else:
        raise SystemExit(f"unknown: {a.action}")
    db.audit(action="user-change", target=name, result="ok", detail=detail + ", from the command line")
    print(f"{name}: {detail}.")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="kfw", description=f"Kiosk Fleet Web {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("serve", help="run the web app")
    sp.add_argument("--host", default=os.environ.get("KFW_HOST", "0.0.0.0"))
    sp.add_argument("--port", type=int, default=int(os.environ.get("KFW_PORT", "8080")))
    sp.add_argument("--ssl-certfile", default=os.environ.get("KFW_TLS_CERT") or None)
    sp.add_argument("--ssl-keyfile", default=os.environ.get("KFW_TLS_KEY") or None)
    sp.add_argument("--demo", action="store_true", help="a pretend fleet, for trying it out")
    sp.add_argument("--access-log", action="store_true", default=os.environ.get("KFW_ACCESS_LOG", "").lower() in ("1", "true", "yes"))
    sp.set_defaults(fn=cmd_serve)

    sc = sub.add_parser("scan", help="one scan of the fleet")
    sc.add_argument("--progress-file")
    sc.add_argument("--dry-run", action="store_true")
    sc.set_defaults(fn=cmd_scan)

    su = sub.add_parser("user", help="accounts")
    su.add_argument("action", choices=["list", "add", "passwd", "role", "disable", "enable", "remove", "import"])
    su.add_argument("name", nargs="?", help="the account (for import: the web-users.json file)")
    su.add_argument("role_pos", nargs="?", metavar="role", help="for 'role': operator or admin")
    su.add_argument("--role", choices=["operator", "admin"])
    su.add_argument("--must-change", action="store_true", help="they choose their own password at the next sign-in")
    su.set_defaults(fn=cmd_user)

    a = p.parse_args(argv)
    if getattr(a, "role_pos", None) and not a.role:
        a.role = a.role_pos
    return a.fn(a) or 0


if __name__ == "__main__":
    sys.exit(main())
