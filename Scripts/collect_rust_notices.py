#!/usr/bin/env python3
"""Regenerate notices for Cargo's locked macOS dependency graph after an upgrade."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
cargo = os.environ.get("CARGO", str(Path.home() / ".cargo/bin/cargo"))
metadata = json.loads(subprocess.check_output([
    cargo, "metadata", "--locked", "--format-version", "1", "--filter-platform", "aarch64-apple-darwin",
    "--manifest-path", str(root / "Native/Mermaid/Cargo.toml")
]))
used = {node["id"] for node in metadata["resolve"]["nodes"]}
notices = root / "Sources/Hanshi/Resources/ThirdPartyNotices"
texts = {}
entries = []
for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
    if package["id"] not in used or package["name"] == "hanshi-mermaid":
        continue
    directory = Path(package["manifest_path"]).parent
    files = sorted({file for pattern in ("LICENSE*", "LICENCE*", "COPYING*", "NOTICE*", "THIRD_PARTY*", "license*", "licenses/*")
                    for file in directory.glob(pattern) if file.is_file()})
    if not files:
        if package.get("repository") == "https://github.com/Latias94/merman":
            files = [notices / "Merman-LICENSE-MIT", notices / "Merman-ThirdParty.md"]
        elif package["name"] == "selectors":
            files = [notices / "MPL-2.0.txt"]
        else:
            raise RuntimeError(f"Missing license text for {package['name']}")
    references = []
    for file in files:
        text = file.read_text(errors="replace").strip()
        if text not in texts:
            texts[text] = len(texts) + 1
        references.append(str(texts[text]))
    entries.append(f"{package['name']} {package['version']} — {package.get('license')}\n"
                   f"Repository: {package.get('repository') or ''}\n"
                   f"Source: https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download\n"
                   f"License/notice texts: {', '.join(references)}\n")
with (notices / "Rust-Dependencies.txt").open("w") as output:
    output.write("Locked macOS Rust dependencies. Identical license texts are included once.\n\n")
    output.write("\n".join(entries))
    for text, number in texts.items():
        output.write(f"\n{'=' * 72}\nLicense/notice text {number}\n{'=' * 72}\n{text}\n")
