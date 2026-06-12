# Ratatoskr Showcase Ideas

Candidate flagship demos for Ratatoskr — applications that genuinely need
Shen's unique features, not just tolerate them.

## The framing

Shen's distinctive features, and what a showcase must exercise:

1. **Sequent-calculus type system** — user-definable type theories. Not
   "types like Haskell" but "encode *domain* judgments as inference rules":
   `Ruleset is total`, `AllowedIPs are disjoint`, `Policy P' ⊆ Policy P`.
2. **Embedded Prolog** (`defprolog`) — analysis questions become queries:
   reachability, shadowing, trust paths, access diffs.
3. **Shen-YACC / `defcc`** — a compiler-compiler in the box. DSLs are cheap.
4. **Ratatoskr itself** — one source shakes to a ~640 KB Lua file, a
   ~4.5 MB static Go binary (≤10 ms startup), a Rust binary, a ~120 KB
   self-contained JS module (Node/Bun/Deno), or a Lisp image.
   Eval-stripped programs carry only ~100 kernel defuns.

The hard constraint that shapes everything: **the shaken kernel has no
networking, threads, or crypto primitives, and port I/O differs.** The
winning shape is compute-shaped — *parse → verify → decide/generate* —
embedded in a host (nginx, the OS kernel, a CI pipeline) that does the I/O
and the crypto. A whole web server in Shen fights the platform; a verified
*brain inside* nginx uses it.

A recurring architectural pattern below, mirroring Ratatoskr's own
two-stage design:

- **Authoring/compiler tool** — full Shen, eval machinery welcome, runs at
  CI time. Parses the DSL, runs the type-level and Prolog analyses, reports
  proofs or counterexamples, and *emits a specialized Shen program* for the
  verified artifact.
- **Decision artifact** — the eval-stripped shake of that emitted program.
  Pure pattern-matching dispatch, no interpreter in the hot path, ~100
  kernel defuns. Each policy/ruleset version becomes its own tiny native
  artifact: **policy-as-binary**.

---

## Idea 1 — Verified firewall / routing policy compiler for OpenResty ⭐ recommended

**One-liner:** Your firewall policy, as a verified 640 KB Lua file.

**The unfair advantage:** OpenResty *is* LuaJIT. A shaken Shen program drops
straight into `access_by_lua_file` / `rewrite_by_lua_file`. No FFI, no
sidecar, no IPC — the verified decision logic runs inside the nginx worker.

**What it does:**

- A routing/firewall/rate-limit DSL (paths, methods, CIDR ranges, headers,
  rate classes) parsed with `defcc`. Use a hand-rolled lexer feeding token
  lists so the *artifact* stays eval-strippable; the authoring tool can use
  the full reader.
- Compile-time proofs that nginx configs and iptables cannot express:
  - **Totality** — every possible request matches some rule (the type
    system: a judgment that the match tree covers the request space).
  - **No shadowing** — every rule is reachable; no rule is dead. Literally
    a Prolog query: `(shadowed? Rule Earlier-Rules)` over match predicates.
  - **No contradiction** — nothing is simultaneously allowed and
    blackholed; rate classes are consistent.
  - **Diff safety** — "does this change open anything that was closed?"
    A Prolog query comparing two rulesets, run in CI on every policy PR.
- The compiler emits a specialized Shen program for *that ruleset* —
  decision logic as straight pattern matching — and Ratatoskr shakes it.
  Deploy the Lua artifact to OpenResty; deploy the *identical* ruleset as a
  Go binary for services not behind nginx.

**Demo money-shot (perfect for showboat):**

1. Show a small policy file. Compile → proofs reported → `out/policy.lua`.
2. `curl` against OpenResty: allowed route passes, blocked route 403s.
3. Edit the policy so rule 9 shadows rule 4. Compiler **refuses with a
   counterexample request** ("GET /api/v2/health from 10.0.0.0/8 matches
   rule 4, never reaches rule 9").
4. Fix it, rebuild, hot-reload the Lua file, `curl` shows the new behavior.
   All in one executable doc.

**Risks/notes:** Totality over CIDR × path × method space needs a sensible
finite abstraction (interval/prefix reasoning, not enumeration). Keep v1's
predicate language small enough that shadowing is decidable by construction.

---

## Idea 2 — Mesh-network control plane (the WireGuard idea, relocated)

**One-liner:** Shen proves the trust graph; the kernel does the crypto.

**Why not crypto in Shen:** implementing ChaCha20-Poly1305 in Shen is the
wrong fit — performance, side channels, and no crypto primitives in the
kernel. The *data plane stays in WireGuard*. But mesh networks have a
trust/reachability problem that is pure logic programming, and today people
manage it with YAML and hope.

**What it does:**

- Ingest the mesh topology: peers, public keys, endpoints, AllowedIPs,
  trust edges, revocations.
- Prove invariants with types + Prolog:
  - **AllowedIPs disjointness** — no two peers claim overlapping ranges
    (routing ambiguity = a query that must fail, with the overlap as
    counterexample).
  - **Trust-path reachability** — "is there a path of trust from A to B?"
    and its dual, "node X is *not* reachable from the quarantine zone."
  - **Revocation impact** — "does revoking this key partition the
    network?" — answered *before* you revoke.
  - **Policy conformance** — typed judgments like `prod peers never trust
    dev peers directly`.
- Generate the per-peer WireGuard configs (`wg-quick` files or `wg set`
  scripts) from the proven topology.
- Ship as a shaken **static Go binary** — the natural fit for an
  ops/coordinator tool: single file, cross-compiles to linux/windows,
  ≤10 ms startup, runs fine in a minimal container or on the nodes
  themselves.

**Demo money-shot:** add a peer whose AllowedIPs overlaps an existing
subnet → coordinator refuses with the exact overlapping range; run the
partition query on a proposed revocation → it names the nodes that would be
orphaned; then emit configs and bring up a real 3-node wg mesh.

**Risks/notes:** the demo needs root/netns for a live mesh; a `netns`-based
showboat doc keeps it self-contained. This is a strong *second act* after
Idea 1 — it reuses the entire analysis layer in a new domain.

---

## Idea 3 — Authorization engine: "Cedar, but the prover and the engine are the same language"

**One-liner:** One verified policy source, identical decision semantics in
nginx (Lua), your Go services, and Rust edge workers.

**The hook:** AWS Cedar is a policy language whose team wrote Dafny proofs
*alongside* the Rust implementation and must keep the two in sync. OPA/Rego
has no proofs at all. In Shen, the policy language (`defcc`), the analysis
(Prolog), the typed semantics (sequent rules), and the production decision
engine are **one source**. There is nothing to keep in sync.

**What it does:**

- A Cedar/Rego-class language: principals, actions, resources, conditions,
  permit/forbid with forbid-overrides semantics.
- Analyses as Prolog queries:
  - "Who can access resource R?" / "What can principal P do?" —
    enumeration over the policy set.
  - **Policy diff:** "did this change broaden anyone's access?" — compare
    policy sets, report the delta as concrete (principal, action, resource)
    witnesses. This is the killer CI feature; auditors dream about it.
  - Forbid-coverage: "is there any path to resource R not guarded by an
    MFA condition?"
- Typed policy well-formedness: a custom type theory where ill-scoped
  attributes or unsatisfiable conditions are *type errors*.
- **The multi-target moat:** the same shaken slice becomes the Lua module
  in the API gateway, the Go middleware in the services, the JS module in
  the Node services, and the Rust library at the edge. Provably identical
  semantics across the stack — it is literally the same kernel slice, not
  four reimplementations that drift. Policy-engine drift between enforcement points is a real, named
  security problem.

**Demo money-shot:** one policy file → five artifacts → the same denial
decision, byte-identical reason string, from nginx, a Go HTTP middleware,
and a Rust CLI. Then a policy PR that quietly broadens access → CI query
prints the exact new (principal, action, resource) triples it would grant.

**Risks/notes:** biggest scope of the bunch — the language needs restraint
(no full Cedar entity hierarchies in v1). Decision latency in the Lua path
should be benchmarked early; pattern-matched specialized policies (the
policy-as-binary trick from Idea 1) keep it fast.

---

## Idea 4 — Binary-protocol parser workbench (langsec angle)

**One-liner:** Grammar in, verified parser out, on five runtimes.

**The hook:** parsers of untrusted input are where the CVEs live
(heartbleed-class bugs are parser bugs). The langsec community's answer is
"parse with verified grammars, not hand-rolled pointer arithmetic" — but
their tooling rarely meets production runtimes. `defcc` + Ratatoskr does.

**What it does:**

- Define a binary format (TLV protocols, DNS wire format, a bespoke IoT
  framing) as a `defcc` grammar over byte/token streams, with typed AST
  output — length fields that must agree, ranges that must hold, are
  *judgments*, not asserts.
- Prolog for grammar-level analysis: ambiguity detection, unreachable
  productions, "can any input make field A disagree with length B?"
- Shake to per-target artifacts: the **Rust** library for the production
  network service, the **Lua** one for an OpenResty-side protocol filter
  or a Wireshark-adjacent dissector, the **Go** binary as a CLI
  validator/fuzz-harness oracle.

**Demo money-shot:** same grammar, three artifacts; feed all three a fuzz
corpus and show they accept/reject identically (differential testing
against themselves — and against a popular hand-written parser, where the
hand-written one disagrees with its own RFC).

**Risks/notes:** `defcc` is designed for token lists; byte-level binary
parsing needs a thin lexing layer and care about performance. Less flashy
than policy ideas, but the differential-testing demo is extremely
convincing to a security audience.

---

## Idea 5 — Typed configuration generator (Dhall/CUE competitor)

**One-liner:** Sequent-calculus types for your Kubernetes manifests.

**What it does:**

- Domain type theories for config: "a valid NetworkPolicy", "a Deployment
  whose probes are consistent with its ports", "a Terraform plan that never
  destroys a stateful resource". These are inference rules, not schema
  checks — they can relate *multiple* documents ("every Service selector
  matches some Deployment's labels").
- Prolog for cross-document queries: orphaned selectors, privilege
  escalation paths through RBAC objects, "which configs change if this
  base value changes?"
- Generate the YAML/HCL. Ship the generator as a shaken Go binary — a
  single-file CI tool, the same distribution story as `kustomize`.

**Why it ranks lower:** real pain point, and the type-theory angle is the
purest Shen flex of the bunch — but the output is dead files rather than a
running artifact, so it shows off Ratatoskr's deployment story least. Good
blog-post material; weaker live demo.

---

## Comparison

| | Shen types | Prolog | defcc | Multi-target payoff | Demo punch | Scope |
|---|---|---|---|---|---|---|
| 1. Firewall compiler (OpenResty) | totality, consistency | shadowing, diffs | policy DSL | **Lua is the star** + Go | ⭐⭐⭐ counterexample → curl | medium |
| 2. Mesh control plane | conformance | trust paths, partition | topology files | Go static binary | ⭐⭐ live wg mesh | medium |
| 3. Authorization engine | well-formedness | access diffs | policy language | **all five, identical semantics** | ⭐⭐⭐ cross-stack denial | large |
| 4. Parser workbench | length/range judgments | ambiguity | **grammars are the product** | Rust + Lua + Go + JS | ⭐⭐ differential fuzzing | medium |
| 5. Config generator | **purest type flex** | cross-doc queries | config DSL | Go CLI only | ⭐ | small–medium |

## Recommendation

**Build Idea 1 first.** It demonstrates every distinctive Shen feature with
none feeling bolted on, lands in a domain (API gateways, WAFs) where people
feel real pain, exploits the OpenResty/LuaJIT coincidence that no other
language toolchain can claim, and produces exactly the kind of
edit-refuse-fix-curl narrative `showboat` was built for.

**Sequence:** Idea 1 → Idea 2 (reuses the whole analysis layer; "same
engine, new domain" is itself a story) → Idea 3 as the ambitious flagship
once the policy-as-binary machinery is proven. Ideas 4 and 5 are
respectable spin-offs/blog posts along the way.
