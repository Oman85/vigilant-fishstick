"""Reaching a kiosk over the network: is it there, and restarting it.

Reachability is ICMP first, two attempts - one dropped packet should not mark
a kiosk offline - then SMB on 445, because a kiosk whose firewall drops ping
but serves the admin share is reachable for every purpose that matters here.

Restarts go over WMI/DCOM, as the PowerShell tools did with CIM:
Win32_OperatingSystem.Win32ShutdownTracker with flags 6 (reboot + force), a
countdown and a comment that Windows shows on the screen and writes into event
1074. impacket speaks DCOM from Linux; nothing is installed on the kiosk.
"""
from __future__ import annotations

import socket
import subprocess
from dataclasses import dataclass

from .config import Settings


@dataclass
class Reach:
    ok: bool
    method: str | None
    error: str | None


def tcp_port_open(host: str, port: int, timeout_ms: int = 1000) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_ms / 1000):
            return True
    except OSError:
        return False


def test_host_reachable(host: str, settings: Settings, timeout_ms: int | None = None) -> Reach:
    if not settings.uses_smb or settings.offline_ok:
        return Reach(True, "local", None)
    timeout_ms = timeout_ms or settings.ping_timeout_ms

    try:
        socket.getaddrinfo(host, 445)
    except OSError as e:
        # The name does not resolve, so neither a second ping nor a port probe will help.
        return Reach(False, None, f"Name/ping failure: {e}")

    last = None
    secs = max(1, round(timeout_ms / 1000))
    for _ in range(2):
        try:
            r = subprocess.run(["ping", "-c", "1", "-W", str(secs), host], capture_output=True, timeout=secs + 3)
            if r.returncode == 0:
                return Reach(True, "ping", None)
            last = "No ping reply"
        except FileNotFoundError:
            last = "ping is not installed"
            break
        except subprocess.TimeoutExpired:
            last = "No ping reply (timed out)"

    if tcp_port_open(host, 445, timeout_ms):
        return Reach(True, "smb", None)
    return Reach(False, None, last)


@dataclass
class RestartResult:
    sent: bool
    via: str
    detail: str


def _split_user(user: str) -> tuple[str, str]:
    if "\\" in user:
        domain, name = user.split("\\", 1)
        return domain, name
    if "@" in user:
        name, domain = user.split("@", 1)
        return domain, name
    return "", user


def send_kiosk_restart(host: str, settings: Settings, warning_seconds: int = 0, comment: str = "",
                       reason_code: int = 0x80000000) -> RestartResult:
    """Restarts a kiosk over WMI. A call that broke off after it was sent is
    also what a kiosk going down mid-reply looks like, so that counts as sent:
    asking again could restart it a second time once it is back."""
    comment = (comment or "")[:500]
    try:
        from impacket.dcerpc.v5.dcom import wmi
        from impacket.dcerpc.v5.dcomrt import DCOMConnection
        from impacket.dcerpc.v5.dtypes import NULL
    except ImportError as e:  # pragma: no cover - the image always has it
        return RestartResult(False, "", f"impacket is missing: {e}")

    domain, user = _split_user(settings.kiosk_user)
    dcom = None
    try:
        try:
            dcom = DCOMConnection(host, user, settings.kiosk_password, domain, oxidResolver=True)
            iface = dcom.CoCreateInstanceEx(wmi.CLSID_WbemLevel1Login, wmi.IID_IWbemLevel1Login)
            login = wmi.IWbemLevel1Login(iface)
            services = login.NTLMLogin("//./root/cimv2", NULL, NULL)
            login.RemRelease()
            enum = services.ExecQuery("SELECT * FROM Win32_OperatingSystem")
            os_obj = enum.Next(0xFFFFFFFF, 1)[0]
        except Exception as e:  # noqa: BLE001 - every failure is a sentence for a person
            return RestartResult(False, "", f"WMI/DCOM: {e}")

        try:
            # Flags 6 = reboot (2) + force (4): a kiosk has nobody to answer
            # "this app is preventing restart".
            out = os_obj.Win32ShutdownTracker(max(0, int(warning_seconds)), comment, reason_code, 6)
        except Exception as e:  # noqa: BLE001
            return RestartResult(True, "WMI/DCOM (reply lost)", str(e))

        code = None
        try:
            code = out.getProperties()["ReturnValue"]["value"]
        except Exception:  # noqa: BLE001 - no reply object: it went
            pass
        if code in (None, 0):
            return RestartResult(True, "WMI/DCOM", "")
        return RestartResult(False, "", f"WMI/DCOM: Win32ShutdownTracker returned {code}")
    finally:
        if dcom is not None:
            try:
                dcom.disconnect()
            except Exception:  # noqa: BLE001
                pass
