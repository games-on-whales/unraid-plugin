#!/usr/bin/env python3
"""Patch persisted RetroArch configs for GOW / Wolf streaming."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Legacy + modern bind keys RetroArch writes when no controller autoconfig applied.
_PLAYER1_BIND_PREFIXES = (
    "input_player1_a",
    "input_player1_b",
    "input_player1_x",
    "input_player1_y",
    "input_player1_up",
    "input_player1_down",
    "input_player1_left",
    "input_player1_right",
    "input_player1_start",
    "input_player1_select",
    "input_player1_l",
    "input_player1_r",
    "input_player1_l2",
    "input_player1_r2",
    "input_player1_l3",
    "input_player1_r3",
)

_PLAYER1_BIND_SUFFIXES = ("_btn", "_axis", "_mbtn")

# Values that indicate keyboard/mouse binds blocking joypad autoconfig.
_JOYPAD_VALUE = re.compile(r'^"([0-9]+|h[0-9]+up|h[0-9]+down|h[0-9]+left|h[0-9]+right|[+-][0-9]+|nul)"$')


def _bind_value(line: str) -> str:
    return line.split("=", 1)[1].strip()


def _should_reset_player1_bind(line: str) -> bool:
    stripped = line.strip()
    if not stripped.startswith("input_player1_") or "=" not in stripped:
        return False
    key = stripped.split("=", 1)[0].strip()
    if key in (
        "input_player1_joypad_index",
        "input_player1_mouse_index",
        "input_player1_device_reservation_type",
        "input_player1_reserved_device",
        "input_player1_analog_dpad_mode",
    ):
        return False
    if key.startswith("input_player1_gun_"):
        return not _JOYPAD_VALUE.match(_bind_value(stripped))
    if key in _PLAYER1_BIND_PREFIXES or key.endswith(_PLAYER1_BIND_SUFFIXES):
        return not _JOYPAD_VALUE.match(_bind_value(stripped))
    return False


def reset_port1_binds(cfg_path: Path) -> tuple[int, str]:
    if not cfg_path.is_file():
        return 0, ""
    lines = cfg_path.read_text(encoding="utf-8").splitlines()
    changed = 0
    out: list[str] = []
    for line in lines:
        if _should_reset_player1_bind(line):
            key = line.split("=", 1)[0].strip()
            out.append(f'{key} = "nul"')
            changed += 1
        else:
            out.append(line)
    extras: list[str] = []
    text = "\n".join(out)
    for key, value in (
        ("input_autodetect_enable", '"true"'),
        ("input_joypad_driver", '"udev"'),
        ("input_auto_game_focus", '"true"'),
        ("input_player1_analog_dpad_mode", '"0"'),
    ):
        if not re.search(rf"^{re.escape(key)}", text, flags=re.MULTILINE):
            extras.append(f"{key} = {value}")
            changed += 1
    if extras:
        out.extend(extras)
    if changed:
        return changed, "\n".join(out) + "\n"
    return changed, ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("cfg", type=Path)
    parser.add_argument("--reset-port1", action="store_true")
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Write patched cfg to stdout (for host-side save when using Docker python)",
    )
    args = parser.parse_args()
    if args.reset_port1:
        n, body = reset_port1_binds(args.cfg)
        if args.stdout:
            if body:
                sys.stdout.write(body)
            print(f"reset {n} retroarch.cfg entries for port 1 autoconfig", file=sys.stderr)
            return 0
        if body:
            dest = args.output or args.cfg
            dest.write_text(body, encoding="utf-8")
        print(f"reset {n} retroarch.cfg entries for port 1 autoconfig")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
