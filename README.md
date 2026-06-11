# Yggdrasil 2.0

A tree-shaker for [Shen](https://shenlanguage.org) programs, retargeted to
ShenOSKernel **41.1**. Based on Mark Tarver's Yggdrasil 1.0 (3-clause BSD).

Yggdrasil turns a Shen program into a minimal, standalone artifact in a
target language: it computes which of the kernel's 1129 functions the
program can actually reach, emits just that slice as KLambda, and hands the
result to a per-target builder that compiles it with the target port's own
KL compiler.

## Architecture

**Stage 1 — shake** (this repo, runs on any certified Shen; developed
against [shen-cl]):

```
shen eval -q -l yggdrasil.shen -e '(yggdrasil.shake ["prog.shen"] "out")'
```

writes to `out/`:

| file | contents |
|---|---|
| `kernel.kl` | shaken kernel defuns, load order preserved |
| `<prog>.kl` | the user program compiled to KLambda |
| `yggdrasil.manifest.txt` | line-oriented contract (`key=value`) |
| `yggdrasil.manifest` | same, as s-expressions |

**Stage 2 — build** (one builder per target port, living in that port's
repo):

| target | builder | output (eval-stripped fib) |
|---|---|---|
| Common Lisp / SBCL | `builders/lisp/build.sh <dir> <exe>` (this repo) | native executable (~36 MB, dominated by SBCL image) |
| LuaJIT | `shen-lua/bin/yggdrasil-build.lua <dir> <out.lua>` | self-contained .lua (~640 KB, ~25 ms startup) |
| Go | `shen-go/cmd/yggdrasil-build <dir> <outdir>` then `go build` | static binary (~4.5 MB, ≤10 ms startup, cross-compiles linux/windows) |
| Rust | `shen-cedar/crates/yggdrasil-build <dir> <outdir>` then `cargo build --release` | static binary (~9 MB, ~40 ms startup) |

**Builder contract**: load `kernel.kl`'s defuns, call `(shen.initialise)`
(41.1 consolidates all global initialisation there), then run each user
file's forms in manifest order — user files contain defuns *and* toplevel
expressions that must execute in source order.

## How the shake works

The kernel call graph (1129 defuns, 5619 edges) is built once by walking
every defun body for call-position symbols and cached as plain text
(`KLambda/callgraph-41.1.shen`). Per shake, a pure worklist reachability
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

## Gotchas (hard-won)

- Shen's `read-file` is **not a data reader**: it applies the currying
  transform to paren applications and turns `[a b c]` into cons ASTs.
  `.kl` files survive because the symbol walk doesn't care about tree
  shape; anything else (like the call-graph cache) must be written and
  parsed as plain text.
- 41.1's stlib is lazily materialised: `mapc`, `filter`,
  `remove-duplicates`, `copy-file` don't exist in port runtimes.
  `yggdrasil.shen` carries its own `ygg.*` versions.
- Compiled KL carries explicit property-table arguments — e.g. the
  external-symbols registration is a 5-element `put` node, not 4.

## Tests

`tests/{hello,fib,prolog}.shen` are the three fixtures; expected outputs
`hello from shaken shen`, `fib 20 = 6765`, `mary likes chocolate: true`.
Every stage-1 change should be verified through at least one stage-2
builder (the Lua one is fastest).

[shen-cl]: https://github.com/Shen-Language/shen-cl
