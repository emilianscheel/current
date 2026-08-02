import sys

from ds_store import DSStore


ARROW_ITEM = "\u2063.tiff"
EXPECTED_LOCATIONS = {
    "Current.app": (160, 170),
    ARROW_ITEM: (330, 170),
    "Applications": (500, 170),
}


def fail(message: str) -> None:
    raise SystemExit(f"Invalid DMG Finder layout: {message}")


if len(sys.argv) != 2:
    raise SystemExit("Usage: verify_layout.py <path-to-.DS_Store>")

with DSStore.open(sys.argv[1], "r") as store:
    icon_view = store["."]["icvp"]
    if icon_view.get("backgroundType") != 0:
        fail("the icon view does not use Finder's native adaptive background")
    if icon_view.get("iconSize") != 112.0:
        fail("the icon size is not 112 points")
    if icon_view.get("textSize") != 14.0:
        fail("the label size is not 14 points")
    if not icon_view.get("showIconPreview"):
        fail("icon previews are disabled")

    for item, expected_location in EXPECTED_LOCATIONS.items():
        if store[item]["Iloc"] != expected_location:
            fail(f"{item!r} is not at {expected_location}")
