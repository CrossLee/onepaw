#!/usr/bin/env python3
"""Write and verify OnePaw's Finder layout without GUI automation."""

from __future__ import annotations

import argparse
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


APP_NAME = "一爪.app"
APPLICATIONS_NAME = "Applications"
BACKGROUND_RELATIVE_PATH = Path(".background") / "DMGBackground.png"
WINDOW_BOUNDS = "{{120, 100}, {793, 496}}"
APP_POSITION = (215, 275)
APPLICATIONS_POSITION = (578, 275)
ICON_SIZE = 112.0
TEXT_SIZE = 14.0


def expected_window_settings() -> dict[str, object]:
    return {
        "ShowStatusBar": False,
        "WindowBounds": WINDOW_BOUNDS,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }


def expected_icon_settings(background_alias: bytes) -> dict[str, object]:
    return {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "backgroundImageAlias": background_alias,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": TEXT_SIZE,
        "iconSize": ICON_SIZE,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }


def validate_volume(volume: Path) -> tuple[Path, Path]:
    if not volume.is_dir():
        raise ValueError(f"DMG mount does not exist: {volume}")

    background = volume / BACKGROUND_RELATIVE_PATH
    if not background.is_file():
        raise ValueError(f"DMG background does not exist: {background}")
    if not (volume / APP_NAME).is_dir():
        raise ValueError(f"DMG app does not exist: {volume / APP_NAME}")
    if not (volume / APPLICATIONS_NAME).is_symlink():
        raise ValueError("DMG Applications link does not exist")

    return background, volume / ".DS_Store"


def write_layout(volume: Path) -> None:
    background, ds_store_path = validate_volume(volume)
    ds_store_path.unlink(missing_ok=True)

    alias = Alias.for_file(str(background))
    # Keep build-machine usernames and staging paths out of the published DMG.
    # Finder resolves the target by volume identity and the volume-relative path.
    alias.volume.posix_path = "/Volumes/一爪"
    background_alias = alias.to_bytes()
    with DSStore.open(str(ds_store_path), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = expected_window_settings()
        store["."]["icvp"] = expected_icon_settings(background_alias)
        store["."]["icvl"] = (b"type", b"icnv")
        store[APP_NAME]["Iloc"] = APP_POSITION
        store[APPLICATIONS_NAME]["Iloc"] = APPLICATIONS_POSITION


def verify_layout(volume: Path) -> None:
    _, ds_store_path = validate_volume(volume)
    if not ds_store_path.is_file() or ds_store_path.stat().st_size == 0:
        raise ValueError("DMG Finder layout is missing")

    with DSStore.open(str(ds_store_path), "r") as store:
        window_settings = store["."]["bwsp"]
        icon_settings = store["."]["icvp"]
        default_view = store["."]["icvl"]
        app_position = store[APP_NAME]["Iloc"]
        applications_position = store[APPLICATIONS_NAME]["Iloc"]

    if window_settings != expected_window_settings():
        raise ValueError(f"unexpected Finder window settings: {window_settings!r}")
    if default_view != (b"type", b"icnv"):
        raise ValueError(f"unexpected Finder default view: {default_view!r}")
    if app_position != APP_POSITION:
        raise ValueError(f"unexpected {APP_NAME} position: {app_position!r}")
    if applications_position != APPLICATIONS_POSITION:
        raise ValueError(
            f"unexpected {APPLICATIONS_NAME} position: {applications_position!r}"
        )

    background_alias = icon_settings.get("backgroundImageAlias")
    if not isinstance(background_alias, bytes) or not background_alias:
        raise ValueError("Finder background alias is missing")

    decoded_alias = Alias.from_bytes(background_alias)
    if decoded_alias.volume.name != "一爪":
        raise ValueError(
            f"Finder background alias has an unexpected volume: {decoded_alias.volume.name!r}"
        )
    if decoded_alias.volume.posix_path != "/Volumes/一爪":
        raise ValueError(
            "Finder background alias has a noncanonical mount path: "
            f"{decoded_alias.volume.posix_path!r}"
        )
    if decoded_alias.target.filename != "DMGBackground.png":
        raise ValueError(
            "Finder background alias has an unexpected target: "
            f"{decoded_alias.target.filename!r}"
        )
    if decoded_alias.target.posix_path != "/.background/DMGBackground.png":
        raise ValueError(
            "Finder background alias has an unexpected path: "
            f"{decoded_alias.target.posix_path!r}"
        )

    expected_icon_values = expected_icon_settings(background_alias)
    if icon_settings != expected_icon_values:
        raise ValueError(f"unexpected Finder icon settings: {icon_settings!r}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("write", "verify"))
    parser.add_argument("mount_path", type=Path)
    args = parser.parse_args()

    if args.action == "write":
        write_layout(args.mount_path)
    else:
        verify_layout(args.mount_path)


if __name__ == "__main__":
    main()
