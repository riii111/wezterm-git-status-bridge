from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import types
import unittest
from collections import namedtuple
from datetime import datetime
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "contrib" / "kitty" / "tab_bar.py"


class FakeCursor:
    def __init__(self) -> None:
        self.x = 0
        self.fg = 0
        self.bg = 0
        self.bold = False
        self.italic = False


class FakeScreen:
    def __init__(self, columns: int = 120) -> None:
        self.columns = columns
        self.cursor = FakeCursor()
        self.drawn: list[tuple[int, int, str]] = []

    def draw(self, value: str) -> None:
        self.drawn.append((self.cursor.x, self.cursor.fg, value))
        self.cursor.x += len(value)


class FakeTabAccessor:
    values: dict[int, tuple[str, str]] = {}

    def __init__(self, tab_id: int) -> None:
        self.active_wd, self.active_exe = self.values[tab_id]


TabBarData = namedtuple("TabBarData", "tab_id is_active")
ExtraData = namedtuple("ExtraData", "for_layout")


def install_kitty_stubs() -> None:
    kitty = types.ModuleType("kitty")
    boss = types.ModuleType("kitty.boss")
    boss.get_boss = lambda: types.SimpleNamespace(os_window_map={})

    fast_data_types = types.ModuleType("kitty.fast_data_types")
    fast_data_types.Screen = FakeScreen
    fast_data_types.add_timer = lambda *_args: 1
    fast_data_types.wcswidth = len

    rgb = types.ModuleType("kitty.rgb")
    rgb.to_color = lambda value: int(value.removeprefix("#"), 16)

    tab_bar = types.ModuleType("kitty.tab_bar")
    tab_bar.DrawData = object
    tab_bar.ExtraData = ExtraData
    tab_bar.TabAccessor = FakeTabAccessor
    tab_bar.TabBarData = TabBarData
    tab_bar.as_rgb = lambda value: value
    tab_bar.draw_tab_with_separator = lambda *_args: 20

    utils = types.ModuleType("kitty.utils")
    utils.color_as_int = int

    sys.modules.update(
        {
            "kitty": kitty,
            "kitty.boss": boss,
            "kitty.fast_data_types": fast_data_types,
            "kitty.rgb": rgb,
            "kitty.tab_bar": tab_bar,
            "kitty.utils": utils,
        }
    )


install_kitty_stubs()
spec = importlib.util.spec_from_file_location("kitty_status_bar", MODULE_PATH)
assert spec and spec.loader
status_bar = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = status_bar
spec.loader.exec_module(status_bar)


class KittyStatusBarTest(unittest.TestCase):
    def test_parses_present_and_absent_payloads(self) -> None:
        present = status_bar._parse_payload(
            "herdrgit1\t123\tpane\t/repo\t1\trepo\tmain\tdw"
        )
        self.assertEqual(present.repo, "repo")
        self.assertEqual(present.ref, "main")
        self.assertEqual(present.flags, "dw")

        absent = status_bar._parse_payload(
            "herdrgit1\t124\tpane\t/not-repo\t0\t\t\t"
        )
        self.assertFalse(absent.present)
        self.assertEqual(absent.repo, "")

    def test_rejects_invalid_payloads(self) -> None:
        invalid = [
            None,
            "",
            "wrong\t123\tpane\t/repo\t1\trepo\tmain\t",
            "herdrgit1\tbad\tpane\t/repo\t1\trepo\tmain\t",
            "herdrgit1\t123\tpane\t/repo\t1\t\tmain\t",
            "herdrgit1\t123\tpane",
        ]
        for value in invalid:
            with self.subTest(value=value):
                self.assertIsNone(status_bar._parse_payload(value))

    def test_cwd_cache_key_matches_rust_contract(self) -> None:
        self.assertEqual(status_bar._cwd_cache_key("/repo"), "81f9fa62")
        self.assertEqual(status_bar._normalize_path("/repo/"), "/repo")
        self.assertEqual(status_bar._normalize_path("/"), "/")

    def test_reads_matching_cwd_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cache_home = Path(temporary)
            cwd = "/repo"
            cache = cache_home / "wezterm" / "herdr-git-info-by-cwd"
            cache.mkdir(parents=True)
            (cache / status_bar._cwd_cache_key(cwd)).write_text(
                "herdrgit1\t123\tpane\t/repo\t1\trepo\tmain\td\n",
                encoding="utf-8",
            )

            with patch.dict(os.environ, {"XDG_CACHE_HOME": temporary}):
                info = status_bar._read_cwd_info("/repo/")

            self.assertEqual(info.repo, "repo")

    def test_herdr_prefers_newer_focused_cwd_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary) / "wezterm"
            cwd_cache = cache / "herdr-git-info-by-cwd"
            cwd_cache.mkdir(parents=True)
            (cache / "herdr-git-info-focused").write_text(
                "herdrgit1\t100\tpane\t/repo\t1\trepo\tmain\t\n",
                encoding="utf-8",
            )
            (cwd_cache / status_bar._cwd_cache_key("/repo")).write_text(
                "herdrgit1\t120\tpane\t/repo\t1\trepo\tfeature\td\n",
                encoding="utf-8",
            )

            with patch.dict(os.environ, {"XDG_CACHE_HOME": temporary}):
                info = status_bar._read_git_info("/host", "/bin/herdr")

            self.assertEqual(info.ref, "feature")
            self.assertEqual(info.flags, "d")

    def test_draw_title_preserves_existing_dotfiles_behavior(self) -> None:
        tab = types.SimpleNamespace(active_exe="/bin/zsh", active_wd="/repo/project")
        title = status_bar.draw_title(
            {"tab": tab, "title": "fallback", "max_title_length": 24}
        )
        self.assertEqual(title, " project ")

    def test_formats_time_with_english_names(self) -> None:
        value = status_bar._format_time(datetime(2026, 8, 27, 9, 5))
        self.assertEqual(value, "Thu Aug 27 09:05")

    def test_draws_status_at_right_edge(self) -> None:
        FakeTabAccessor.values[1] = ("/repo", "/bin/zsh")
        info = status_bar.GitInfo(123, "pane", "/repo", True, "repo", "main", "d")
        screen = FakeScreen(columns=100)

        with patch.object(status_bar, "_read_git_info", return_value=info):
            status_bar._draw_right_status(screen, TabBarData(1, True), 20)

        rendered = "".join(value for _, _, value in screen.drawn)
        self.assertIn("repo", rendered)
        self.assertIn("main *", rendered)
        self.assertEqual(screen.cursor.x, 100)

    def test_falls_back_to_time_when_space_is_narrow(self) -> None:
        info = status_bar.GitInfo(123, "pane", "/repo", True, "repo", "main", "d")
        time_cells = [(status_bar.TIME, " time ")]
        with patch.object(status_bar, "_time_cells", return_value=time_cells):
            cells = status_bar._fit_cells(info, 7)
        self.assertEqual(cells, time_cells)


if __name__ == "__main__":
    unittest.main()
