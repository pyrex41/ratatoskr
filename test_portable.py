"""Cross-platform unit tests for ratatoskr_cli's portability helpers.

Run identically on Linux/macOS/Windows; they exercise the parameterised
helpers so the Windows code paths are verified on every OS. No Shen host or
build toolchain is required.

Run:  pytest test_portable.py
"""

import ratatoskr_cli as r


def test_wrap_bat_cmd_on_windows():
    assert r.wrap_executable([r"C:\p\shen.cmd", "eval"], is_windows=True)[:2] == ["cmd", "/c"]
    assert r.wrap_executable([r"C:\p\x.bat"], is_windows=True)[:2] == ["cmd", "/c"]


def test_wrap_sh_on_windows():
    assert r.wrap_executable(["builders/lisp/build.sh", "a", "b"], is_windows=True) == \
        ["sh", "builders/lisp/build.sh", "a", "b"]


def test_wrap_exe_and_posix_noop():
    assert r.wrap_executable([r"C:\p\app.exe"], is_windows=True) == [r"C:\p\app.exe"]
    for argv in (["/x/app"], ["x/build.sh"], ["foo.cmd"]):
        assert r.wrap_executable(argv, is_windows=False) == argv


def test_find_executable_windows_extension(tmp_path):
    (tmp_path / "shen.exe").write_text("MZ")
    base = str(tmp_path / "shen")
    assert r.find_executable_path(base, is_windows=True) == base + ".exe"
    assert r.find_executable_path(base, is_windows=False) is None


def test_find_executable_exact(tmp_path):
    f = tmp_path / "host"
    f.write_text("#!/bin/sh\n")
    assert r.find_executable_path(str(f), is_windows=False) == str(f)


def test_find_executable_missing(tmp_path):
    assert r.find_executable_path(str(tmp_path / "nope"), is_windows=True) is None


def test_load_builders_has_targets():
    b = r.load_builders()
    assert {"lisp", "lua", "go", "rust", "js"}.issubset(set(b))
