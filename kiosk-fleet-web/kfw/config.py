"""Settings, all from the environment (KFW_*), so one image fits every site.

Secrets can come from a file instead of the variable itself - KIOSK_ADMIN_PASSWORD_FILE
next to KIOSK_ADMIN_PASSWORD - which is how Docker secrets are mounted.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path


def _env(name: str, default: str = "") -> str:
    """A variable, or the contents of the file named by <name>_FILE."""
    path = os.environ.get(name + "_FILE")
    if path:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            return default
    return os.environ.get(name, default)


def _bool(name: str, default: bool) -> bool:
    v = _env(name, "").strip().lower()
    if not v:
        return default
    return v in ("1", "true", "yes", "on", "y")


def _int(name: str, default: int, lo: int, hi: int) -> int:
    v = _env(name, "").strip()
    if not v:
        return default
    try:
        n = int(v)
    except ValueError:
        raise SystemExit(f"{name} has to be a whole number, not '{v}'")
    if n < lo or n > hi:
        raise SystemExit(f"{name} has to be {lo} to {hi}, not {n}")
    return n


@dataclass
class Settings:
    data_dir: Path = Path("/data")

    # Each kiosk's C: drive. {0} is the host name. A UNC path (\\{0}\C$) is
    # read over SMB; anything else is a local folder per kiosk (tests, demos).
    root_template: str = r"\\{0}\C$"
    kiosk_user: str = ""
    kiosk_password: str = ""
    smb_auth: str = "ntlm"            # ntlm | negotiate | kerberos
    smb_timeout: int = 20

    kiosk_list: str = ""              # .xlsx, .csv or .txt; default: the uploaded one in data_dir
    kiosk_list_sheet: str = ""
    include_all_hosts: bool = False
    publish_csv: str = ""             # optional second copy of the events CSV (a synced SharePoint folder)

    autoscan: bool = True
    autoscan_minutes: int = 15
    stale_minutes: int = 45           # the dashboard calls the data stale after this
    refresh_seconds: int = 5

    # The collector
    agent_stale_minutes: int = 10
    launcher_stale_minutes: int = 5
    parallel_hosts: int = 8
    host_timeout_seconds: int = 180
    ping_timeout_ms: int = 1500
    retention_days: int = 400
    run_row_retention_days: int = 30
    reconcile_days: int = 30
    keepalive_hours: int = 24
    heartbeat_minutes: int = 60
    trusted_from_agent_version: str = "6.1"
    keep_pre_upgrade_history: bool = False

    # Sessions
    idle_minutes: int = 30
    session_hours: int = 10
    secure_cookies: str = "auto"      # auto | true | false
    trust_proxy: bool = False         # believe X-Forwarded-Proto / X-Forwarded-For

    restart_message: str = "IT is restarting this kiosk remotely. Please do not switch it off - it will come back on its own."
    restart_warning_seconds: int = 60
    sccm_site_server: str = ""

    bootstrap_admin: str = ""
    bootstrap_password: str = ""

    templates_dir: Path = field(default_factory=lambda: Path(__file__).parent / "templates")
    web_dir: Path = field(default_factory=lambda: Path(__file__).parent / "web")

    # For the tests: skip the network reachability check and the SMB login.
    offline_ok: bool = False

    @property
    def db_path(self) -> Path:
        return self.data_dir / "kfw.sqlite3"

    @property
    def log_dir(self) -> Path:
        return self.data_dir / "logs"

    @property
    def run_dir(self) -> Path:
        return self.log_dir / "run"

    @property
    def snapshot_dir(self) -> Path:
        return self.log_dir / "snapshots"

    @property
    def local_csv(self) -> Path:
        return self.data_dir / "MWST_FleetEvents.csv"

    @property
    def events_csv(self) -> Path:
        """The CSV the dashboard reads: the published one if there is one."""
        return Path(self.publish_csv) if self.publish_csv else self.local_csv

    @property
    def uses_smb(self) -> bool:
        return self.root_template.startswith("\\\\")

    @property
    def has_credential(self) -> bool:
        return bool(self.kiosk_user and self.kiosk_password)

    def resolve_kiosk_list(self) -> Path | None:
        if self.kiosk_list:
            return Path(self.kiosk_list)
        for name in ("kiosk-list.xlsx", "kiosk-list.csv", "kiosk-list.txt"):
            p = self.data_dir / name
            if p.exists():
                return p
        return None

    def ensure_dirs(self) -> None:
        for d in (self.data_dir, self.log_dir, self.run_dir, self.snapshot_dir):
            d.mkdir(parents=True, exist_ok=True)


def settings_json(s: Settings) -> str:
    """The settings, for a child process (the collector) to pick up as they are."""
    return json.dumps({k: (str(v) if isinstance(v, Path) else v) for k, v in asdict(s).items()})


def load_settings() -> Settings:
    passed = os.environ.get("KFW_SETTINGS_JSON")
    if passed:
        data = json.loads(passed)
        kinds = {f.name: f.type for f in fields(Settings)}
        return Settings(**{k: (Path(v) if "Path" in str(kinds.get(k)) else v) for k, v in data.items() if k in kinds})
    s = Settings(
        data_dir=Path(_env("KFW_DATA_DIR", "/data")),
        root_template=_env("KFW_ROOT_TEMPLATE", r"\\{0}\C$"),
        kiosk_user=_env("KIOSK_ADMIN_USER"),
        kiosk_password=_env("KIOSK_ADMIN_PASSWORD"),
        smb_auth=_env("KFW_SMB_AUTH", "ntlm").lower(),
        smb_timeout=_int("KFW_SMB_TIMEOUT", 20, 2, 300),
        kiosk_list=_env("KFW_KIOSK_LIST"),
        kiosk_list_sheet=_env("KFW_KIOSK_LIST_SHEET"),
        include_all_hosts=_bool("KFW_INCLUDE_ALL_HOSTS", False),
        publish_csv=_env("KFW_PUBLISH_CSV"),
        autoscan=_bool("KFW_AUTOSCAN", True),
        autoscan_minutes=_int("KFW_AUTOSCAN_MINUTES", 15, 1, 1440),
        stale_minutes=_int("KFW_STALE_MINUTES", 45, 1, 10080),
        refresh_seconds=_int("KFW_REFRESH_SECONDS", 5, 1, 3600),
        agent_stale_minutes=_int("KFW_AGENT_STALE_MINUTES", 10, 1, 1440),
        launcher_stale_minutes=_int("KFW_LAUNCHER_STALE_MINUTES", 5, 1, 1440),
        parallel_hosts=_int("KFW_PARALLEL_HOSTS", 8, 1, 64),
        host_timeout_seconds=_int("KFW_HOST_TIMEOUT_SECONDS", 180, 15, 900),
        ping_timeout_ms=_int("KFW_PING_TIMEOUT_MS", 1500, 100, 10000),
        retention_days=_int("KFW_RETENTION_DAYS", 400, 30, 3650),
        run_row_retention_days=_int("KFW_RUN_ROW_RETENTION_DAYS", 30, 1, 3650),
        reconcile_days=_int("KFW_RECONCILE_DAYS", 30, 1, 3650),
        keepalive_hours=_int("KFW_KEEPALIVE_HOURS", 24, 1, 720),
        heartbeat_minutes=_int("KFW_HEARTBEAT_MINUTES", 60, 1, 1440),
        trusted_from_agent_version=_env("KFW_TRUSTED_FROM_AGENT_VERSION", "6.1"),
        keep_pre_upgrade_history=_bool("KFW_KEEP_PRE_UPGRADE_HISTORY", False),
        idle_minutes=_int("KFW_IDLE_MINUTES", 30, 5, 1440),
        session_hours=_int("KFW_SESSION_HOURS", 10, 1, 168),
        secure_cookies=_env("KFW_SECURE_COOKIES", "auto").lower(),
        trust_proxy=_bool("KFW_TRUST_PROXY", False),
        restart_message=_env("KFW_RESTART_MESSAGE", Settings.restart_message),
        restart_warning_seconds=_int("KFW_RESTART_WARNING_SECONDS", 60, 0, 3600),
        sccm_site_server=_env("KFW_SCCM_SITE_SERVER"),
        bootstrap_admin=_env("KFW_ADMIN_USER"),
        bootstrap_password=_env("KFW_ADMIN_PASSWORD"),
    )
    if s.smb_auth not in ("ntlm", "negotiate", "kerberos"):
        raise SystemExit("KFW_SMB_AUTH is ntlm, negotiate or kerberos")
    if s.secure_cookies not in ("auto", "true", "false"):
        raise SystemExit("KFW_SECURE_COOKIES is auto, true or false")
    return s
