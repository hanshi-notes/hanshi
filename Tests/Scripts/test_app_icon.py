#!/usr/bin/env python3
"""Check the actual packaged macOS icon. Run after Scripts/package_app.sh."""
from pathlib import Path
import json
import plistlib
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / "build/Hanshi.app"
with (app / "Contents/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info.get("CFBundleIconName") == "AppIcon", "The app must declare its asset catalog icon"
icon_name = info.get("CFBundleIconFile")
assert icon_name, "The app must declare a Finder/Dock icon"
icon = app / "Contents/Resources" / icon_name
if icon.suffix != ".icns":
    icon = icon.with_suffix(".icns")
assert icon.is_file(), f"Missing packaged icon: {icon}"
catalog = app / "Contents/Resources/Assets.car"
assert catalog.is_file(), "Missing compiled asset catalog"
assets = json.loads(subprocess.check_output(["/usr/bin/assetutil", "--info", str(catalog)]))
representations = {(asset["PixelWidth"], asset["PixelHeight"], asset["Scale"])
                   for asset in assets if asset.get("Name") == "AppIcon" and asset.get("AssetType") == "Icon Image"}
expected = {(size * scale, size * scale, scale) for size in (16, 32, 128, 256, 512) for scale in (1, 2)}
assert expected <= representations, f"Missing catalog icon resolutions: {expected - representations}"
with tempfile.TemporaryDirectory(prefix="hanshi-icon-") as directory:
    output = Path(directory) / "AppIcon.iconset"
    subprocess.run(["/usr/bin/iconutil", "--convert", "iconset", "--output", str(output), str(icon)], check=True)
    sizes = set()
    for image in output.glob("*.png"):
        data = image.read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {image.name}"
        width, height = struct.unpack(">II", data[16:24])
        assert width == height, f"Non-square icon: {image.name}"
        sizes.add(width)
    assert {16, 32} <= sizes, f"Missing compatibility icon resolutions: {sizes}"
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
print("Packaged AppIcon is declared, decodable at all resolutions, and signed.")
