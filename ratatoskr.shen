\\                                           Ratatoskr
\\                  descended from Yggdrasil 1.0, (c) Mark Tarver, 3 clause BSD
\\
\\ Tree-shaker for Shen programs, updated for ShenOSKernel 41.2.
\\
\\ Stage 1 (this file): shake a program against the 41.2 kernel and emit
\\ minimal KL + a manifest.  Pure Shen against the certified kernel API;
\\ run it on shen-cl - the user KL comes from the host's bootstrap
\\ compiler, and other hosts may emit port-internal hooks (see README,
\\ host-portability gotcha).  Stage 2 (per target, lives in each port
\\ repo): compile the shaken KL with the port's own KL->native compiler.
\\
\\ (ratatoskr.shake ["prog.shen"] "out") writes to out/:
\\    kernel.kl                shaken kernel defuns, in load order
\\    <prog>.kl                user code compiled to KL
\\    ratatoskr.manifest       sexp manifest
\\    ratatoskr.manifest.txt   line-oriented manifest (key=value)
\\
\\ Driver contract for builders: load kernel.kl, call (shen.initialise),
\\ then load the user files in order.  In 41.2 (shen.initialise) performs
\\ all global initialisation, so no separate globals file is needed.
\\
\\ Run from the Ratatoskr directory: paths below are relative.

\\ No package wrapper: 41.2 has no stlib package to import from, and all
\\ stdlib functions are kernel-defined globals.  The public entry point is
\\ explicitly dot-qualified instead.

\\ ShenOSKernel-41.2 in canonical boot order (shen-cl boot.lsp order).
(set *kernel* ["KLambda/compiler.kl" "KLambda/toplevel.kl" "KLambda/core.kl"
 "KLambda/sys.kl" "KLambda/dict.kl" "KLambda/sequent.kl" "KLambda/yacc.kl"
 "KLambda/reader.kl" "KLambda/prolog.kl" "KLambda/track.kl" "KLambda/load.kl"
 "KLambda/writer.kl" "KLambda/macros.kl" "KLambda/declarations.kl"
 "KLambda/types.kl" "KLambda/t-star.kl" "KLambda/init.kl"
 "KLambda/extension-features.kl" "KLambda/extension-expand-dynamic.kl"
 "KLambda/extension-launcher.kl" "KLambda/stlib.kl"])

(set *callgraph-cache* "KLambda/callgraph-41.2.shen")

\\ The 41.2 primitives: special forms plus everything the kernel calls but
\\ does not define.  Derived mechanically: symbols in call position across
\\ KLambda/*.kl minus defun'd names.  prolog-memory, vector, variable?,
\\ read-file-as-* moved into the kernel in 41.2 and are no longer here.
(set *primitives* [if and or cond defun lambda let freeze type trap-error
      cons hd tl cons? intern pos tlstr cn str string? n->string string->n
      set value simple-error error-to-string
      absvector address-> <-address absvector?
      write-byte read-byte open close get-time eval-kl
      = + - * / > < >= <= number?
      shen.char-stinput? shen.char-stoutput?
      shen.read-unit-string shen.write-string
      *stinput* *stoutput*])

\\ ===================== self-contained list helpers ======================
\\ mapc/filter/remove-duplicates/copy-file live in 41.2's stlib, which is
\\ lazily materialised and absent from port runtimes; define our own.

(define rat.mapc
  _ [] -> done
  F [X | Xs] -> (do (F X) (rat.mapc F Xs)))

(define rat.filter
  _ [] -> []
  F [X | Xs] -> [X | (rat.filter F Xs)]  where (F X)
  F [_ | Xs] -> (rat.filter F Xs))

(define rat.remove-dups
  [] -> []
  [X | Xs] -> (rat.remove-dups Xs)  where (element? X Xs)
  [X | Xs] -> [X | (rat.remove-dups Xs)])

(define rat.copy-file
  From To -> (let Bytes (read-file-as-bytelist From)
                  Sink  (open To out)
                  Write (rat.mapc (/. B (write-byte B Sink)) Bytes)
                  Close (close Sink)
                  To))

\\ ============================ stage 1: shake ============================

(define ratatoskr.shake
  Files Dir -> (let MaxPrint   (value *maximum-print-sequence-size*)
                    Unlimit    (set *maximum-print-sequence-size* 1000000000)
                    Kernel     (kernel-code)
                    Graph      (call-graph Kernel)
                    KLFiles    (map (fn bootstrap) Files)
                    KL         (map (fn read-file) KLFiles)
                    UserFs     (function-calls KL)
                    EvalFree   (eval-free? UserFs)
                    Graph2     (if EvalFree (strip-macros-edge Graph) Graph)
                    Foot       (footprint [shen.initialise | UserFs] Graph2)
                    FootCode   (map (/. D (trim-init-tables D Foot EvalFree))
                                    (footcode Foot Kernel))
                    Prims      (find-primitives (append FootCode KL))
                    WriteK     (write-kl-file (@s Dir "/kernel.kl") FootCode)
                    UserOut    (write-user-files KLFiles KL Dir)
                    WriteM     (write-manifest Dir UserOut KL Prims)
                    Restore    (set *maximum-print-sequence-size* MaxPrint)
                    done))

\\ ========================== eval stripping ==============================
\\ The macro expander's registration in *macros* keeps shen.macros - and
\\ through it the typechecker, the define-compiler and eval - reachable
\\ from shen.initialise, putting a ~561-defun floor under every program.
\\ A compiled program only needs that machinery if it can evaluate Shen
\\ at runtime.  When the user KL never mentions an eval-capable entry
\\ point we drop the shen.macros edge from the graph and rewrite the
\\ *macros* registration to (set *macros* ()) at write time.
\\ function-calls over-approximates (every symbol counts), which errs in
\\ the safe direction: a stray symbol named eval keeps the machinery.

(set *eval-entry-points*
     [eval eval-kl load tc spy track step it
      read read-from-string lineread input input+ bootstrap])

(define eval-free?
  UserFs -> (not (intersect? UserFs (value *eval-entry-points*))))

(define intersect?
  [] _ -> false
  [X | Xs] Ys -> (or (element? X Ys) (intersect? Xs Ys)))

(define strip-macros-edge
  [] -> []
  [[shen.initialise-environment | Calls] | Rows]
     -> [[shen.initialise-environment | (remove shen.macros Calls)]
         | (strip-macros-edge Rows)]
  [[shen.f-error | _] | Rows] -> [[shen.f-error] | (strip-macros-edge Rows)]
  [Row | Rows] -> [Row | (strip-macros-edge Rows)])

\\ In an eval-stripped program the pattern-failure handler must not offer
\\ interactive tracking (its y-or-n? prompt calls read, dragging the whole
\\ reader/typechecker/eval); it just errors.  Counterpart of the
\\ shen.f-error case in strip-macros-edge.
(set *static-f-error*
     [defun shen.f-error [V]
        [simple-error [cn [str V] ": partial function or unhandled case"]]])

\\ ====================== kernel call graph (cached) ======================
\\ The original Yggdrasil computed a full transitive closure with Warshall's
\\ algorithm - O(N^3) over every kernel symbol, which does not scale to the
\\ 41.2 kernel (1129 defuns, ~700K of KL).  We only ever need reachability
\\ from a seed set, so build the direct call graph once (cached to disk)
\\ and run a worklist traversal over it per shake.  Full rationale,
\\ including why a faster external closure (Julia/bitsets) is still the
\\ wrong tool: docs/reachability.md.
\\
\\ The graph is a VALUE: a list of rows [F | Callees] threaded through the
\\ footprint computation.  The cache file is plain text - one row per line,
\\ space-separated names - parsed with string primitives.  It must NOT go
\\ through read-file: the Shen reader applies the currying transform to
\\ paren applications (and turns bracket lists into cons ASTs), silently
\\ corrupting any row whose head's declared arity differs from its length.

(define kernel-code
  -> (mapcan (fn read-kl-file) (value *kernel*)))

\\ The kernel files are already fully-expanded KL.  read-file runs them
\\ back through the macro expander, which - on the 41.2 kernel - is fatal:
\\ stlib.kl's own (defun vector.vector-macros ...) embeds literal
\\ (vector.array-> ...) sub-forms, and the live vector.vector-macros macro
\\ fires on them, trying to macro-expand a non-literal dimensional argument
\\ ((hd (tl V2049))) and aborting with "cannot macro expand the dimensional
\\ argument".  read-kl-file mirrors read-file's pipeline (raw s-exprs ->
\\ find-arities/types -> currying transform) but skips macroexpand, so
\\ already-compiled KL is read verbatim - both correct and crash-free.
(define read-kl-file
  File -> (let Bytes  (read-file-as-bytelist File)
               Sexprs (trap-error (compile (/. Z (shen.<s-exprs> Z)) Bytes)
                                  (/. E (shen.reader-error (value shen.*residue*))))
               Types  (shen.find-types Sexprs)
               (map (/. S (shen.process-applications S Types)) Sexprs)))

(define call-graph
  Code -> (trap-error (load-call-graph) (/. E (build-call-graph Code))))

(define load-call-graph
  -> (let Bytes (read-file-as-bytelist (value *callgraph-cache*))
          Rows  (parse-graph Bytes "" [] [])
          (if (empty? Rows) (error "empty call graph cache~%") Rows)))

\\ parse-graph Bytes Token Row Rows: accumulate chars into Token, tokens
\\ into Row, rows into Rows.  Walks the bytelist (O(n)); recursing over a
\\ string with @s patterns would copy the tail each step (O(n^2)).
(define parse-graph
  [] Token Row Rows -> (reverse (close-row Token Row Rows))
  [10 | Bs] Token Row Rows -> (parse-graph Bs "" [] (close-row Token Row Rows))
  [13 | Bs] Token Row Rows -> (parse-graph Bs Token Row Rows)
  [32 | Bs] Token Row Rows -> (parse-graph Bs "" (close-token Token Row) Rows)
  [B | Bs] Token Row Rows -> (parse-graph Bs (cn Token (n->string B)) Row Rows))

(define close-token
  "" Row -> Row
  Token Row -> [(intern Token) | Row])

(define close-row
  Token Row Rows -> (let Full (close-token Token Row)
                         (if (empty? Full) Rows [(reverse Full) | Rows])))

(define build-call-graph
  Code -> (let Fs    (defun-names Code)
               Mark  (rat.mapc (/. F (put F defp true)) Fs)
               Graph (graph-rows Code)
               Save  (save-call-graph Graph)
               Graph))

(define defun-names
  [] -> []
  [[defun F | _] | Code] -> [F | (defun-names Code)]
  [_ | Code] -> (defun-names Code))

(define graph-rows
  [] -> []
  [[defun F _ Body] | Code] -> [[F | (called-fns Body)] | (graph-rows Code)]
  [_ | Code] -> (graph-rows Code))

\\ Two kernel data tables masquerade as code and would otherwise drag
\\ ~every public symbol into every footprint:
\\   - the arity table literal is pure name/number data;
\\   - lambda-form entries (cons F (lambda Y (F Y))) are eta-wrappers
\\     whose only callee is their own key F.  We drop their edges here
\\     and instead filter the entries to the footprint at write time
\\     (see trim-lambda-forms), so a kept entry's F is in Foot already.
(define called-fns
  [shen.initialise-arity-table _] -> [shen.initialise-arity-table]
  [shen.set-lambda-form-entry [cons _ _]] -> [shen.set-lambda-form-entry]
  [put P shen.external-symbols _ | Rest] -> (union (called-fns put) (called-fns Rest))
      where (symbol? P)
  [set shen.*special* _] -> (called-fns set)
  [set shen.*extraspecial* _] -> (called-fns set)
  [shen.assoc-> K | R] -> (union (called-fns shen.assoc->) (called-fns R))
      where (symbol? K)
  [X | Y] -> (union (called-fns X) (called-fns Y))
  F -> [F]   where (and (symbol? F) (kernel-defun? F))
  _ -> [])

\\ defp is a build-time-only membership test: called-fns visits every
\\ symbol leaf of ~700K of KL, where (element? F Fs) over 1129 names
\\ would cost ~45M comparisons.  Never consulted per-shake.
(define kernel-defun?
  F -> (trap-error (get F defp) (/. E false)))

(define save-call-graph
  Graph -> (let Sink  (open (value *callgraph-cache*) out)
                Write (rat.mapc (/. Row (pr-graph-row Row Sink)) Graph)
                Close (close Sink)
                saved))

(define pr-graph-row
  [F | Calls] Sink -> (do (pr (str F) Sink)
                          (rat.mapc (/. C (pr (cn " " (str C)) Sink)) Calls)
                          (pr (n->string 10) Sink)))

\\ ============================ footprint =================================
\\ Pure worklist reachability: the visited set is the accumulator itself.
\\ Seeds that are not kernel functions fall through row-calls to [].
\\ (set *use-warshall* true) routes footprint through the optional Warshall
\\ closure below instead - identical result, kept for homage to the
\\ original; see the Warshall section for the cost caveat.

(set *use-warshall* false)

(define footprint
  Seeds Graph -> (if (value *use-warshall*)
                     (warshall-footprint Seeds Graph)
                     (reach Seeds [] Graph)))

(define reach
  [] Seen _ -> Seen
  [F | Fs] Seen Graph -> (reach Fs Seen Graph)    where (element? F Seen)
  [F | Fs] Seen Graph -> (reach (append (row-calls F Graph) Fs)
                                [F | Seen] Graph))

(define row-calls
  F [[F | Calls] | _] -> Calls
  F [_ | Rows] -> (row-calls F Rows)
  _ [] -> [])

\\ ===================== Warshall closure (homage, optional) ==============
\\ Tarver's original Yggdrasil derived the footprint from the FULL transitive
\\ closure of the call graph, built with an iterative Warshall - the part he
\\ was proudest of.  His version leaned on an array/:=/for DSL that never
\\ shipped, so it could not actually run; this is the same algorithm,
\\ finished against primitives that exist (Shen vectors).  It is preserved
\\ for coherence with the original and as a differential oracle for the
\\ worklist reach (both must yield the same footprint).
\\
\\ Cost is the reason it is not the default: O(V^3) over a V*V boolean
\\ matrix.  Fine on the small graphs of the test fixtures; impractical on the
\\ full 1129-node kernel (see docs/reachability.md).  Enable per run with
\\ (set *use-warshall* true).
\\
\\ One correction over the 1.0 original: each seed is unioned into its own
\\ reachable set (seed-row prepends S), so a directly-called LEAF function is
\\ retained.  The original irreflexive closure gave a leaf no row, and
\\ footprint-by-lookup then dropped it - a latent bug in 1.0.  Pivot K is the
\\ outermost loop, the invariant Warshall correctness depends on.

(define warshall-footprint
  Seeds Graph -> (let Fs    (map (fn row-head) Graph)
                      N     (length Fs)
                      Index (index-rows Fs 1)
                      M     (zero-matrix N)
                      Fill  (populate-matrix Graph M)
                      Close (warshall-iterate M N 1)
                      (collect-reachable Seeds Fs M N)))

(define row-head
  [F | _] -> F)

\\ Map each node name to its 1-based matrix index on a property list (the
\\ same trick kernel-defun? uses), so populate/collect are O(1) lookups.
(define index-rows
  [] _ -> done
  [F | Fs] I -> (do (put F rat.warshall-ix I) (index-rows Fs (+ I 1))))

(define node-index
  F -> (trap-error (get F rat.warshall-ix) (/. E 0)))

\\ N*N boolean matrix as a vector of N row-vectors, every cell false (Shen
\\ vector slots start unpopulated, which is not a boolean - so fill them).
(define zero-matrix
  N -> (fill-row-vectors (vector N) 1 N))

(define fill-row-vectors
  M I N -> M  where (> I N)
  M I N -> (do (vector-> M I (false-vector (vector N) 1 N))
               (fill-row-vectors M (+ I 1) N)))

(define false-vector
  V I N -> V  where (> I N)
  V I N -> (do (vector-> V I false) (false-vector V (+ I 1) N)))

(define mget
  M I J -> (<-vector (<-vector M I) J))

(define mset
  M I J Val -> (vector-> (<-vector M I) J Val))

(define populate-matrix
  [] _ -> done
  [[F | Calls] | Rows] M -> (do (populate-row (node-index F) Calls M)
                                (populate-matrix Rows M)))

(define populate-row
  _ [] _ -> done
  I [C | Cs] M -> (do (set-edge I (node-index C) M) (populate-row I Cs M)))

(define set-edge
  _ 0 _ -> done            \\ callee is not a graph node (e.g. a primitive)
  I J M -> (mset M I J true))

\\ Iterative Warshall: pivot K outermost, then I, then J -
\\ M[I][J] |= M[I][K] and M[K][J].  The I-loop skips rows where M[I][K] is
\\ false (nothing to propagate), matching the guard in the 1.0 original.
(define warshall-iterate
  M N K -> M  where (> K N)
  M N K -> (do (warshall-i M N K 1) (warshall-iterate M N (+ K 1))))

(define warshall-i
  M N K I -> done  where (> I N)
  M N K I -> (do (if (mget M I K) (warshall-j M N K I 1) done)
                 (warshall-i M N K (+ I 1))))

(define warshall-j
  M N K I J -> done  where (> J N)
  M N K I J -> (do (if (mget M K J) (mset M I J true) done)
                   (warshall-j M N K I (+ J 1))))

(define collect-reachable
  [] _ _ _ -> []
  [S | Ss] Fs M N -> (union (seed-row S Fs M N) (collect-reachable Ss Fs M N)))

\\ A seed always contributes itself (the worklist adds every seed to Seen,
\\ kernel node or not); a kernel seed also contributes its closure row.
(define seed-row
  S Fs M N -> (let I (node-index S)
                   (if (= I 0) [S] [S | (row-true I Fs M 1 N)])))

(define row-true
  _ _ _ J N -> []  where (> J N)
  I Fs M J N -> [(nth J Fs) | (row-true I Fs M (+ J 1) N)]  where (mget M I J)
  I Fs M J N -> (row-true I Fs M (+ J 1) N))

(define function-calls
  [X | Y] -> (union (function-calls X) (function-calls Y))
  V -> []   where (variable? V)
  F -> [F]  where (symbol? F)
  _ -> [])

(define footcode
  Footprint Kernel -> (rat.filter (/. Def (mentioned? Def Footprint)) Kernel))

\\ Write-time rewrites of the two initialise defuns whose bodies embed
\\ registration tables (right-nested do-chains):
\\   - lambda-forms registers eta-wrappers only for footprint functions
\\     (counterpart of the called-fns special case above);
\\   - when eval-stripping, the *macros* registration in
\\     initialise-environment becomes (set *macros* ()) (counterpart of
\\     strip-macros-edge).
(define trim-init-tables
  [defun shen.initialise-lambda-forms P Body] Foot _ ->
      [defun shen.initialise-lambda-forms P (trim-lf-chain Body Foot)]
  [defun shen.initialise-environment P Body] Foot true ->
      [defun shen.initialise-environment P (strip-macros-chain Body Foot)]
  [defun shen.f-error | _] _ true -> (value *static-f-error*)
  Def _ _ -> Def)

(define trim-lf-chain
  [do E Rest] Foot -> (let R (trim-lf-chain Rest Foot)
                           (if (lf-keep? E Foot) [do E R] R))
  E Foot -> (if (lf-keep? E Foot) E true))

(define lf-keep?
  [shen.set-lambda-form-entry [cons F _]] Foot -> (element? F Foot)
  _ _ -> true)

\\ Alongside emptying *macros*, restrict the arity-table literal to the
\\ footprint (plus primitives): an eval-stripped program can never define
\\ or look up functions outside its footprint, and the full literal both
\\ bloats kernel.kl and re-introduces stray names (eval-kl among them)
\\ that find-primitives would report.
(define strip-macros-chain
  [do [set *macros* _] Rest] Foot -> [do [set *macros* []] (strip-macros-chain Rest Foot)]
  [do [shen.initialise-arity-table Lit] Rest] Foot ->
      [do [shen.initialise-arity-table (trim-arity-pairs Lit (keep-set Foot))]
          (strip-macros-chain Rest Foot)]
  [do [put P shen.external-symbols Lit V] Rest] Foot ->
      [do [put P shen.external-symbols (trim-sym-list Lit (keep-set Foot)) V]
          (strip-macros-chain Rest Foot)]
  [do E Rest] Foot -> [do E (strip-macros-chain Rest Foot)]
  E _ -> E)

\\ Names worth keeping in the stripped data tables: footprint plus
\\ primitives, minus the eval entry points (unreachable by construction).
(define keep-set
  Foot -> (rat.filter (/. F (not (element? F (value *eval-entry-points*))))
                      (append Foot (value *primitives*))))

(define trim-arity-pairs
  [cons Name [cons Arity Rest]] Keep ->
      (if (element? Name Keep)
          [cons Name [cons Arity (trim-arity-pairs Rest Keep)]]
          (trim-arity-pairs Rest Keep))
  X _ -> X)

(define trim-sym-list
  [cons Name Rest] Keep -> (if (element? Name Keep)
                               [cons Name (trim-sym-list Rest Keep)]
                               (trim-sym-list Rest Keep))
  X _ -> X)

(define mentioned?
  [defun F | _] Fs -> (element? F Fs)
  _ _ -> false)

\\ ============================ primitives ================================

(define find-primitives
  X -> [X]     where (primitive? X)
  [X | Y] -> (union (find-primitives X) (find-primitives Y))
  _ -> [])

(define primitive?
  {symbol --> boolean}
  X -> (element? X (value *primitives*)))

\\ ---------------------------- capabilities ------------------------------
\\ Group the effectful gateway primitives by capability.  A shaken program
\\ "cannot reach" a capability when the emitted KL contains none of its
\\ gateways - a static, certifiable property of the artifact (the code
\\ literally has no occurrence of the gateway).  Derived from the same
\\ primitive set the manifest already reports (find-primitives over the
\\ footprint + user KL), so it stays in lock-step with the eval-strip:
\\ eval-kl drops out of Prims exactly when the program is eval-free, and
\\ cannot-reach then lists eval.  Reported as reaches=/cannot-reach= lines;
\\ builders ignore keys they do not recognise.
(set *capabilities*
  [[eval  eval-kl]
   [read  read-byte]
   [write write-byte]
   [file  open close]
   [clock get-time]])

(define cap-label
  [L | _] -> L)

(define cap-reached?
  [_ | Sinks] Prims -> (intersect? Sinks Prims))

(define reaches-caps
  Prims -> (map (fn cap-label)
                (rat.filter (/. C (cap-reached? C Prims)) (value *capabilities*))))

(define cannot-reach-caps
  Prims -> (map (fn cap-label)
                (rat.filter (/. C (not (cap-reached? C Prims))) (value *capabilities*))))

\\ Used by backends that map primitives to copyable implementation files
\\ (the Tarver model, retained for the Lisp backend).
(define primfiles
  Primitives Language -> (rat.remove-dups
                          (mapcan (/. Primitive (get Primitive Language)) Primitives)))

(define copy-primitive-files
  {(list string) --> string --> (list string)}
  Files Dir -> (map (/. X (copy-primitive-file X Dir)) Files))

(define copy-primitive-file
  {string --> string --> string}
  File Dir -> (let Truncate (truncate-filename File "")
                   Copy (rat.copy-file File (@s Dir "/" Truncate))
                   Truncate))

(define truncate-filename
  {string --> string --> string}
  "" Out -> Out
  (@s "/" S) _ -> (truncate-filename S "")
  (@s S Ss) Out -> (truncate-filename Ss (cn Out S)))

\\ ========================== writing KL files ============================
\\ Shen's printer renders lists in Shen syntax ([...]), but .kl files must
\\ be in KL syntax ((...)), so we print cons trees ourselves.

(define write-kl-file
  File Code -> (let Sink  (open File out)
                    Write (rat.mapc (/. X (do (pr-kl X Sink)
                                          (pr (make-string "~%~%") Sink))) Code)
                    Close (close Sink)
                    File))

(define pr-kl
  [] Sink -> (pr "()" Sink)
  [X | Xs] Sink -> (do (pr "(" Sink) (pr-kl X Sink) (pr-kl-body Xs Sink))
  \\ The kernel writer renders anything = to (fail) as "..." (see
  \\ shen.arg->str), which is unreadable KL; print the marker verbatim.
  X Sink -> (pr "shen.fail!" Sink)  where (= X (fail))
  X Sink -> (pr (make-string "~S" X) Sink))

(define pr-kl-body
  [] Sink -> (pr ")" Sink)
  [X | Xs] Sink -> (do (pr " " Sink) (pr-kl X Sink) (pr-kl-body Xs Sink)))

(define pr-kl-line
  X Sink -> (do (pr-kl X Sink) (pr (make-string "~%") Sink)))

(define write-user-files
  [] [] _ -> []
  [File | Files] [Code | Codes] Dir ->
     (let Name  (truncate-filename File "")
          Write (write-kl-file (@s Dir "/" Name) Code)
          [Name | (write-user-files Files Codes Dir)]))

\\ ============================ manifest ==================================
\\ Contract additions requested by every stage-2 builder so far:
\\   fn=<name> <arity>    one per user defun, so builders need not rescan
\\                        the KL (arity bugs were the #1 stage-2 trap)
\\   global=              *stinput* etc., split out of primitive=
\\   primitive-optional=  guarded-dead unless the port's char-st*
\\                        predicates return true; a port may omit them
\\ Builders must ignore keys they do not recognise.

(set *optional-primitives* [shen.write-string shen.read-unit-string])
(set *global-primitives*   [*stinput* *stoutput*])

(define write-manifest
  Dir UserFiles UserKL Prims ->
     (let NeedsEval (element? eval-kl Prims)
          Fns       (user-arities UserKL)
          Globals   (rat.filter (/. P (element? P (value *global-primitives*))) Prims)
          Optional  (rat.filter (/. P (element? P (value *optional-primitives*))) Prims)
          Required  (rat.filter (/. P (not (or (element? P Globals)
                                               (element? P Optional)))) Prims)
          Reaches   (reaches-caps Prims)
          Cannot    (cannot-reach-caps Prims)
          Sexp (write-manifest-sexp Dir UserFiles Fns Required Optional Globals NeedsEval Reaches Cannot)
          Txt  (write-manifest-txt Dir UserFiles Fns Required Optional Globals NeedsEval Reaches Cannot)
          done))

(define user-arities
  [] -> []
  [[[defun F Args | _] | Forms] | Files] -> [[F (rat.len Args)]
                                             | (user-arities [Forms | Files])]
  [[_ | Forms] | Files] -> (user-arities [Forms | Files])
  [[] | Files] -> (user-arities Files))

(define rat.len
  [] -> 0
  [_ | Xs] -> (+ 1 (rat.len Xs)))

(define write-manifest-sexp
  Dir UserFiles Fns Required Optional Globals NeedsEval Reaches Cannot ->
    (let Sink (open (@s Dir "/ratatoskr.manifest") out)
         W1 (pr-kl-line ["ratatoskr-manifest" 2] Sink)
         W2 (pr-kl-line ["kernel-version" "41.2"] Sink)
         W3 (pr-kl-line ["kernel" "kernel.kl"] Sink)
         W4 (pr-kl-line ["init" shen.initialise] Sink)
         W5 (pr-kl-line ["user" | UserFiles] Sink)
         W6 (rat.mapc (/. FA (pr-kl-line ["fn" | FA] Sink)) Fns)
         W7 (pr-kl-line ["primitives" | Required] Sink)
         W8 (pr-kl-line ["primitives-optional" | Optional] Sink)
         W9 (pr-kl-line ["globals" | Globals] Sink)
         WA (pr-kl-line ["needs-eval" NeedsEval] Sink)
         WB (pr-kl-line ["reaches" | Reaches] Sink)
         WC (pr-kl-line ["cannot-reach" | Cannot] Sink)
         (close Sink)))

(define write-manifest-txt
  Dir UserFiles Fns Required Optional Globals NeedsEval Reaches Cannot ->
    (let Sink (open (@s Dir "/ratatoskr.manifest.txt") out)
         W1 (pr (make-string "manifest-version=2~%") Sink)
         W2 (pr (make-string "kernel-version=41.2~%") Sink)
         W3 (pr (make-string "kernel=kernel.kl~%") Sink)
         W4 (pr (make-string "init=shen.initialise~%") Sink)
         W5 (rat.mapc (/. F (pr (make-string "user=~A~%" F) Sink)) UserFiles)
         W6 (rat.mapc (/. FA (pr (make-string "fn=~A ~A~%" (hd FA) (hd (tl FA))) Sink)) Fns)
         W7 (rat.mapc (/. P (pr (make-string "primitive=~A~%" P) Sink)) Required)
         W8 (rat.mapc (/. P (pr (make-string "primitive-optional=~A~%" P) Sink)) Optional)
         W9 (rat.mapc (/. P (pr (make-string "global=~A~%" P) Sink)) Globals)
         WA (pr (make-string "needs-eval=~A~%" NeedsEval) Sink)
         WB (rat.mapc (/. C (pr (make-string "reaches=~A~%" C) Sink)) Reaches)
         WC (rat.mapc (/. C (pr (make-string "cannot-reach=~A~%" C) Sink)) Cannot)
         (close Sink)))

