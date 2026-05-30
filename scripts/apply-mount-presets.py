#!/usr/bin/env python3
# apply-mount-presets.py — merge Unraid plugin library paths into Wolf app runners.
#
# Game apps live on the Wolf "user" profile in config.toml. GET /api/v1/apps only
# lists the Moonlight profile, so config.toml is always patched when present.
# The Wolf API path is optional for Moonlight-profile apps only.
#
# See: https://games-on-whales.github.io/wolf/stable/dev/api.html

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

TITLE_ALIASES: dict[str, str] = {
    "Prism Launcher": "Prismlauncher",
    "Heroic": "Heroic Games Launcher",
    "ES-DE": "EmulationStation",
    "ESDE": "EmulationStation",
    "EmulationStation Desktop Edition": "EmulationStation",
}

# Normalized alias lookup (lowercased, non-alphanumerics stripped).
_NORMALIZED_ALIASES: dict[str, str] = {
    "esde": "EmulationStation",
    "emulationstationdesktopedition": "EmulationStation",
    "emustation": "EmulationStation",
    "retroarchra": "RetroArch",
    "xfce": "Desktop (xfce)",
    "desktop": "Desktop (xfce)",
    "xfcedesktop": "Desktop (xfce)",
    "heroic": "Heroic Games Launcher",
    "heroicgameslauncher": "Heroic Games Launcher",
    "prism": "Prismlauncher",
    "prismlauncher": "Prismlauncher",
}

# title -> list of (config key, container destination)
APP_PRESETS: dict[str, list[tuple[str, str]]] = {
    "RetroArch": [("ROMS", "/ROMs"), ("BIOS", "/bioses"), ("MEDIA", "/media")],
    "Pegasus": [("ROMS", "/ROMs"), ("BIOS", "/bioses"), ("MEDIA", "/media")],
    "EmulationStation": [("ROMS", "/ROMs"), ("BIOS", "/bioses"), ("MEDIA", "/media")],
    "Steam": [
        ("STEAM", "/home/retro/.local/share/Steam"),
        (
            "COMPAT",
            "/home/retro/.steam/debian-installation/compatibilitytools.d",
        ),
    ],
    "Lutris": [
        ("LUTRIS", "/var/lutris"),
        (
            "COMPAT",
            "/home/retro/.steam/debian-installation/compatibilitytools.d",
        ),
    ],
    "Prismlauncher": [("GAMES", "/games"), ("PRISM", "/games/prismlauncher")],
    "Kodi": [("MEDIA", "/media")],
    "Desktop (xfce)": [("GAMES", "/games")],
    "Heroic Games Launcher": [
        ("GAMES", "/games"),
        (
            "COMPAT",
            "/home/retro/.steam/debian-installation/compatibilitytools.d",
        ),
    ],
}

HOME_MOUNT_ALIASES: dict[str, list[tuple[str, str]]] = {
    "RetroArch": [("BIOS", "/home/retro/bioses")],
    "Pegasus": [
        ("BIOS", "/home/retro/bioses"),
        ("ROMS", "/home/retro/ROMs"),
    ],
    "EmulationStation": [
        ("BIOS", "/home/retro/bioses"),
        ("ROMS", "/home/retro/ROMs"),
    ],
}

DEPRECATED_DESTINATIONS = {
    "/home/retro/ROMs",
    "/home/retro/bioses",
    "/home/retro/media",
    "/etc/wolf/roms",
    "/etc/wolf/bioses",
    "/etc/wolf/media",
}

GOW_REQUIRED_BASE = "/dev/input/* /dev/dri/* /dev/nvidia*"

# Optional GOW_REQUIRED_DEVICES path tokens (trimmed when not mounted).
GOW_PATH_TOKENS = ("/ROMs/", "/bioses/", "/media/", "/var/lutris/", "/games/")


def parse_mount_line(line: str) -> tuple[str, str, str] | None:
    line = line.strip().strip(",").strip('"').strip("'")
    if not line:
        return None
    parts = line.split(":")
    if len(parts) < 2:
        return None
    mode = parts[2] if len(parts) >= 3 else "rw"
    return parts[0], parts[1], mode


def parse_mounts_array(text: str) -> list[tuple[str, str, str]]:
    mounts: list[tuple[str, str, str]] = []
    for raw in re.findall(r'"([^"]+)"', text):
        parsed = parse_mount_line(raw)
        if parsed:
            mounts.append(parsed)
    for raw in re.findall(r"'([^']+)'", text):
        parsed = parse_mount_line(raw)
        if parsed:
            mounts.append(parsed)
    return mounts


def parse_string_array(text: str) -> list[str]:
    """Extract TOML string array entries (single- or double-quoted)."""
    entries: list[str] = []
    seen: set[str] = set()
    for raw in re.findall(r'"([^"]+)"', text):
        if raw not in seen:
            seen.add(raw)
            entries.append(raw)
    for raw in re.findall(r"'([^']+)'", text):
        if raw not in seen:
            seen.add(raw)
            entries.append(raw)
    return entries


def format_env_array(entries: list[str]) -> str:
    if not entries:
        return "[]"
    inner = ", ".join(f'"{entry}"' for entry in entries)
    return f"[{inner}]"


def format_mounts_array(mounts: list[tuple[str, str, str]]) -> str:
    if not mounts:
        return "[]"
    inner = ",\n    ".join(f'"{src}:{dst}:{mode}"' for src, dst, mode in mounts)
    return f"[\n    {inner}\n]"


def find_bracket_array(block: str, key: str) -> tuple[int, int] | None:
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*", block, flags=re.MULTILINE)
    if not match:
        return None
    idx = match.end()
    while idx < len(block) and block[idx] in " \t\n\r":
        idx += 1
    if idx >= len(block) or block[idx] != "[":
        return None
    depth = 0
    start = idx
    for pos in range(idx, len(block)):
        char = block[pos]
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return start, pos + 1
    return None


def merge_mounts(
    existing: list[tuple[str, str, str]],
    desired: list[tuple[str, str, str]],
) -> list[tuple[str, str, str]]:
    by_dest = {dst: (src, dst, mode) for src, dst, mode in existing}
    for src, dst, mode in desired:
        by_dest[dst] = (src, dst, mode)
    return list(by_dest.values())


def sanitize_mounts(mounts: list[tuple[str, str, str]]) -> list[tuple[str, str, str]]:
    cleaned: list[tuple[str, str, str]] = []
    for src, dst, mode in mounts:
        if dst in DEPRECATED_DESTINATIONS:
            continue
        if src.startswith("/etc/wolf/"):
            continue
        cleaned.append((src, dst, mode))
    return cleaned


def required_device_paths(mounts: list[tuple[str, str, str]]) -> list[str]:
    paths: list[str] = []
    destinations = {dst for _, dst, _ in mounts}
    if "/ROMs" in destinations or "/home/retro/ROMs" in destinations:
        paths.append("/ROMs/")
    if "/bioses" in destinations or "/home/retro/bioses" in destinations:
        paths.append("/bioses/")
    if "/media" in destinations:
        paths.append("/media/")
    if "/var/lutris" in destinations:
        paths.append("/var/lutris/")
    if "/games" in destinations:
        paths.append("/games/")
    return paths


def normalize_gow_required_value(value: str, allowed_path_tokens: set[str]) -> str:
    """Keep device globs; drop GOW path tokens that are not backed by a mount."""
    parts = value.split()
    kept: list[str] = []
    for part in parts:
        if part in GOW_PATH_TOKENS and part not in allowed_path_tokens:
            continue
        kept.append(part)
    return " ".join(kept)


def _normalize_title(title: str) -> str:
    return re.sub(r"[^a-z0-9]", "", title.lower())


def preset_key(title: str) -> str | None:
    aliased = TITLE_ALIASES.get(title, title)
    if aliased in APP_PRESETS or aliased in HOME_MOUNT_ALIASES:
        return aliased
    normalized = _NORMALIZED_ALIASES.get(_normalize_title(aliased))
    if normalized and (normalized in APP_PRESETS or normalized in HOME_MOUNT_ALIASES):
        return normalized
    lower = aliased.lower()
    for key in APP_PRESETS:
        if key.lower() == lower:
            return key
    for key in HOME_MOUNT_ALIASES:
        if key.lower() == lower:
            return key
    return None


def load_paths(argv: list[str]) -> dict[str, str]:
    keys = ["ROMS", "BIOS", "MEDIA", "STEAM", "GAMES", "LUTRIS", "PRISM", "COMPAT"]
    out: dict[str, str] = {}
    for key, value in zip(keys, argv):
        value = value.strip()
        if value:
            out[key] = value.rstrip("/")
    return out


def desired_for_title(title: str, paths: dict[str, str]) -> list[tuple[str, str, str]]:
    key = preset_key(title)
    if not key:
        return []
    desired: list[tuple[str, str, str]] = []
    preset = APP_PRESETS.get(key, [])
    aliases = HOME_MOUNT_ALIASES.get(key, [])
    for cfg_key, dest in preset + aliases:
        host = paths.get(cfg_key, "")
        if host:
            desired.append((host, dest, "rw"))
    return desired


def mount_strings(mounts: list[tuple[str, str, str]]) -> list[str]:
    return [f"{src}:{dst}:{mode}" for src, dst, mode in mounts]


WOLF_UI_TITLE = "Wolf UI"
WOLF_SOCKET_CONTAINER = "/var/run/wolf/wolf.sock"
# Godot Wayland can GPF in libwayland-cursor on some NVIDIA hosts; gamescope avoids direct WL cursor load.
WOLF_UI_EXTRA_ENV = ("RUN_GAMESCOPE=1",)
WOLF_UI_DEFAULT_ENV = (
    "GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia*",
    "WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock",
    "WOLF_UI_AUTOUPDATE=False",
    "LOGLEVEL=INFO",
)


def is_wolf_api_socket_mount(src: str, dst: str) -> bool:
    return dst.rstrip("/") == WOLF_SOCKET_CONTAINER or dst.endswith("wolf.sock")


def fix_wolf_ui_socket_mounts(
    mounts: list[tuple[str, str, str]],
    host_socket_path: str,
) -> tuple[list[tuple[str, str, str]], bool]:
    """Replace container-relative wolf.sock bind sources with the host socket path."""
    desired = (host_socket_path, WOLF_SOCKET_CONTAINER, "rw")
    kept: list[tuple[str, str, str]] = []
    changed = False
    found = False

    for src, dst, mode in mounts:
        if is_wolf_api_socket_mount(src, dst):
            found = True
            if (src, dst, mode) != desired:
                changed = True
            continue
        kept.append((src, dst, mode))

    if not found:
        kept.append(desired)
        changed = True
    else:
        kept.append(desired)

    return kept, changed


def ensure_env_entries(env: list[str], required: tuple[str, ...]) -> tuple[list[str], bool]:
    existing_keys = {e.split("=", 1)[0] for e in env if "=" in e}
    changed = False
    new_env = list(env)
    for entry in required:
        key = entry.split("=", 1)[0]
        if key not in existing_keys:
            new_env.append(entry)
            changed = True
    return new_env, changed


def patch_wolf_ui_env_block(block: str) -> tuple[str, bool]:
    title_match = re.search(r'^\s*title\s*=\s*["\']([^"\']+)["\']', block, flags=re.MULTILINE)
    if not title_match or title_match.group(1) != WOLF_UI_TITLE:
        return block, False

    span = find_bracket_array(block, "env")
    if not span:
        return block, False

    start, end = span
    env_text = block[start:end]
    entries = parse_string_array(env_text)
    entries, default_changed = ensure_env_entries(entries, WOLF_UI_DEFAULT_ENV)
    entries, extra_changed = ensure_env_entries(entries, WOLF_UI_EXTRA_ENV)
    changed = default_changed or extra_changed
    if not changed:
        return block, False

    new_env = format_env_array(entries)
    return block[:start] + new_env + block[end:], True


def patch_wolf_ui_env_config(text: str) -> tuple[str, int]:
    updated = 0
    pattern = r"(?=^\s*\[\[(?:profiles\.)?apps\]\])"
    parts = re.split(pattern, text, flags=re.MULTILINE)
    out: list[str] = []

    for part in parts:
        if not part.strip():
            continue
        if not re.match(r"^\[\[(?:profiles\.)?apps\]\]", part.lstrip()):
            out.append(part)
            continue
        new_part, changed = patch_wolf_ui_env_block(part)
        if changed:
            updated += 1
        out.append(new_part)

    return "".join(out), updated


def patch_wolf_ui_socket_block(block: str, host_socket_path: str) -> tuple[str, bool]:
    title_match = re.search(r'^\s*title\s*=\s*["\']([^"\']+)["\']', block, flags=re.MULTILINE)
    if not title_match or title_match.group(1) != WOLF_UI_TITLE:
        return block, False

    mounts_span = find_bracket_array(block, "mounts")
    if not mounts_span:
        return block, False

    start, end = mounts_span
    mounts_text = block[start:end]
    existing = sanitize_mounts(parse_mounts_array(mounts_text))
    fixed, changed = fix_wolf_ui_socket_mounts(existing, host_socket_path)
    new_block = block[:start] + format_mounts_array(fixed) + block[end:] if changed else block

    new_block, env_changed = patch_wolf_ui_env_block(new_block)
    return new_block, changed or env_changed


def patch_wolf_ui_socket_config(text: str, host_socket_path: str) -> tuple[str, int]:
    updated = 0
    pattern = r"(?=^\s*\[\[(?:profiles\.)?apps\]\])"
    parts = re.split(pattern, text, flags=re.MULTILINE)
    out: list[str] = []

    for part in parts:
        if not part.strip():
            continue
        if not re.match(r"^\[\[(?:profiles\.)?apps\]\]", part.lstrip()):
            out.append(part)
            continue
        new_part, changed = patch_wolf_ui_socket_block(part, host_socket_path)
        if changed:
            updated += 1
        out.append(new_part)

    return "".join(out), updated


def patch_wolf_ui_socket_api(socket: Path, host_socket_path: str) -> int:
    data = curl_unix_json(socket, "GET", "/api/v1/apps")
    if not data.get("success"):
        raise RuntimeError("GET /api/v1/apps returned success=false")

    for app in data.get("apps") or []:
        if app.get("title") != WOLF_UI_TITLE:
            continue
        runner = app.get("runner")
        if not runner_is_docker(runner):
            return 0

        existing_raw = runner.get("mounts") or []
        existing: list[tuple[str, str, str]] = []
        for raw in existing_raw:
            parsed = parse_mount_line(str(raw))
            if parsed:
                existing.append(parsed)

        fixed, changed = fix_wolf_ui_socket_mounts(sanitize_mounts(existing), host_socket_path)
        new_mounts = mount_strings(fixed)

        app = dict(app)
        app["runner"] = dict(runner)
        app["runner"]["mounts"] = new_mounts
        env = list(app["runner"].get("env") or [])
        env, default_changed = ensure_env_entries(env, WOLF_UI_DEFAULT_ENV)
        env, extra_changed = ensure_env_entries(env, WOLF_UI_EXTRA_ENV)
        if default_changed or extra_changed:
            app["runner"]["env"] = env
            changed = True

        if not changed:
            return 0
        app_id = app.get("id")
        if not app_id:
            return 0
        curl_unix_json(socket, "POST", "/api/v1/apps/delete", {"id": app_id})
        curl_unix_json(socket, "POST", "/api/v1/apps/add", app)
        print("  Updated Wolf UI Wolf API socket mount via Wolf API")
        return 1

    return 0


def patch_gow_required_env(
    env: list[str],
    extra_paths: list[str],
) -> tuple[list[str], bool]:
    allowed_tokens = set(extra_paths)
    changed = False
    found = False
    new_env: list[str] = []

    for entry in env:
        if not entry.startswith("GOW_REQUIRED_DEVICES="):
            new_env.append(entry)
            continue
        found = True
        base = entry.split("=", 1)[1].strip()
        normalized = normalize_gow_required_value(base, allowed_tokens)
        for path in extra_paths:
            if path not in normalized:
                normalized = f"{normalized} {path}".strip()
        merged = f"GOW_REQUIRED_DEVICES={normalized}"
        if merged != entry:
            changed = True
        new_env.append(merged)

    if not found:
        suffix = " " + " ".join(extra_paths) if extra_paths else ""
        new_env.append(f"GOW_REQUIRED_DEVICES={GOW_REQUIRED_BASE}{suffix}")
        changed = True
    elif not changed and extra_paths:
        # Re-check: normalization may have removed stale tokens
        for entry in new_env:
            if entry.startswith("GOW_REQUIRED_DEVICES="):
                old = next(
                    (e for e in env if e.startswith("GOW_REQUIRED_DEVICES=")),
                    "",
                )
                if entry != old:
                    changed = True
                break

    return new_env, changed


def patch_gow_required_devices(block: str, extra_paths: list[str]) -> tuple[str, bool]:
    if not extra_paths:
        return block, False

    span = find_bracket_array(block, "env")
    if not span:
        return block, False

    start, end = span
    env_text = block[start:end]
    entries = parse_string_array(env_text)
    if not entries:
        return block, False

    new_entries, changed = patch_gow_required_env(entries, extra_paths)
    if not changed:
        return block, False

    new_env = format_env_array(new_entries)
    return block[:start] + new_env + block[end:], True


def patch_toml_block(block: str, paths: dict[str, str]) -> tuple[str, bool]:
    title_match = re.search(r'^\s*title\s*=\s*["\']([^"\']+)["\']', block, flags=re.MULTILINE)
    if not title_match:
        return block, False

    title = title_match.group(1)
    desired = desired_for_title(title, paths)
    if not desired:
        return block, False

    mounts_span = find_bracket_array(block, "mounts")
    if not mounts_span:
        return block, False

    start, end = mounts_span
    mounts_text = block[start:end]
    existing = sanitize_mounts(parse_mounts_array(mounts_text))
    merged = merge_mounts(existing, desired)
    new_mounts = format_mounts_array(merged)
    new_block = block[:start] + new_mounts + block[end:]

    extra_paths = required_device_paths(merged)
    new_block, env_changed = patch_gow_required_devices(new_block, extra_paths)

    changed = new_mounts.replace(" ", "") != mounts_text.replace(" ", "") or env_changed
    return new_block, changed


def patch_config_toml(text: str, paths: dict[str, str]) -> tuple[str, int]:
    updated = 0
    pattern = r"(?=^\s*\[\[(?:profiles\.)?apps\]\])"
    parts = re.split(pattern, text, flags=re.MULTILINE)
    out: list[str] = []

    for part in parts:
        if not part.strip():
            continue
        if not re.match(r"^\[\[(?:profiles\.)?apps\]\]", part.lstrip()):
            out.append(part)
            continue
        new_part, changed = patch_toml_block(part, paths)
        if changed:
            updated += 1
        out.append(new_part)

    return "".join(out), updated


def curl_unix_json(socket: Path, method: str, path: str, body: dict | None = None) -> dict:
    url = f"http://localhost{path}"
    cmd = ["curl", "-sfS", "--unix-socket", str(socket), "-X", method, url]
    if body is not None:
        cmd.extend(["-H", "Content-Type: application/json", "-d", json.dumps(body)])
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"curl failed ({method} {path})")
    return json.loads(proc.stdout)


def runner_is_docker(runner: object) -> bool:
    return isinstance(runner, dict) and runner.get("type") in ("docker", "Docker")


def patch_runner_mounts(runner: dict, desired: list[tuple[str, str, str]]) -> tuple[dict, bool]:
    existing_raw = runner.get("mounts") or []
    existing: list[tuple[str, str, str]] = []
    for raw in existing_raw:
        parsed = parse_mount_line(str(raw))
        if parsed:
            existing.append(parsed)
    merged = merge_mounts(sanitize_mounts(existing), desired)
    new_mounts = mount_strings(merged)
    changed = new_mounts != list(existing_raw)
    runner = dict(runner)
    runner["mounts"] = new_mounts
    env = list(runner.get("env") or [])
    new_env, env_changed = patch_gow_required_env(env, required_device_paths(merged))
    if env_changed or new_env != env:
        runner["env"] = new_env
        changed = True
    return runner, changed


def patch_config_api(socket: Path, paths: dict[str, str]) -> int:
    """Update Moonlight-profile apps only (Wolf API limitation)."""
    data = curl_unix_json(socket, "GET", "/api/v1/apps")
    if not data.get("success"):
        raise RuntimeError("GET /api/v1/apps returned success=false")
    apps: list[dict] = data.get("apps") or []
    updated = 0

    for app in apps:
        title = app.get("title", "")
        desired = desired_for_title(title, paths)
        if not desired:
            continue
        runner = app.get("runner")
        if not runner_is_docker(runner):
            continue
        new_runner, changed = patch_runner_mounts(dict(runner), desired)
        if not changed:
            continue
        app_id = app.get("id")
        if not app_id:
            continue
        app = dict(app)
        app["runner"] = new_runner
        curl_unix_json(socket, "POST", "/api/v1/apps/delete", {"id": app_id})
        curl_unix_json(socket, "POST", "/api/v1/apps/add", app)
        updated += 1
        print(f"  Updated Moonlight app {title!r} via Wolf API")

    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply Unraid library mount presets to Wolf apps")
    parser.add_argument(
        "config",
        nargs="?",
        help="Path to config.toml (required for user-profile apps)",
    )
    parser.add_argument(
        "--socket",
        help="Wolf API Unix socket (Moonlight-profile apps only)",
    )
    parser.add_argument(
        "--wolf-socket-host",
        help="Host path to wolf.sock for Wolf UI session containers (Unraid appdata)",
    )
    parser.add_argument(
        "libraries",
        nargs="*",
        help="ROMS BIOS MEDIA STEAM GAMES LUTRIS PRISM COMPAT paths",
    )
    args = parser.parse_args()

    lib_argv = args.libraries
    paths = load_paths(lib_argv)

    exit_code = 0
    toml_count = 0
    api_count = 0
    socket_count = 0

    cfg_path: Path | None = None
    if args.config and not args.config.startswith("-"):
        cfg_path = Path(args.config)

    working_text: str | None = None
    if cfg_path and cfg_path.is_file():
        working_text = cfg_path.read_text(encoding="utf-8")
    elif cfg_path:
        print(f"Config not found: {cfg_path}", file=sys.stderr)
        exit_code = 1

    if args.wolf_socket_host and working_text is not None:
        patched, socket_count = patch_wolf_ui_socket_config(working_text, args.wolf_socket_host)
        if socket_count:
            cfg_path.write_text(patched, encoding="utf-8")  # type: ignore[union-attr]
            print(
                f"Fixed Wolf UI Wolf API socket mount in {socket_count} app runner(s) in {cfg_path}"
            )
            working_text = patched

    if not paths:
        if args.socket and args.wolf_socket_host:
            sock = Path(args.socket)
            if sock.is_socket():
                try:
                    api_count = patch_wolf_ui_socket_api(sock, args.wolf_socket_host)
                except (RuntimeError, json.JSONDecodeError, OSError) as exc:
                    print(f"Wolf UI socket mount API warning: {exc}", file=sys.stderr)
        if not paths and not args.wolf_socket_host:
            print("No library paths configured; skipping mount presets")
        elif not paths:
            print("No library paths configured; skipping library mount presets")
        if not cfg_path and not args.socket:
            parser.print_usage(file=sys.stderr)
            return 2 if not args.wolf_socket_host else exit_code
        return exit_code

    if working_text is not None:
        patched, toml_count = patch_config_toml(working_text, paths)
        if toml_count:
            cfg_path.write_text(patched, encoding="utf-8")  # type: ignore[union-attr]
            print(f"Applied mount presets to {toml_count} app runner(s) in {cfg_path}")
        elif not socket_count:
            print(f"No app runners needed mount preset updates in {cfg_path}")
        working_text = patched

    if args.socket:
        sock = Path(args.socket)
        if not sock.is_socket():
            print(f"Wolf API socket not ready: {sock}", file=sys.stderr)
            if not cfg_path or not cfg_path.is_file():
                return 1
        else:
            try:
                if args.wolf_socket_host:
                    api_count += patch_wolf_ui_socket_api(sock, args.wolf_socket_host)
                api_count += patch_config_api(sock, paths)
            except (RuntimeError, json.JSONDecodeError, OSError) as exc:
                print(f"Wolf API mount preset warning: {exc}", file=sys.stderr)
            else:
                if api_count:
                    print(f"Applied mount presets to {api_count} Moonlight app(s) via Wolf API")
                elif not toml_count and not socket_count:
                    print("No apps needed mount preset updates")

    if not cfg_path and not args.socket:
        parser.print_usage(file=sys.stderr)
        return 2

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
