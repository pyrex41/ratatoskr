#!/usr/bin/env python3
"""ratatoskr -- a friendly CLI around the Ratatoskr Shen tree-shaker.

Ratatoskr itself is a Shen program (`ratatoskr.shen`) that runs on a host Shen
port and shakes a Shen program into a minimal, portable KLambda slice; per-target
builders then compile that slice into a standalone artifact. This thin wrapper
makes both stages a one-liner and is packaged so it runs with zero install:

    uvx --from git+https://.../ratatoskr ratatoskr shake prog.shen out/
    uvx --from git+https://.../ratatoskr ratatoskr build prog.shen out/ --target go

Subcommands:
    shake  PROG OUTDIR             stage 1: emit kernel.kl + <prog>.kl + manifest
    build  PROG OUTDIR --target T  stage 1 + stage 2 builder for target T
    run    PROG OUTDIR --target T  build, then execute the artifact (prints stdout)
    targets                        list available stage-2 targets

The shake host defaults to shen-cl (the reference + fastest host); shake output
is byte-identical across hosts, so this is almost always what you want. Override
with --host (a launcher, e.g. "node /path/shen.js") and --eval-style.

Pure standard library, Python 3 only.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RATROOT = HERE  # ratatoskr.shen, KLambda/, builders/, builders.json live here
BUILDERS_PATH = os.path.join(RATROOT, "builders.json")


# --------------------------------------------------------------------------
# Host (stage-1) resolution
# --------------------------------------------------------------------------

def default_host():
    """Resolve the stage-1 host launcher argv. shen-cl is the reference host.

    Returns None if nothing resolves (the launcher is machine-specific and not
    something the package can ship), so callers can emit a clean message.
    """
    for env in ("RATATOSKR_HOST", "BIFROST_SHEN_CL"):
        v = os.environ.get(env)
        if v and os.path.isfile(v.split()[0]):
            return v.split()
    cand = os.path.abspath(os.path.join(RATROOT, "..", "shen-cl", "bin", "sbcl", "shen"))
    return [cand] if os.path.isfile(cand) else None


def shake(prog, outdir, host=None, eval_style="sub", quiet=False):
    """Run stage 1: shake `prog` into `outdir`. Returns the outdir path.

    cwd is the Ratatoskr root so ratatoskr.shen's relative KLambda/ loads
    resolve; `prog` and `outdir` are passed as absolute paths.
    """
    host = host or default_host()
    if not host:
        raise SystemExit(
            "ratatoskr: no Shen host launcher found. Set $RATATOSKR_HOST (or "
            "$BIFROST_SHEN_CL) to a Shen launcher, e.g.\n"
            "  RATATOSKR_HOST=/path/to/shen-cl/bin/sbcl/shen ratatoskr shake ...")
    prog = os.path.abspath(prog)
    outdir = os.path.abspath(outdir)
    if not os.path.isfile(prog):
        raise SystemExit("ratatoskr: program not found: %s" % prog)
    os.makedirs(outdir, exist_ok=True)
    expr = '(ratatoskr.shake ["%s"] "%s")' % (prog, outdir)

    if eval_style == "positional":
        # Hosts without an `eval -e` channel (shen-lua): drive via a temp .shen
        # driver loaded positionally. NB: no -q (it would silence file writes).
        drv = os.path.join(outdir, "_shake_driver.shen")
        with open(drv, "w") as f:
            f.write('(load "ratatoskr.shen")\n%s\n' % expr)
        argv = host + [drv]
    else:
        argv = host + ["eval", "-q", "-l", "ratatoskr.shen", "-e", expr]

    out = None if quiet else None
    proc = subprocess.run(argv, cwd=RATROOT,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = proc.stdout.decode("utf-8", "replace") if proc.stdout else ""
    kernel = os.path.join(outdir, "kernel.kl")
    if not (os.path.isfile(kernel) and os.path.getsize(kernel) > 0):
        sys.stderr.write(text)
        raise SystemExit("ratatoskr: shake produced no kernel.kl (host=%s)\n"
                         "  did the program load cleanly on the host?" % " ".join(host))
    if not quiet:
        sys.stderr.write(text)
    return outdir


# --------------------------------------------------------------------------
# Stage-2 builders
# --------------------------------------------------------------------------

def load_builders():
    with open(BUILDERS_PATH) as f:
        return {k: v for k, v in json.load(f).items() if not k.startswith("_")}


def _sibling_dir(target, cfg):
    """Resolve a target's sibling port-repo root ({shen_lua} etc.)."""
    env = cfg.get("dir_env")
    if env and os.environ.get(env):
        return os.path.abspath(os.environ[env])
    name = {"lua": "shen-lua", "go": "shen-go", "rust": "shen-rust",
            "js": "ShenScript", "julia": "shen-julia"}.get(target)
    return os.path.abspath(os.path.join(RATROOT, "..", name)) if name else RATROOT


def _subst(s, subs):
    for k, v in subs.items():
        s = s.replace(k, v)
    return s


def build(target, outdir, tmp=None, quiet=True):
    """Run a target's stage-2 build steps. Returns the run argv for the artifact.

    Assumes `outdir` already holds a shake result. Returns None if a required
    tool is missing (caller decides whether that is a SKIP or an error).
    """
    builders = load_builders()
    if target not in builders:
        raise SystemExit("ratatoskr: unknown target %r (have: %s)"
                         % (target, ", ".join(sorted(builders))))
    cfg = builders[target]
    for tool in cfg.get("needs", []):
        if shutil.which(tool) is None:
            return None  # tool missing -> caller treats as SKIP
    outdir = os.path.abspath(outdir)
    tmp = tmp or tempfile.mkdtemp(prefix="ratatoskr_build_")
    subs = {
        "{ratroot}": RATROOT,
        "{outdir}": outdir,
        "{tmp}": tmp,
        "{shen_lua}": _sibling_dir("lua", cfg),
        "{shen_go}": _sibling_dir("go", cfg),
        "{shen_rust}": _sibling_dir("rust", cfg),
        "{shenscript}": _sibling_dir("js", cfg),
        "{shen_julia}": _sibling_dir("julia", cfg),
    }
    for step in cfg["build"]:
        argv = [_subst(a, subs) for a in step["argv"]]
        cwd = _subst(step["cwd"], subs) if step.get("cwd") else None
        env = dict(os.environ)
        for k, v in step.get("env", {}).items():
            env[k] = _subst(v, subs)
        out = subprocess.DEVNULL if quiet else None
        proc = subprocess.run(argv, cwd=cwd, env=env, stdout=out,
                              stderr=subprocess.STDOUT if not quiet else out)
        if proc.returncode != 0:
            raise SystemExit("ratatoskr: build step failed for target %s: %s"
                             % (target, " ".join(argv)))
    return [_subst(a, subs) for a in cfg["run"]]


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="ratatoskr",
                                 description="Tree-shake a Shen program to a portable artifact")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_host_opts(p):
        p.add_argument("--host", help='stage-1 host launcher (e.g. "node /p/shen.js"); '
                                       "default: shen-cl")
        p.add_argument("--eval-style", choices=["sub", "positional"], default="sub",
                       help="how the host evaluates the shake expr "
                            "(sub = `eval -e`; positional = load a driver, for shen-lua)")

    ps = sub.add_parser("shake", help="stage 1: emit the portable KLambda slice")
    ps.add_argument("prog"); ps.add_argument("outdir"); add_host_opts(ps)

    pb = sub.add_parser("build", help="stage 1 + stage 2 builder for a target")
    pb.add_argument("prog"); pb.add_argument("outdir")
    pb.add_argument("--target", required=True); add_host_opts(pb)

    pr = sub.add_parser("run", help="build, then run the artifact (prints its stdout)")
    pr.add_argument("prog"); pr.add_argument("outdir")
    pr.add_argument("--target", required=True); add_host_opts(pr)

    sub.add_parser("targets", help="list available stage-2 targets")

    args = ap.parse_args(argv)
    host = args.host.split() if getattr(args, "host", None) else None

    if args.cmd == "targets":
        b = load_builders()
        for t in sorted(b):
            print("%-6s runs on %-10s needs %s"
                  % (t, b[t].get("run_impl", "?"), ", ".join(b[t].get("needs", []))))
        return 0

    if args.cmd == "shake":
        out = shake(args.prog, args.outdir, host, args.eval_style)
        print("shaken -> %s" % out)
        for f in sorted(os.listdir(out)):
            print("  %s" % f)
        return 0

    # build / run
    shake(args.prog, args.outdir, host, args.eval_style, quiet=True)
    run_argv = build(args.target, args.outdir)
    if run_argv is None:
        print("ratatoskr: target %r skipped (a required tool is not on PATH)"
              % args.target, file=sys.stderr)
        return 3
    if args.cmd == "build":
        print("built %s artifact; run with:\n  %s" % (args.target, " ".join(run_argv)))
        return 0
    # run
    proc = subprocess.run(run_argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    sys.stdout.write(proc.stdout.decode("utf-8", "replace"))
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
