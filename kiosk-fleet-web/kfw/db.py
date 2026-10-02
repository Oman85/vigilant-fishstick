"""The app's own state, in one SQLite file in the data folder: accounts,
sessions, the audit log and failed sign-ins. The fleet itself stays in the
events CSV, which other things (the Power BI report) read too.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from datetime import datetime
from pathlib import Path

from . import auth

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    name        TEXT PRIMARY KEY COLLATE NOCASE,
    role        TEXT NOT NULL,
    algorithm   TEXT NOT NULL,
    iterations  INTEGER NOT NULL,
    salt        TEXT NOT NULL,
    hash        TEXT NOT NULL,
    disabled    INTEGER NOT NULL DEFAULT 0,
    must_change INTEGER NOT NULL DEFAULT 0,
    created     TEXT NOT NULL,
    updated     TEXT NOT NULL,
    last_login  TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
    token_hash  TEXT PRIMARY KEY,
    user        TEXT NOT NULL COLLATE NOCASE,
    csrf        TEXT NOT NULL,
    created     REAL NOT NULL,
    last_seen   REAL NOT NULL,
    ip          TEXT,
    agent       TEXT
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user);
CREATE TABLE IF NOT EXISTS audit (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    time    TEXT NOT NULL,
    user    TEXT,
    role    TEXT,
    ip      TEXT,
    action  TEXT NOT NULL,
    target  TEXT,
    result  TEXT,
    detail  TEXT
);
CREATE TABLE IF NOT EXISTS login_failures (
    key     TEXT PRIMARY KEY,
    count   INTEGER NOT NULL,
    first   REAL NOT NULL,
    until   REAL
);
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def _now_text() -> str:
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


class Database:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.lock = threading.RLock()
        self.conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA foreign_keys=ON")
            self.conn.executescript(SCHEMA)
        try:
            path.chmod(0o600)
        except OSError:
            pass

    def q(self, sql: str, args=()) -> list[sqlite3.Row]:
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def x(self, sql: str, args=()) -> int:
        with self.lock:
            return self.conn.execute(sql, args).rowcount

    # --- accounts ---------------------------------------------------------
    def users(self) -> list[dict]:
        return [dict(r) for r in self.q("SELECT name, role, disabled, must_change, created, updated, last_login FROM users ORDER BY name COLLATE NOCASE")]

    def user(self, name: str) -> dict | None:
        rows = self.q("SELECT * FROM users WHERE name = ?", (name,))
        return dict(rows[0]) if rows else None

    def user_count(self, active_admins_only: bool = False) -> int:
        if active_admins_only:
            return self.q("SELECT COUNT(*) FROM users WHERE role = 'admin' AND disabled = 0")[0][0]
        return self.q("SELECT COUNT(*) FROM users")[0][0]

    def add_user(self, name: str, role: str, password: str, must_change: bool = False) -> None:
        h = auth.hash_password(password)
        now = _now_text()
        self.x("INSERT INTO users (name, role, algorithm, iterations, salt, hash, disabled, must_change, created, updated) VALUES (?,?,?,?,?,?,0,?,?,?)",
               (name, role, h["Algorithm"], h["Iterations"], h["Salt"], h["Hash"], int(must_change), now, now))

    def import_user(self, name: str, role: str, record: dict, disabled: bool) -> None:
        now = _now_text()
        self.x("INSERT OR REPLACE INTO users (name, role, algorithm, iterations, salt, hash, disabled, must_change, created, updated) VALUES (?,?,?,?,?,?,?,0,?,?)",
               (name, role, record["Algorithm"], int(record["Iterations"]), record["Salt"], record["Hash"], int(disabled), now, now))

    def set_password(self, name: str, password: str, must_change: bool = False) -> None:
        h = auth.hash_password(password)
        self.x("UPDATE users SET algorithm=?, iterations=?, salt=?, hash=?, must_change=?, updated=? WHERE name=?",
               (h["Algorithm"], h["Iterations"], h["Salt"], h["Hash"], int(must_change), _now_text(), name))

    def set_role(self, name: str, role: str) -> None:
        self.x("UPDATE users SET role=?, updated=? WHERE name=?", (role, _now_text(), name))

    def set_disabled(self, name: str, disabled: bool) -> None:
        self.x("UPDATE users SET disabled=?, updated=? WHERE name=?", (int(disabled), _now_text(), name))

    def remove_user(self, name: str) -> None:
        with self.lock:
            self.x("DELETE FROM sessions WHERE user=?", (name,))
            self.x("DELETE FROM users WHERE name=?", (name,))

    def check_login(self, name: str, password: str) -> dict | None:
        """The account for a name and password, or None."""
        u = self.user(name) if name else None
        if not u:
            auth.burn_time(password)
            return None
        rec = {"Algorithm": u["algorithm"], "Iterations": u["iterations"], "Salt": u["salt"], "Hash": u["hash"]}
        if not auth.verify_password(rec, password) or u["disabled"] or u["role"] not in auth.ROLE_RANK:
            return None
        self.x("UPDATE users SET last_login=? WHERE name=?", (_now_text(), u["name"]))
        return u

    # --- sessions ---------------------------------------------------------
    def new_session(self, user: str, ip: str, agent: str) -> tuple[str, str]:
        token, csrf = auth.new_token(), auth.new_token()
        now = time.time()
        self.x("INSERT INTO sessions (token_hash, user, csrf, created, last_seen, ip, agent) VALUES (?,?,?,?,?,?,?)",
               (auth.token_hash(token), user, csrf, now, now, ip, (agent or "")[:200]))
        return token, csrf

    def session(self, token: str, idle_minutes: int, session_hours: int) -> dict | None:
        """The session and its account, or None if either has gone. A disabled
        or removed account, or a changed role, takes effect at once."""
        if not token:
            return None
        th = auth.token_hash(token)
        rows = self.q("SELECT s.*, u.role AS role, u.disabled AS disabled, u.must_change AS must_change, u.name AS uname "
                      "FROM sessions s JOIN users u ON u.name = s.user WHERE s.token_hash = ?", (th,))
        if not rows:
            return None
        s = dict(rows[0])
        now = time.time()
        if s["disabled"] or now - s["last_seen"] > idle_minutes * 60 or now - s["created"] > session_hours * 3600:
            self.x("DELETE FROM sessions WHERE token_hash=?", (th,))
            return None
        if now - s["last_seen"] > 5:
            self.x("UPDATE sessions SET last_seen=? WHERE token_hash=?", (now, th))
        s["user"] = s["uname"]
        s["token_hash"] = th
        return s

    def end_session(self, token_hash: str) -> None:
        self.x("DELETE FROM sessions WHERE token_hash=?", (token_hash,))

    def end_sessions_of(self, user: str, except_hash: str | None = None) -> None:
        if except_hash:
            self.x("DELETE FROM sessions WHERE user=? AND token_hash<>?", (user, except_hash))
        else:
            self.x("DELETE FROM sessions WHERE user=?", (user,))

    def sweep_sessions(self, idle_minutes: int, session_hours: int) -> None:
        now = time.time()
        self.x("DELETE FROM sessions WHERE last_seen < ? OR created < ?", (now - idle_minutes * 60, now - session_hours * 3600))

    def active_sessions(self) -> dict[str, int]:
        return {r[0]: r[1] for r in self.q("SELECT user, COUNT(*) FROM sessions GROUP BY user COLLATE NOCASE")}

    # --- sign-in lockout --------------------------------------------------
    def locked(self, key: str) -> bool:
        rows = self.q("SELECT until FROM login_failures WHERE key=?", (key,))
        return bool(rows and rows[0][0] and time.time() < rows[0][0])

    def add_failure(self, key: str, limit: int, window: int = 900, lock_for: int = 900) -> None:
        """Five wrong passwords for a name, or twenty from one address, inside
        a quarter of an hour: that name or address waits a quarter of an hour."""
        now = time.time()
        with self.lock:
            rows = self.q("SELECT count, first FROM login_failures WHERE key=?", (key,))
            if not rows or now - rows[0][1] > window:
                count, first = 0, now
            else:
                count, first = rows[0][0], rows[0][1]
            count += 1
            until = now + lock_for if count >= limit else None
            self.x("INSERT OR REPLACE INTO login_failures (key, count, first, until) VALUES (?,?,?,?)", (key, count, first, until))

    def clear_failures(self, key: str) -> None:
        self.x("DELETE FROM login_failures WHERE key=?", (key,))

    def sweep_failures(self) -> None:
        now = time.time()
        self.x("DELETE FROM login_failures WHERE first < ? AND (until IS NULL OR until < ?)", (now - 1800, now))

    # --- audit ------------------------------------------------------------
    def audit(self, user: str = "", role: str = "", ip: str = "", action: str = "", target: str = "", result: str = "", detail: str = "") -> None:
        self.x("INSERT INTO audit (time, user, role, ip, action, target, result, detail) VALUES (?,?,?,?,?,?,?,?)",
               (_now_text(), user or "", role or "", ip or "", action, target or "", result or "", (detail or "")[:600]))

    def audit_entries(self, limit: int = 400, text: str = "") -> list[dict]:
        if text:
            like = f"%{text}%"
            rows = self.q("SELECT * FROM audit WHERE user LIKE ? OR action LIKE ? OR target LIKE ? OR result LIKE ? OR detail LIKE ? "
                          "ORDER BY id DESC LIMIT ?", (like, like, like, like, like, limit))
        else:
            rows = self.q("SELECT * FROM audit ORDER BY id DESC LIMIT ?", (limit,))
        return [{"Time": r["time"], "User": r["user"], "Role": r["role"], "Ip": r["ip"], "Action": r["action"],
                 "Target": r["target"], "Result": r["result"], "Detail": r["detail"]} for r in rows]

    def audit_all(self):
        with self.lock:
            cur = self.conn.execute("SELECT time, user, role, ip, action, target, result, detail FROM audit ORDER BY id")
            return cur.fetchall()

    # --- meta -------------------------------------------------------------
    def meta(self, key: str) -> str | None:
        rows = self.q("SELECT value FROM meta WHERE key=?", (key,))
        return rows[0][0] if rows else None

    def set_meta(self, key: str, value: str | None) -> None:
        if value is None:
            self.x("DELETE FROM meta WHERE key=?", (key,))
        else:
            self.x("INSERT OR REPLACE INTO meta (key, value) VALUES (?,?)", (key, value))


def import_web_users(db: Database, path: Path) -> list[str]:
    """Accounts from the PowerShell server's Config\\web-users.json. Their
    password hashes carry over as they are, so nobody needs a new password."""
    doc = json.loads(path.read_text(encoding="utf-8-sig"))
    done = []
    for u in doc.get("Users") or []:
        name, role = str(u.get("Name") or ""), str(u.get("Role") or "")
        if not auth.valid_user_name(name) or role not in auth.ROLE_RANK:
            continue
        if u.get("Algorithm") != "PBKDF2-SHA256":
            continue
        db.import_user(name, role, u, bool(u.get("Disabled")))
        done.append(name)
    return done
