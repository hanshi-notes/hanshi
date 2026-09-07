#!/usr/bin/env python3
"""Build scripts must use the same Swift selected by the caller's PATH."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repository = Path(__file__).resolve().parents[2]
for script in ("package_app.sh", "check_preview_package.sh"):
    with tempfile.TemporaryDirectory(prefix="hanshi-toolchain-") as directory:
        root = Path(directory)
        scripts = root / "Scripts"
        scripts.mkdir()
        shutil.copy(repository / "Scripts" / script, scripts / script)
        commands = root / "bin"
        commands.mkdir()
        for path, body in (
            (scripts / "build_mermaid.sh", "exit 0"),
            (commands / "swift", 'echo "PATH_SWIFT:$*" >&2; exit 42'),
            (commands / "xcrun", 'echo "WRONG_XCODE_SWIFT"; exit 86'),
        ):
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        result = subprocess.run(
            ["/bin/bash", str(scripts / script)], text=True, capture_output=True,
            env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]},
        )
        expected = "package resolve" if script == "package_app.sh" else "build -c release --show-bin-path"
        assert result.returncode == 42 and f"PATH_SWIFT:{expected}" in result.stderr, (
            script, result.returncode, result.stdout, result.stderr
        )
print("Both packaging scripts use the caller's Swift toolchain.")
