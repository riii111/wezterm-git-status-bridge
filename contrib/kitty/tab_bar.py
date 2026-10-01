# wezterm-git-status-bridge managed kitty adapter
from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path
from typing import NamedTuple

import kitty.tab_bar as kitty_tab_bar
from kitty.boss import get_boss
from kitty.fast_data_types import Screen, add_timer, remove_timer, wcswidth
from kitty.rgb import to_color
from kitty.tab_bar import (
    DrawData,
    ExtraData,
    TabAccessor,
    TabBarData,
    as_rgb,
    draw_tab_with_separator,
)
from kitty.utils import color_as_int


HERDR_PROCESS = "herdr"
REFRESH_SECONDS = 1.0
TIMER_ID_ATTRIBUTE = "_wezterm_git_status_bridge_timer_id"

STATUS_BG = "#1f1f28"
MUTED = "#565f89"
REPO = "#c0caf5"
REF = "#7dcfff"
DETACHED = "#ff9e64"
DIRTY = "#e6c384"
WORKTREE = "#9ece6a"
TIME = "#bb9af7"

SEPARATOR = "  \ue0b3  "
WORKTREE_TEXT = "\U000f0645 "
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)


class GitInfo(NamedTuple):
    at: int
    pane_id: str
    cwd: str
    present: bool
    repo: str
    ref: str
    flags: str


_active_tab: TabBarData | None = None


def _rgb(value: str) -> int:
    return as_rgb(color_as_int(to_color(value)))


def _cache_dir() -> Path:
    cache_home = os.environ.get("XDG_CACHE_HOME")
    if cache_home:
        return Path(cache_home) / "wezterm"
    return Path.home() / ".cache" / "wezterm"


def _normalize_path(path: str) -> str:
    if path == "/" or (len(path) == 3 and path[1:] in {":/", ":\\"}):
        return path
    return path.rstrip("/\\")


def _cwd_cache_key(cwd: str) -> str:
    value = 2_166_136_261
    for byte in cwd.encode("utf-8"):
        value ^= byte
        value = value * 16_777_619 & 0xFFFFFFFF
    return f"{value:08x}"


def _read_line(path: Path) -> str | None:
    try:
        with path.open(encoding="utf-8") as source:
            return source.readline().rstrip("\n")
    except (OSError, UnicodeError):
        return None


def _parse_payload(value: str | None) -> GitInfo | None:
    if not value:
        return None

    fields = value.split("\t")
    if len(fields) < 8 or fields[0] != "herdrgit1" or not fields[1].isdigit():
        return None
    if fields[4] not in {"0", "1"}:
        return None

    present = fields[4] == "1"
    if present and (not fields[5] or not fields[6]):
        return None

    return GitInfo(
        at=int(fields[1]),
        pane_id=fields[2],
        cwd=fields[3],
        present=present,
        repo=fields[5] if present else "",
        ref=fields[6] if present else "",
        flags=fields[7],
    )


def _read_cwd_info(cwd: str) -> GitInfo | None:
    normalized = _normalize_path(cwd)
    path = _cache_dir() / "herdr-git-info-by-cwd" / _cwd_cache_key(normalized)
    info = _parse_payload(_read_line(path))
    if not info or _normalize_path(info.cwd) != normalized:
        return None
    return info


def _read_git_info(cwd: str, executable: str) -> GitInfo | None:
    if Path(executable).name != HERDR_PROCESS:
        info = _read_cwd_info(cwd)
        return info if info and info.present else None

    focused = _parse_payload(_read_line(_cache_dir() / "herdr-git-info-focused"))
    if not focused:
        return None
    cwd_info = _read_cwd_info(focused.cwd)
    chosen = cwd_info if cwd_info and cwd_info.at >= focused.at else focused
    return chosen if chosen.present else None


def _git_cells(info: GitInfo) -> list[tuple[str, str]]:
    cells = [(REPO, f"  {info.repo}"), (MUTED, SEPARATOR)]
    if "w" in info.flags:
        cells.append((WORKTREE, WORKTREE_TEXT))
    cells.append((DETACHED if "D" in info.flags else REF, f" {info.ref}"))
    if "d" in info.flags:
        cells.append((DIRTY, " *"))
    if "R" in info.flags:
        cells.append((DETACHED, " REBASE"))
    if "C" in info.flags:
        cells.append((DETACHED, " PICK"))
    return cells


def _format_time(now: datetime | None = None) -> str:
    current = now or datetime.now()
    return (
        f"{WEEKDAYS[current.weekday()]} {MONTHS[current.month - 1]} "
        f"{current.day:2d} {current:%H:%M}"
    )


def _time_cells() -> list[tuple[str, str]]:
    return [(MUTED, SEPARATOR), (TIME, f" {_format_time()}  ")]


def _cells_width(cells: list[tuple[str, str]]) -> int:
    return sum(max(wcswidth(text), 0) for _, text in cells)


def _fit_cells(info: GitInfo | None, available: int) -> list[tuple[str, str]]:
    time_cells = _time_cells()
    candidates = [time_cells]
    if info:
        git_cells = _git_cells(info)
        compact_git = [(DETACHED if "D" in info.flags else REF, f" {info.ref}")]
        if "d" in info.flags:
            compact_git.append((DIRTY, " *"))
        candidates = [git_cells + time_cells, compact_git + time_cells, time_cells]

    for cells in candidates:
        if _cells_width(cells) < available:
            return cells
    return []


def _draw_right_status(screen: Screen, tab: TabBarData, tab_end: int) -> None:
    accessor = TabAccessor(tab.tab_id)
    cwd = accessor.active_wd or ""
    executable = accessor.active_exe or ""
    info = _read_git_info(cwd, executable) if cwd else None
    cells = _fit_cells(info, screen.columns - tab_end)
    width = _cells_width(cells)
    if not cells or width <= 0:
        return

    screen.cursor.x = screen.columns - width
    screen.cursor.bg = _rgb(STATUS_BG)
    screen.cursor.bold = False
    screen.cursor.italic = False
    for color, text in cells:
        screen.cursor.fg = _rgb(color)
        screen.draw(text)


def _redraw_tab_bars(_timer_id: int) -> None:
    boss = get_boss()
    for tab_manager in boss.os_window_map.values():
        tab_manager.mark_tab_bar_dirty()


def _remove_previous_redraw_timer() -> None:
    timer_id = getattr(kitty_tab_bar, TIMER_ID_ATTRIBUTE, None)
    if timer_id is not None:
        remove_timer(timer_id)
        delattr(kitty_tab_bar, TIMER_ID_ATTRIBUTE)


def _ensure_redraw_timer() -> None:
    if getattr(kitty_tab_bar, TIMER_ID_ATTRIBUTE, None) is None:
        timer_id = add_timer(_redraw_tab_bars, REFRESH_SECONDS, True)
        setattr(kitty_tab_bar, TIMER_ID_ATTRIBUTE, timer_id)


_remove_previous_redraw_timer()


def draw_tab(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    before: int,
    max_title_length: int,
    index: int,
    is_last: bool,
    extra_data: ExtraData,
) -> int:
    global _active_tab
    if index == 1:
        _active_tab = None
    if tab.is_active:
        _active_tab = tab

    end = draw_tab_with_separator(
        draw_data,
        screen,
        tab,
        before,
        max_title_length,
        index,
        is_last,
        extra_data,
    )
    if is_last and not extra_data.for_layout:
        _ensure_redraw_timer()
        _draw_right_status(screen, _active_tab or tab, end)
    return end
