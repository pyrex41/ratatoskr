# Ratatoskr

A tree-shaker for [Shen](https://shenlanguage.org) programs, targeting
ShenOSKernel **41.2**. Descended from Mark Tarver's **Yggdrasil 1.0**
(3-clause BSD) — in the myth, Ratatoskr is the squirrel that runs the
trunk of Yggdrasil, carrying messages between crown and roots; here it
walks the kernel call graph and carries a minimal slice of the tree to
each target runtime.

Dr. Tarver's original vision and description, *Using Yggdrasil to Generate
Stand-alone Programs from Shen* (Shen Group, 2023), is preserved here as
[`yggdrasil.pdf`](yggdrasil.pdf). The Yggdrasil 1.0 distribution this
repository started from is archived in [`archive/`](archive/) along with the
[Wayback Machine capture](https://web.archive.org/web/20240430183437/https://www.shenlanguage.org/Download/Yggdrasil.zip)
it was retrieved from.

Ratatoskr turns a Shen program into a minimal, standalone artifact in a
target language: it computes which of the kernel's 1129 functions the
program can actually reach, emits just that slice as KLambda, and hands the
result to a per-target builder that compiles it with the target port's own
KL compiler.

> **The shaker runs on any of the five ports.** Stage 1 is pure Shen, but
> it compiles your program to KLambda with the host's `bootstrap`
> compiler, so the host must emit fully portable KL. All five ports —
> shen-cl, shen-lua, shen-go, shen-rust and ShenScript — are now verified
> to produce a byte-identical `kernel.kl` + manifest and portable user KL
> (see the Gotchas section for the per-host launcher invocation and the
> `*hush*` caveat). shen-cl remains the reference and the fastest host.

**See it run:** [`DEMO.md`](DEMO.md) is an executable demo (built with
[showboat]) that shakes one program and produces a running artifact on all
five targets; `showboat verify DEMO.md` re-executes every step.

## Architecture

**Stage 1 — shake** (this repo; run on any of the five ports — see the
host-portability gotcha for per-host launcher syntax):

```
shen eval -q -l ratatoskr.shen -e '(ratatoskr.shake ["prog.shen"] "out")'
```

writes to `out/`:

| file | contents |
|---|---|
| `kernel.kl` | shaken kernel defuns, load order preserved |
| `<prog>.kl` | the user program compiled to KLambda |
| `ratatoskr.manifest.txt` | line-oriented contract (`key=value`) |
| `ratatoskr.manifest` | same, as s-expressions |

**Stage 2 — build** (one builder per target port, living in that port's
repo):

| target | builder | output (eval-stripped fib) |
|---|---|---|
| Common Lisp | `builders/lisp/build.sh <dir> <exe>` (this repo; `LISP_IMPL=sbcl\|clisp\|ecl`) | saved image (SBCL ~36 MB, CLISP ~7.8 MB) or compiled binary (ECL ~620 KB + libecl) |
| LuaJIT | `shen-lua/bin/ratatoskr-build.lua <dir> <out.lua>` | self-contained .lua (~640 KB, ~25 ms startup) |
| Go | `shen-go/cmd/ratatoskr-build <dir> <outdir>` then `go build` | static binary (~4.5 MB, ≤10 ms startup, cross-compiles linux/windows) |
| Rust | `shen-rust/crates/ratatoskr-build <dir> <outdir>` then `cargo build --release` | static binary (~9 MB, ~40 ms startup) |
| JavaScript | `node ShenScript/bin/ratatoskr-build.js <dir> <out.js>` (`--linked` for needs-eval) | self-contained ES module (~120 KB, runs on Node 20+ / Bun / Deno 2) |

**Builder contract**: load `kernel.kl`'s defuns, call `(shen.initialise)`
(41.2 consolidates all global initialisation there), then run each user
file's forms in manifest order — user files contain defuns *and* toplevel
expressions that must execute in source order.

## How the shake works

The kernel call graph (1129 defuns, 5619 edges) is built once by walking
every defun body for call-position symbols and cached as plain text
(`KLambda/callgraph-41.2.shen`). Per shake, a pure worklist reachability
pass runs from the seed set `{shen.initialise} ∪ symbols(user KL)`. See
`docs/reachability.md` for why this replaced Yggdrasil 1.0's O(N³)
Warshall transitive closure, and why fancier algorithms lose on this graph.

Several kernel "tables masquerading as code" (the arity table, the package
external-symbols registry, `*special*`, type-signature keys, lambda-form
eta-entries) are treated as data, not calls; lambda-form entries are
additionally filtered to the footprint at write time.

**Eval-stripping**: when the user KL never mentions an eval-capable entry
point (`eval`, `eval-kl`, `load`, `tc`, `read`, `input+`, …), the shake
additionally drops the `*macros*` registration and replaces
`shen.f-error`'s interactive track-prompt with a plain `simple-error`,
letting the macro expander, typechecker, reader and `eval` fall away.
Stripped programs shake to ~100 kernel defuns (~66 KB of KL) and the
manifest reports `needs-eval=false`; eval-capable programs keep the full
machinery (~561 defuns). Detection over-approximates safely — a stray
symbol named `eval` keeps the machinery.

The eval-capable path is exercised end-to-end by `tests/metaeval.shen`
(builds expressions as data — a list, a runtime `define`, a string — and
evaluates them) on all five targets. Each port embeds or links its own
KL compiler for runtime `eval-kl`: the Lisp builder stages shen-cl's
precompiled `compiled/compiler.lsp` when the manifest says
`needs-eval=true`, and ShenScript requires `--linked` (self-contained
mode refuses eval-capable manifests).

## Gotchas (hard-won)

- Shen's `read-file` is **not a data reader**: it applies the currying
  transform to paren applications and turns `[a b c]` into cons ASTs.
  `.kl` files survive because the symbol walk doesn't care about tree
  shape; anything else (like the call-graph cache) must be written and
  parsed as plain text.
- 41.2's stlib is lazily materialised: `mapc`, `filter`,
  `remove-duplicates`, `copy-file` don't exist in port runtimes.
  `ratatoskr.shen` carries its own `rat.*` versions.
- Compiled KL carries explicit property-table arguments — e.g. the
  external-symbols registration is a 5-element `put` node, not 4.
- **Stage 1 runs on all five ports** (verified 2026-06-12 for `fib` and
  `prolog`: byte-identical `kernel.kl` + manifest against the shen-cl
  reference, user KL identical modulo gensym numbering). Getting there
  took one fix per non-shen-cl host, since the user program's KL comes
  from the host's `bootstrap` (shen→KL) compiler and each had a way of
  emitting non-portable KL:
  - **shen-cl** — reference host, fastest (~0.06 s): `shen eval -q -l ratatoskr.shen -e '(ratatoskr.shake ["prog.shen"] "out")'`
  - **shen-lua** — `bin/shen ratatoskr.shen -e '(ratatoskr.shake ...)'`. Its native engine compiled `prolog?` to port-local `shen.lua-run-query*` hooks; that expansion is now gated to skip the dynamic extent of `bootstrap`, so compiled `.kl` carries the kernel's portable CPS expansion.
  - **shen-go** — `shen eval -q -l ratatoskr.shen -e '(ratatoskr.shake ...)'`. Gained the standard launcher CLI (`extension-launcher.kl`); the stock binary previously had no `-l`/`-e` and fell straight into the REPL.
  - **shen-rust** — `shen-rust eval -l ratatoskr.shen -e '(ratatoskr.shake ...)'`. Gained the same launcher CLI (on a 1 GB-stack thread for the deep call-graph walk); also fixed `open/2` to honour the `in`/`out` direction symbol so the KL writers truncate-for-write.
  - **ShenScript** — `node bin/shen.js eval -l ratatoskr.shen -e '(ratatoskr.shake ...)'`. The async `read-byte`/file streams left EOF as an unsettled promise, so `read-file-as-bytelist` looped forever (the 50-min hang); file streams are now synchronous and the shake finishes in ~25 s.
  - **`*hush*` caveat**: `-q` sets `*hush*`, and on **shen-lua and
    shen-rust** that silences the `pr` writes to the output files,
    producing zero-byte artifacts — **omit `-q` on those two**. shen-cl
    (native `pr` override), shen-go and ShenScript route `pr` to file
    streams regardless of `*hush*`, so `-q` is harmless there. Dropping
    `-q` everywhere is the safe default; it only adds a load-echo line to
    stdout, not to the artifacts.

## Tests

`tests/{hello,fib,prolog,metaeval}.shen` are the four fixtures; expected
outputs `hello from shaken shen`, `fib 20 = 6765`,
`mary likes chocolate: true`, and three lines of `eval ...: 42`
(metaeval is the eval-capable fixture: `needs-eval=true`, ~568 kernel
defuns).
Every stage-1 change should be verified through at least one stage-2
builder (the Lua one is fastest).

The Lisp builder is verified on SBCL, GNU CLISP and ECL (`LISP_IMPL=`).
CCL is unsupported: no native Apple Silicon build exists. Implementation
notes that cost real debugging: shen-cl's native `pr` override is
`#+(or ccl sbcl)`, so other implementations need the optional stream
primitives (`shen.write-string` etc. — the driver installs portable
fallbacks when missing); and streams captured in a saved image are dead
on restart under CLISP, so the image toplevel rebinds
`*stoutput*`/`*stinput*` at startup. ECL cannot dump images at all — the
driver compiles each module to an object file and links a real
executable via `c:build-program`, with boot replayed at program startup.

## Name and lineage

This project was previously published as "Yggdrasil 2.0". It was renamed
to Ratatoskr to leave the Yggdrasil name to Dr. Tarver's original work,
of which this is an independent continuation — same idea, retargeted and
rebuilt for the 41.2 kernel. If you need to relate the two: Ratatoskr ≈
Yggdrasil 2.0.

[shen-cl]: https://github.com/Shen-Language/shen-cl
[showboat]: https://github.com/simonw/showboat
