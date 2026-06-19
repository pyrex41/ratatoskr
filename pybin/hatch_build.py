"""Hatchling build hook: compile the Go ratatoskr binary into the wheel.

Runs `go build` at wheel-build time (the binary matches the target machine when
uvx/pip builds from sdist or git) and force-includes it. Requires the Go
toolchain on the build machine; no-Go paths are `go install` and the release
binaries.
"""

import os
import subprocess
import sys

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class GoBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version, build_data):
        root = self.root
        exe = "ratatoskr.exe" if sys.platform == "win32" else "ratatoskr"
        out_dir = os.path.join(root, "pybin", "ratatoskr_launch", "_bin")
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, exe)
        subprocess.run(
            ["go", "build", "-trimpath", "-o", out, "."],
            cwd=root, check=True,
        )
        build_data["pure_python"] = False
        build_data["infer_tag"] = True
        build_data.setdefault("force_include", {})[out] = os.path.join("ratatoskr_launch", "_bin", exe)
