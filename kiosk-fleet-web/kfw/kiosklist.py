"""The kiosk list: which kiosks to scan, and what they are.

A .xlsx workbook (the master list), a .csv, or a .txt with one name per line.
The .xlsx reader is a plain OOXML zip + XML walk, the same as the PowerShell
one: no Excel, no extra packages.
"""
from __future__ import annotations

import csv
import io
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"


@dataclass
class RawRow:
    host: str
    location: str = ""
    type: str = ""
    has_mwst: str = ""
    active: str = ""
    restart_group: str = ""
    info: str = ""
    listed_version: str = ""
    sheet: str = ""


@dataclass
class Kiosk:
    host: str
    location: str
    type: str
    restart_group: str
    info: str
    listed_version: str
    sheet: str
    active: str
    runs_watchdog: bool
    ping_only: bool


@dataclass
class ListStats:
    rows: int = 0
    included: int = 0
    inactive: int = 0
    not_flagged: int = 0
    inactive_rows: list[RawRow] = field(default_factory=list)


def is_power_bi(kind: str) -> bool:
    return bool(kind) and re.match(r"^(PBI|POWER\s*BI)\b", kind.strip(), re.IGNORECASE) is not None


def is_web(kind: str) -> bool:
    return bool(kind) and re.match(r"^WEB\b", kind.strip(), re.IGNORECASE) is not None


# ---------------------------------------------------------------------------
# .xlsx
# ---------------------------------------------------------------------------
def _col_index(ref: str) -> int:
    n = 0
    for ch in re.sub(r"\d", "", ref).upper():
        n = n * 26 + (ord(ch) - 64)
    return n


def _si_text(node) -> str:
    # A shared string is a plain <t>, or <r><t> runs when part of the cell is
    # formatted differently; both are joined or names come back cut short.
    out = ""
    for child in node:
        tag = child.tag.split("}")[-1]
        if tag == "t":
            out += child.text or ""
        elif tag == "r":
            for rc in child:
                if rc.tag.split("}")[-1] == "t":
                    out += rc.text or ""
    return out


def read_xlsx(path: Path, sheet_name: str = "") -> list[RawRow]:
    rows: list[RawRow] = []
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())

        def xml(name):
            return ET.fromstring(z.read(name)) if name in names else None

        shared: list[str] = []
        ss = xml("xl/sharedStrings.xml")
        if ss is not None:
            shared = [_si_text(si) for si in ss.findall("m:si", NS)]

        wb = xml("xl/workbook.xml")
        rels = xml("xl/_rels/workbook.xml.rels")
        if wb is None or rels is None:
            raise ValueError(f"not a readable .xlsx workbook: {path}")
        targets = {r.get("Id"): r.get("Target") for r in rels.findall(f"{{{PKG_REL_NS}}}Relationship")}

        sheets = wb.findall("m:sheets/m:sheet", NS)
        if sheet_name:
            sheets = [s for s in sheets if s.get("name") == sheet_name]
            if not sheets:
                raise ValueError(f"sheet '{sheet_name}' not found in {path}")

        for sheet in sheets:
            target = targets.get(sheet.get(f"{{{REL_NS}}}id"))
            if not target:
                continue
            target = re.sub(r"^/?(xl/)?", "", target)
            doc = xml("xl/" + target)
            if doc is None:
                continue
            rows += _rows_from_sheet(doc, shared, sheet.get("name") or "")
    return rows


def _rows_from_sheet(doc, shared: list[str], sheet: str) -> list[RawRow]:
    grid: dict[int, dict[int, str]] = {}
    for row in doc.findall("m:sheetData/m:row", NS):
        rnum = int(row.get("r") or 0)
        cells: dict[int, str] = {}
        for c in row.findall("m:c", NS):
            ref = c.get("r")
            if not ref:
                continue
            t = c.get("t")
            v = c.find("m:v", NS)
            value = None
            if t == "s":
                if v is not None and v.text and v.text.isdigit() and int(v.text) < len(shared):
                    value = shared[int(v.text)]
            elif t == "inlineStr":
                is_ = c.find("m:is", NS)
                if is_ is not None:
                    value = _si_text(is_)
            elif v is not None:
                value = v.text
            if value is not None:
                cells[_col_index(ref)] = str(value).strip()
        grid[rnum] = cells

    numbers = sorted(grid)
    header_row = None
    header: dict[str, int] = {}
    # The header is the first row, within the first ten, naming the host column.
    for rnum in numbers[:10]:
        m = {re.sub(r"\s+", " ", v).strip().upper(): ci for ci, v in grid[rnum].items() if v}
        if "NAME" in m or "HOST" in m or "HOSTNAME" in m:
            header_row, header = rnum, m
            break
    if header_row is None:
        return []

    def col(*names):
        for n in names:
            if n in header:
                return header[n]
        return None

    c_host = col("NAME", "HOST", "HOSTNAME")
    c_type, c_flag, c_active = col("TYPE"), col("HAS MWST", "HASMWST", "MWST"), col("ACTIVE", "IS ACTIVE")
    c_loc, c_group, c_info, c_ver = col("LOCATION"), col("RESTART GROUP", "GROUP"), col("INFO"), col("VER", "VERSION")

    out = []
    for rnum in numbers:
        if rnum <= header_row:
            continue
        cells = grid[rnum]
        host = cells.get(c_host, "").strip()
        if not host:
            continue
        g = lambda c: cells.get(c, "") if c is not None else ""  # noqa: E731
        out.append(RawRow(host=host, location=g(c_loc), type=g(c_type), has_mwst=g(c_flag), active=g(c_active),
                          restart_group=g(c_group), info=g(c_info), listed_version=g(c_ver), sheet=sheet))
    return out


# ---------------------------------------------------------------------------
# Flat files
# ---------------------------------------------------------------------------
def read_flat(path: Path) -> list[RawRow]:
    text = path.read_bytes().decode("utf-8-sig", errors="replace")
    if path.suffix.lower() == ".csv":
        out = []
        for r in csv.DictReader(io.StringIO(text)):
            host = (r.get("Host") or r.get("Name") or "").strip()
            if not host:
                continue
            out.append(RawRow(
                host=host, location=r.get("Location") or "", type=r.get("Type") or "",
                has_mwst=r["HasMwst"] if "HasMwst" in r else "Y", active=r.get("Active") or "",
                restart_group=r.get("RestartGroup") or "", info=r.get("Info") or "", sheet="csv"))
        return out
    # One name per line; everything in such a file runs the watchdog.
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(RawRow(host=line, type="Mach2", has_mwst="Y", sheet="txt"))
    return out


def import_kiosk_list(path: Path, sheet_name: str = "", include_all: bool = False) -> tuple[list[Kiosk], ListStats]:
    """The kiosks to scan, and what was kept and skipped.

    ACTIVE is a deliberate yes/no and beats everything else; left blank it says
    nothing. HAS MWST = Y means the kiosk runs the watchdog. Power BI and web
    page kiosks are scanned without it, since a dark screen is as visible as a
    white one.
    """
    if not path.exists():
        raise FileNotFoundError(f"kiosk list not found: {path}")
    raw = read_xlsx(path, sheet_name) if path.suffix.lower() == ".xlsx" else read_flat(path)

    stats = ListStats()
    seen: set[str] = set()
    out: list[Kiosk] = []
    for row in raw:
        stats.rows += 1
        pbi, web = is_power_bi(row.type), is_web(row.type)
        has_mwst = row.has_mwst.strip().upper().startswith("Y")
        active_set = bool(row.active.strip())
        active = active_set and row.active.strip().upper().startswith("Y")
        if not include_all:
            if active_set and not active:
                stats.inactive += 1
                stats.inactive_rows.append(row)
                continue
            if not active_set and not has_mwst and not pbi and not web:
                stats.not_flagged += 1
                continue
        key = row.host.upper()
        if key in seen:
            continue
        seen.add(key)
        stats.included += 1
        out.append(Kiosk(
            host=row.host, location=row.location, type=row.type, restart_group=row.restart_group, info=row.info,
            listed_version=row.listed_version, sheet=row.sheet, active=row.active,
            runs_watchdog=has_mwst and not pbi and not web, ping_only=pbi or web or not has_mwst))
    return out, stats
