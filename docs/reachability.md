# Design note: seed-set reachability, not Warshall closure

**Status**: decided (Yggdrasil 2.0, June 2026)
**Code**: `yggdrasil.shen` — `call-graph`, `footprint`, `reach`
**Decision**: compute the shaken footprint with a worklist traversal (BFS/DFS)
over a cached direct call graph. Do **not** compute the transitive closure
(Warshall), and do **not** add an external compute step (e.g. Julia) to speed
a closure up — the closure itself is the wrong tool, not its implementation.

## The problem Yggdrasil actually solves

Tree-shaking is: given the kernel call graph and a seed set
(`shen.initialise` plus every function the user program calls), find all
kernel defuns *reachable from the seeds*, and discard the rest.

That is **single-source (multi-seed) reachability** — one row of the
reachability relation, unioned over a handful of seeds. It is not all-pairs
reachability.

## Why the original Yggdrasil used Warshall, and why 2.0 dropped it

Tarver's original Yggdrasil computed the full transitive closure of the
kernel call graph with Warshall's algorithm: Θ(N³) over every kernel symbol.
That was tolerable for the small kernels it targeted. Against ShenOSKernel
41.1 it is not:

| | 41.1 numbers |
|---|---|
| Kernel defuns (V) | 1,129 |
| Call edges (E) | 5,619 (≈ 5 per node — very sparse) |
| Kernel KL source | ~700 KB |
| Warshall closure | V³ ≈ 1.44 × 10⁹ ops, plus a V×V matrix |
| Worklist reachability | O(V + E) ≈ 6.7 × 10³ graph ops per shake |

Beyond the constant-factor pain, the closure computes ~1.27 million
pairwise answers per shake and then throws away all but one row's worth.

## What 2.0 does instead

1. **Build the direct call graph once** (`build-call-graph`): for each
   `defun`, record which kernel-defined names appear in its body. This is
   the only expensive pass (it walks every symbol leaf of ~700 KB of KL),
   so it is cached to disk (`KLambda/callgraph-41.1.shen`) and reloaded on
   subsequent shakes. The cache is keyed to the kernel version, which only
   changes when the kernel does.
2. **Per shake, traverse from the seeds** (`footprint` / `reach`): a pure
   worklist — pop a function, skip if seen, otherwise mark it and push its
   callees. The visited set *is* the result.

Note on terminology: `reach` pushes callees onto the *front* of the
worklist, so the traversal order is depth-first. This is immaterial — BFS,
DFS, and any other correct worklist order compute the identical reachable
set. The choice that matters is *traversal vs. closure*, not *which
traversal*.

Conservatism note: `called-fns` collects every kernel-defined symbol that
appears anywhere in a body, not just call position. That over-approximates
(a function named as data keeps its target alive) but never
under-approximates, which is the correct failure direction for a shaker —
especially with `eval-kl` and higher-order kernel code in play.

## Why not Julia (or bitsets, or any faster Warshall)

The temptation: Warshall closure "feels idiomatic" and a tuned
implementation (Julia, bitset rows at word-parallelism w=64) gets closure
down to O(V³/w) ≈ 2.2 × 10⁷ word ops. Objections, in order of importance:

1. **Wrong asymptotics for the question asked.** Closure is Ω(V²) just to
   write its output. Traversal is O(V + E). On a graph this sparse the gap
   is ~190× even against an ideal bitset closure, and the closure's extra
   work buys answers (reachability between arbitrary non-seed pairs) that
   no part of the pipeline consumes.
2. **Portability is the product.** Stage 1's contract (see the header of
   `yggdrasil.shen`) is that it runs on *any certified Shen*. Adding a
   Julia (or C, or anything) sidecar for graph math breaks the one
   property the tool exists to provide. There is no performance problem to
   justify it: per-shake reachability over 1,129 nodes is milliseconds in
   pure Shen.
3. **The actual bottleneck was never the traversal.** Profiling during the
   41.1 retarget showed the cost is in *building* the graph (one walk of
   700 KB of KL — solved by the disk cache and the `defp` property-list
   membership test) and in reading/writing KL files. Speeding up the
   per-shake traversal optimizes a rounding error.

If per-shake traversal ever did show up in a profile, the in-language fix
is to replace `row-calls`'s linear scan of the row list (O(V) per pop,
O(V·E) per shake — still ≪ closure) with a property-list lookup, the same
trick `kernel-defun?` already uses. That is a 10-line change, not a new
toolchain.

## When to revisit

Reconsider only if a future feature needs *many-pair* reachability over a
static graph — e.g. "which functions can reach `error`?" asked for every
function, or cycle/SCC structure for load ordering. Even then the standard
answer is Tarjan SCC + condensation (linear time) or per-query traversal,
not Warshall. Full closure earns its keep only when queries are dense over
the pair space and the graph is small; neither holds here.
