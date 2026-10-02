"""A kiosk's C: drive, over SMB or - for tests and demos - in a local folder.

Everything that reads or writes a kiosk goes through KPath, a small
pathlib-like handle that knows which kiosk it is on. Paths are written the
Windows way (Users\\Public\\Documents) and each backend turns them into its own.

SMB uses smbprotocol (pure Python, no mount, no root): the admin share is
opened with the kiosk-admin credential, exactly as the PowerShell tools did
with New-PSDrive. Reads open the file with share mode read/write/delete, so a
launcher can keep appending to or rolling over a file while it is read.
"""
from __future__ import annotations

import logging
import os
import re
import shutil
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .config import Settings

# smbclient closes its connections when Python exits and logs a traceback for
# every kiosk that has already let go of its session: noise, not news.
logging.getLogger("smbclient._pool").setLevel(logging.CRITICAL)

HOST_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")


def clean_host(text: str | None) -> str | None:
    """A typed name ("  \\\\PC-01 " -> "PC-01"), or None for anything that is not one."""
    if not text:
        return None
    name = text.strip().strip("\\")
    return name if HOST_PATTERN.match(name) else None


class KioskError(Exception):
    """Something a person can read: offline, no access, not found."""


@dataclass
class Entry:
    name: str
    path: "KPath"
    is_dir: bool
    mtime: datetime | None
    size: int


def _split(rel: str) -> tuple[str, ...]:
    return tuple(p for p in re.split(r"[\\/]+", rel) if p)


class KPath:
    __slots__ = ("fs", "host", "parts")

    def __init__(self, fs: "KioskFS", host: str, parts: tuple[str, ...] = ()):
        self.fs = fs
        self.host = host
        self.parts = parts

    def __truediv__(self, rel: str) -> "KPath":
        return KPath(self.fs, self.host, self.parts + _split(rel))

    def __repr__(self) -> str:
        return f"KPath({self.host}:{self.rel})"

    def __eq__(self, other: object) -> bool:
        return isinstance(other, KPath) and other.host == self.host and tuple(p.lower() for p in other.parts) == tuple(p.lower() for p in self.parts)

    def __hash__(self) -> int:
        return hash((self.host, tuple(p.lower() for p in self.parts)))

    @property
    def name(self) -> str:
        return self.parts[-1] if self.parts else ""

    @property
    def parent(self) -> "KPath":
        return KPath(self.fs, self.host, self.parts[:-1])

    @property
    def rel(self) -> str:
        """As the kiosk sees it, under C:."""
        return "\\".join(self.parts)

    def __str__(self) -> str:
        return self.fs.backend.to_str(self)

    # --- what can be done with it -------------------------------------
    def exists(self) -> bool:
        return self.fs.backend.exists(self)

    def is_dir(self) -> bool:
        return self.fs.backend.is_dir(self)

    def is_file(self) -> bool:
        return self.fs.backend.is_file(self)

    def iterdir(self) -> list[Entry]:
        """Its entries, or [] when it is not there or not readable."""
        try:
            return self.fs.backend.listdir(self)
        except OSError:
            return []

    def dirs(self) -> list[Entry]:
        return [e for e in self.iterdir() if e.is_dir]

    def files(self, pattern: str | None = None) -> list[Entry]:
        rx = _glob_rx(pattern) if pattern else None
        return [e for e in self.iterdir() if not e.is_dir and (rx is None or rx.match(e.name))]

    def mtime(self) -> datetime | None:
        try:
            return self.fs.backend.stat(self)[0]
        except OSError:
            return None

    def size(self) -> int:
        return self.fs.backend.stat(self)[1]

    def read_bytes(self, tail: int | None = None, head: int | None = None) -> bytes:
        """The whole file, or only its last `tail` / first `head` bytes."""
        return self.fs.backend.read(self, tail, head)

    def read_text(self, tail: int | None = None, head: int | None = None) -> str:
        data = self.read_bytes(tail, head)
        if data.startswith(b"\xef\xbb\xbf"):
            data = data[3:]
        return data.decode("utf-8", errors="replace")

    def write_text(self, text: str, bom: bool = False) -> None:
        """Written whole under a temporary name, then moved into place, so
        nobody on the kiosk ever reads half of it."""
        data = (b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8")
        tmp = self.parent / f"~{self.name}.{uuid.uuid4().hex[:8]}.tmp"
        self.fs.backend.write(tmp, data)
        try:
            try:
                self.fs.backend.replace(tmp, self)
            except OSError:
                # Some servers refuse to replace a file they would let us
                # delete (Samba, for one, over a file without the archive
                # bit). Delete, then move: a moment without the file, but
                # never half of one.
                if not self.exists():
                    raise
                self.fs.backend.remove(self)
                self.fs.backend.replace(tmp, self)
        except OSError:
            try:
                self.fs.backend.remove(tmp)
            except OSError:
                pass
            raise

    def copy(self, dest: "KPath") -> None:
        self.fs.backend.write(dest, self.read_bytes())

    def unlink(self, missing_ok: bool = True) -> None:
        try:
            self.fs.backend.remove(self)
        except FileNotFoundError:
            if not missing_ok:
                raise
        except OSError:
            if self.exists() or not missing_ok:
                raise

    def mkdir(self) -> None:
        self.fs.backend.makedirs(self)

    def copy_to_local(self, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(self.read_bytes())


def _glob_rx(pattern: str) -> re.Pattern:
    out = ""
    for ch in pattern:
        out += ".*" if ch == "*" else "." if ch == "?" else re.escape(ch)
    return re.compile("^" + out + "$", re.IGNORECASE)


def _utc(ts: float) -> datetime:
    return datetime.fromtimestamp(ts, tz=timezone.utc)


# ---------------------------------------------------------------------------
# Backends
# ---------------------------------------------------------------------------
class LocalBackend:
    """A folder per kiosk, standing in for its C: drive."""

    def __init__(self, template: str):
        self.template = template

    def base(self, host: str) -> Path:
        return Path(self.template.replace("{0}", host))

    def local(self, p: KPath) -> Path:
        return self.base(p.host).joinpath(*p.parts) if p.parts else self.base(p.host)

    def to_str(self, p: KPath) -> str:
        return str(self.local(p))

    def connect(self, host: str, settings: Settings) -> None:
        if not self.base(host).is_dir():
            raise KioskError(f"cannot read {self.base(host)}")

    def exists(self, p): return self.local(p).exists()
    def is_dir(self, p): return self.local(p).is_dir()
    def is_file(self, p): return self.local(p).is_file()

    def listdir(self, p):
        out = []
        with os.scandir(self.local(p)) as it:
            for e in it:
                try:
                    st = e.stat()
                    out.append(Entry(e.name, p / e.name, e.is_dir(), _utc(st.st_mtime), st.st_size))
                except OSError:
                    continue
        return out

    def stat(self, p):
        st = self.local(p).stat()
        return _utc(st.st_mtime), st.st_size

    def read(self, p, tail, head=None):
        with open(self.local(p), "rb") as f:
            if head:
                return f.read(head)
            if tail:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - tail))
            return f.read()

    def write(self, p, data):
        self.local(p).parent.mkdir(parents=True, exist_ok=True)
        with open(self.local(p), "wb") as f:
            f.write(data)

    def replace(self, src, dst):
        os.replace(self.local(src), self.local(dst))

    def remove(self, p):
        os.remove(self.local(p))

    def makedirs(self, p):
        self.local(p).mkdir(parents=True, exist_ok=True)


def _as_oserror(fn):
    """Every SMB failure as an OSError, so callers handle one kind of error."""
    import functools

    @functools.wraps(fn)
    def wrapper(*a, **kw):
        try:
            return fn(*a, **kw)
        except OSError:
            raise
        except Exception as e:  # noqa: BLE001 - smbprotocol has errors of its own
            raise OSError(f"{type(e).__name__}: {e}") from e
    return wrapper


class SmbBackend:
    """\\\\HOST\\C$ over SMB2/3, with the kiosk-admin credential."""

    def __init__(self, template: str):
        self.template = template
        self._lock = threading.Lock()
        self._locks: dict[str, threading.Lock] = {}
        import smbclient  # noqa: F401  (fails early when the package is missing)

    def _server_lock(self, server: str) -> threading.Lock:
        with self._lock:
            return self._locks.setdefault(server.lower(), threading.Lock())

    def base(self, host: str) -> str:
        return self.template.replace("{0}", host).rstrip("\\")

    def to_str(self, p: KPath) -> str:
        return self.base(p.host) + ("\\" + "\\".join(p.parts) if p.parts else "")

    def connect(self, host: str, settings: Settings) -> None:
        import smbclient
        from smbprotocol.exceptions import SMBException

        server = self.base(host).lstrip("\\").split("\\", 1)[0]
        try:
            # One at a time per server: smbclient keeps its connections in one
            # cache, and two threads opening a session to the same server at
            # once leave one holding a connection the other has replaced.
            with self._server_lock(server):
                smbclient.register_session(
                    server,
                    username=settings.kiosk_user or None,
                    password=settings.kiosk_password or None,
                    auth_protocol=settings.smb_auth,
                    connection_timeout=settings.smb_timeout,
                )
        except (SMBException, OSError, ValueError) as e:
            raise KioskError(f"cannot open {self.base(host)}: {e}") from e

    def exists(self, p):
        import smbclient.path
        try:
            return smbclient.path.exists(self.to_str(p))
        except Exception:  # noqa: BLE001 - a share that will not answer is "not there"
            return False

    def is_dir(self, p):
        import smbclient.path
        try:
            return smbclient.path.isdir(self.to_str(p))
        except Exception:  # noqa: BLE001
            return False

    def is_file(self, p):
        import smbclient.path
        try:
            return smbclient.path.isfile(self.to_str(p))
        except Exception:  # noqa: BLE001
            return False

    @_as_oserror
    def listdir(self, p):
        import smbclient
        out = []
        for e in smbclient.scandir(self.to_str(p)):
            try:
                st = e.stat()
                out.append(Entry(e.name, p / e.name, e.is_dir(), _utc(st.st_mtime), st.st_size))
            except OSError:
                continue
        return out

    @_as_oserror
    def stat(self, p):
        import smbclient
        st = smbclient.stat(self.to_str(p))
        return _utc(st.st_mtime), st.st_size

    @_as_oserror
    def read(self, p, tail, head=None):
        import smbclient
        with smbclient.open_file(self.to_str(p), mode="rb", share_access="rwd") as f:
            if head:
                return f.read(head)
            if tail:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - tail))
            return f.read()

    @_as_oserror
    def write(self, p, data):
        import smbclient
        with smbclient.open_file(self.to_str(p), mode="wb", share_access="r") as f:
            f.write(data)

    def replace(self, src, dst):
        import smbclient
        smbclient.replace(self.to_str(src), self.to_str(dst))

    @_as_oserror
    def remove(self, p):
        import smbclient
        smbclient.remove(self.to_str(p))

    @_as_oserror
    def makedirs(self, p):
        import smbclient
        smbclient.makedirs(self.to_str(p), exist_ok=True)


class KioskFS:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.backend = SmbBackend(settings.root_template) if settings.uses_smb else LocalBackend(settings.root_template)

    def root(self, host: str) -> KPath:
        return KPath(self, host)

    def public_docs(self, host: str) -> KPath:
        return KPath(self, host, ("Users", "Public", "Documents"))

    def connect(self, host: str) -> KPath:
        """The kiosk's C: drive, opened. Raises KioskError if it cannot be."""
        self.backend.connect(host, self.settings)
        root = self.root(host)
        if not (root / "Users").is_dir():
            raise KioskError(f"cannot read {root}\\Users")
        return root

    def unc_hint(self, host: str) -> str:
        """Where a person opens the share from their own PC."""
        if self.settings.uses_smb:
            return self.settings.root_template.replace("{0}", host) + r"\Users\Public\Documents"
        return str(Path(self.settings.root_template.replace("{0}", host)) / "Users" / "Public" / "Documents")


def copy_local_file(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
