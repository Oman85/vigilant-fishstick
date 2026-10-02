"""Who may use the app, and what they may do.

Two roles:

  operator  sees everything, and can do what cannot break a kiosk: scan now,
            read live, screenshot, reload, restart the browser, a message on
            the screen, the launcher log
  admin     everything: restart a kiosk, hold/resume, stop, the sign-in
            password, the kiosk config, the deploy command builder,
            auto-scan, stopping a run, the audit log, users and settings

Accounts live in the app's database with a salted PBKDF2-SHA256 hash of the
password, never the password itself - the same hash format as the PowerShell
server's Config\\web-users.json, which can be imported as it is.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets

ROLE_RANK = {"operator": 1, "admin": 2}

# The least role each thing needs. Anything not listed needs admin.
PERMISSIONS = {
    "view": "operator", "scan": "operator", "live": "operator", "snapshot": "operator",
    "reload": "operator", "relaunch": "operator", "message": "operator", "log": "operator",
    "restart": "admin", "hold": "admin", "resume": "admin", "stop": "admin", "password": "admin",
    "config": "admin", "deploy": "admin", "autoscan": "admin", "stoprun": "admin", "audit": "admin",
    "users": "admin", "settings": "admin",
}

HASH_ITERATIONS = 210_000


def allowed(role: str | None, action: str) -> bool:
    if not role or role not in ROLE_RANK:
        return False
    need = PERMISSIONS.get(action, "admin")
    return ROLE_RANK[role] >= ROLE_RANK[need]


def allowed_actions(role: str | None) -> list[str]:
    return sorted(a for a in PERMISSIONS if allowed(role, a))


def new_token(nbytes: int = 32) -> str:
    return secrets.token_urlsafe(nbytes)


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def hash_password(password: str, iterations: int = HASH_ITERATIONS) -> dict:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, 32)
    return {"Algorithm": "PBKDF2-SHA256", "Iterations": iterations,
            "Salt": base64.b64encode(salt).decode(), "Hash": base64.b64encode(digest).decode()}


def verify_password(record: dict | None, password: str) -> bool:
    if not record or record.get("Algorithm") != "PBKDF2-SHA256" or not record.get("Salt") or not record.get("Hash"):
        return False
    try:
        salt = base64.b64decode(record["Salt"])
        want = base64.b64decode(record["Hash"])
        got = hashlib.pbkdf2_hmac("sha256", (password or "").encode("utf-8"), salt, int(record["Iterations"]), len(want))
        return hmac.compare_digest(got, want)
    except (ValueError, TypeError):
        return False


_DUMMY: dict | None = None


def burn_time(password: str) -> None:
    """A name that does not exist costs the same work as one that does, so
    how long a sign-in takes says nothing about which names are real."""
    global _DUMMY
    if _DUMMY is None:
        _DUMMY = hash_password(secrets.token_hex(16))
    verify_password(_DUMMY, password)


def valid_user_name(name: str) -> bool:
    return bool(re.match(r"^[A-Za-z0-9][A-Za-z0-9._@-]{1,63}$", name or ""))


def password_problem(password: str, user_name: str = "") -> str | None:
    """Why a password is not good enough, or None."""
    if not password or len(password) < 12:
        return "at least 12 characters"
    if len(password) > 256:
        return "at most 256 characters"
    if user_name and user_name.lower() in password.lower():
        return "not containing the account name"
    kinds = sum(1 for rx in (r"[a-z]", r"[A-Z]", r"[0-9]", r"[^A-Za-z0-9]") if re.search(rx, password))
    if kinds < 3 and len(password) < 20:
        return "three of: lower case, upper case, digits, symbols (or 20 characters or more)"
    return None
