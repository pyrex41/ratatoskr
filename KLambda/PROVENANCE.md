# Kernel provenance

The `.kl` files in this directory are Mark Tarver's **refreshed S41.2**
kernel, vendored byte-for-byte from the canonical mirror of his uploads:

- **Canonical source:** `pyrex41/shen-s41.1`, tag
  `s41.2-pristine-20260711` (commit `11fc51b`), files `KLambda/*.kl`.
  Verified byte-identical here with `cmp` at vendoring time.
- **Upstream origin:** <https://www.shenlanguage.org/Download/S41.2.zip>,
  re-uploaded 2026-07-11 (`Last-Modified` header; an in-place refresh —
  same URL and version number as the earlier S41.2, substantially
  different content). Zip SHA-256:
  `51becbfd60fa8c93c3f8ae5b20b948eaa84c4b1d14ad2f5d2a056002a53ee836`

This is a **lineage switch**: earlier Ratatoskr vendored the community
ShenOSKernel-41.2 packaging (Shen-Language/shen-sources, tag `shen-41.2`).
The S-series kernel differs structurally (and has had the 15-file
backend.kl layout since 41.1 — see the mirror's PROVENANCE.md for the
lineage note):

- `backend.kl` — the `cl.*` KL→Lisp compiler, inside the kernel. It is
  vendored for the Lisp builder's eval path but is **not** on the
  runtime boot list (`*kernel*`), matching upstream `install.lsp`.
- `compiler.kl` (shen-cl build artifact), `dict.kl`, `init.kl`,
  `stlib.kl` and the community `extension-*.kl` files are gone. Dicts
  are replaced by a property vector (`*property-vector*`); the stlib
  ships as lazily-loaded Shen sources (`S41/Lib/StLib`); there is **no
  `shen.initialise`** — initialisation is toplevel forms in
  `declarations.kl` and `types.kl`, which the shake wraps into a
  synthetic `(defun shen.initialise () ...)`.
- Against the community kernel: 672 shared defuns, 156 modified
  (including `put`, `get`, `arity`, `bootstrap`, `read`, `macroexpand`),
  21 new, ~26 core removals besides the dropped files.
- Boot order is `install.lsp`'s: sys writer core reader declarations
  toplevel macros load prolog sequent track t-star yacc types.

`callgraph-*.shen` files are generated caches (gitignored).
