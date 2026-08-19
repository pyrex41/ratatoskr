"""Thin launcher: exec the bundled native Go yggdrasil binary with our argv.

The binary is compiled into _bin/ at wheel-build time (see hatch_build.py).
"""

import os
import sys


def _binary():
    here = os.path.dirname(os.path.abspath(__file__))
    exe = "yggdrasil.exe" if sys.platform == "win32" else "yggdrasil"
    return os.path.join(here, "_bin", exe)


def main():
    path = _binary()
    if not os.path.exists(path):
        sys.stderr.write(
            "yggdrasil: bundled binary missing (%s). Reinstall, or use "
            "`go install github.com/pyrex41/yggdrasil@latest`.\n" % path
        )
        return 1
    argv = [path] + sys.argv[1:]
    if sys.platform == "win32":
        import subprocess
        return subprocess.call(argv)
    os.execv(path, argv)


if __name__ == "__main__":
    sys.exit(main())
