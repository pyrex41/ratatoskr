\\                            Yggdrasil 2.0 - stage 2 builder (Common Lisp / SBCL)
\\
\\ Run via the shen-cl binary from the Yggdrasil directory, after loading
\\ yggdrasil.shen (for the ygg.* list helpers):
\\
\\   shen eval -q -l yggdrasil.shen -l builders/lisp/build.shen \
\\        -e '(lsp.build "out" "/abs/path/to/exe")'
\\
\\ build.sh wraps this and then runs sbcl on DIR/driver.lsp.
\\
\\ Reads DIR/yggdrasil.manifest - the sexp manifest, because read-file
\\ parses its paren rows directly into plain lists (the .txt manifest would
\\ need string parsing).  Then:
\\
\\   - compiles DIR/kernel.kl with shen-cl.kl->lisp -> DIR/kernel.lsp
\\   - compiles each user .kl -> DIR/<name>.lsp; toplevel non-defun forms
\\     are wrapped, in source order, into (DEFUN |yggdrasil.toplevel-<name>| () ...)
\\     which the driver's saved toplevel runs after (shen.initialise)
\\   - copies the shen-cl runtime sources (package.lsp primitives.lsp
\\     native.lsp shen-utils.lsp overwrite.lsp) and the static driver.lsp
\\     into DIR, so DIR is self-contained
\\   - writes DIR/yggdrasil.config.lsp telling the driver which user modules
\\     to load and where save-lisp-and-die should write the executable
\\
\\ Strategy note: this reuses shen-cl's own runtime .lsp files rather than
\\ the 34.6-era Primitives/CL snippets (kept in the repo as historical
\\ reference only).

\\ The binary carries the KL->Lisp compiler (compiled/compiler.lsp) as Lisp
\\ functions, but they are absent from the Shen arity table, so eval cannot
\\ apply them until the arities are registered.
(shen.store-arity shen-cl.kl->lisp 1)
(shen.store-arity shen-cl.cl 1)

\\ Compiler flags, as shen-cl's boot would set them.  *compiling-shen-sources*
\\ enables trap-error optimisations that are only sound for kernel sources;
\\ lsp.compile-kernel turns it on, user code is compiled with it off.
(set shen-cl.*factorise-patterns* true)
(set shen-cl.*compiling-shen-sources* false)

(set lsp.*shen-cl* "../shen-cl/")
(set lsp.*driver* "builders/lisp/driver.lsp")
(set lsp.*runtime-files*
     ["package.lsp" "primitives.lsp" "native.lsp" "shen-utils.lsp" "overwrite.lsp"])

\\ Guard against the Shen printer truncating anything big (error messages
\\ aside, all printing below goes through lsp.sexp->string).
(set *maximum-print-sequence-size* 1000000000)

\\ ======================= printing compiled forms =========================
\\ Same printing approach as shen-cl's own precompile step
\\ (shen-cl/scripts/build.shen): symbols containing lowercase characters are
\\ printed in |pipes| so the case-sensitive Shen names survive the CL
\\ reader; uppercase/uncased symbols print bare.

(define lsp.sexp->string
  [] -> "()"
  true -> "|true|"
  false -> "|false|"
  Comma -> "|,|"  where (= Comma ,)
  Sym -> (lsp.symbol->string Sym)  where (symbol? Sym)
  S -> (make-string "~R" (lsp.escape-string S))  where (string? S)
  [Quote Exp] -> (@s "'" (lsp.sexp->string Exp))  where (= Quote (shen-cl.cl quote))
  [Sexp | Sexps] -> (@s "("
                        (lsp.concat-strings
                         (map (/. X (lsp.sexp->string X)) [Sexp | Sexps]))
                        ")")
  Sexp -> (make-string "~R" Sexp))

(define lsp.symbol->string
  S -> "|;|"  where (= ; S)
  S -> "|:|"  where (= : S)
  S -> (@s "|" (str S) "|")  where (lsp.cased-symbol? (explode S))
  S -> (str S))

(define lsp.cased-symbol?
  [] -> false
  [C | Rest] -> (or (lsp.lowercase? C) (lsp.cased-symbol? Rest)))

(define lsp.lowercase?
  C -> (let N (string->n C)
         (and (>= N 97) (<= N 122))))

(define lsp.escape-string
  S -> (lsp.escape-string-h (explode S)))

(define lsp.escape-string-h
  [] -> ""
  [C | Cs] -> (@s (n->string 92) (n->string 92) (lsp.escape-string-h Cs))
      where (= (string->n C) 92)
  [C | Cs] -> (@s (n->string 92) C (lsp.escape-string-h Cs))
      where (= (string->n C) 34)
  [C | Cs] -> (@s C (lsp.escape-string-h Cs)))

(define lsp.concat-strings
  [] -> ""
  [S] -> S
  [S | Ss] -> (@s S " " (lsp.concat-strings Ss)))

\\ ============================== helpers ==================================

(define lsp.manifest-get
  _ [] -> []
  Key [[K | Vals] | _] -> Vals  where (= Key K)
  Key [_ | Rows] -> (lsp.manifest-get Key Rows))

(define lsp.defun?
  [defun | _] -> true
  _ -> false)

\\ The compiler emits direct calls only for functions whose arity it knows;
\\ otherwise it falls back to a runtime (fn ...) lookup, which fails in the
\\ target because nothing ever stores user arities there.  So register every
\\ user defun's arity in this (host) binary before compiling anything -
\\ across all user files first, to allow cross-file references.
(define lsp.register-arities
  [] -> done
  [[defun F Args | _] | Forms] -> (do (shen.store-arity F (lsp.len Args))
                                      (lsp.register-arities Forms))
  [_ | Forms] -> (lsp.register-arities Forms))

\\ stlib's length is not always materialised in the host runtime.
(define lsp.len
  [] -> 0
  [_ | Xs] -> (+ 1 (lsp.len Xs)))

\\ "fib.kl" -> "fib"
(define lsp.strip-kl
  S -> (lsp.strip-kl-h S ""))

(define lsp.strip-kl-h
  ".kl" Acc -> Acc
  "" Acc -> Acc
  (@s C Cs) Acc -> (lsp.strip-kl-h Cs (cn Acc C)))

(define lsp.write-lsp
  File Strings -> (let Sink  (open File out)
                       Top   (pr (make-string "(in-package :shen)~%~%") Sink)
                       Write (ygg.mapc (/. S (pr (make-string "~A~%~%" S) Sink))
                                       Strings)
                       Close (close Sink)
                       File))

\\ ====================== compiling KL to Lisp =============================

(define lsp.compile-kernel
  Dir -> (let Forms  (read-file (@s Dir "/kernel.kl"))
              FlagOn (set shen-cl.*compiling-shen-sources* true)
              Lisp   (map (/. F (shen-cl.kl->lisp F)) Forms)
              FlagOff (set shen-cl.*compiling-shen-sources* false)
              (lsp.write-lsp (@s Dir "/kernel.lsp")
                              (map (/. L (lsp.sexp->string L)) Lisp))))

(define lsp.compile-user
  Dir File -> (let Name   (lsp.strip-kl File)
                   Forms  (read-file (@s Dir "/" File))
                   Defuns (ygg.filter (/. F (lsp.defun? F)) Forms)
                   Tops   (ygg.filter (/. F (not (lsp.defun? F))) Forms)
                   CDefs  (map (/. F (shen-cl.kl->lisp F)) Defuns)
                   CTops  (map (/. F (shen-cl.kl->lisp F)) Tops)
                   Main   [(shen-cl.cl defun)
                           (intern (@s "yggdrasil.toplevel-" Name)) []
                           | CTops]
                   Strs   (map (/. L (lsp.sexp->string L))
                               (append CDefs [Main]))
                   Write  (lsp.write-lsp (@s Dir "/" Name ".lsp") Strs)
                   Name))

\\ ====================== staging the build dir ============================

(define lsp.copy-runtime
  Dir -> (do (ygg.mapc (/. F (ygg.copy-file (@s (value lsp.*shen-cl*) "src/" F)
                                            (@s Dir "/" F)))
                       (value lsp.*runtime-files*))
             (ygg.copy-file (value lsp.*driver*) (@s Dir "/driver.lsp"))))

(define lsp.write-config
  Dir Names Exe ->
    (lsp.write-lsp (@s Dir "/yggdrasil.config.lsp")
      (map (/. L (lsp.sexp->string L))
           [[(shen-cl.cl defparameter) (shen-cl.cl yggdrasil-user-names)
             [(shen-cl.cl quote) Names]]
            [(shen-cl.cl defparameter) (shen-cl.cl yggdrasil-exe) Exe]])))

(define lsp.warn-needs-eval
  [true] -> (output "yggdrasil/lisp: note: manifest says needs-eval=true.  The KL->Lisp compiler is not packaged, so a runtime call to eval-kl would fail; the fixtures never call it.~%")
  _ -> done)

\\ ============================ entry point ================================

(define lsp.build
  Dir Exe -> (let Manifest (read-file (@s Dir "/yggdrasil.manifest"))
                  Users    (lsp.manifest-get "user" Manifest)
                  Reg      (ygg.mapc (/. F (lsp.register-arities
                                            (read-file (@s Dir "/" F))))
                                     Users)
                  Kernel   (lsp.compile-kernel Dir)
                  Names    (map (/. F (lsp.compile-user Dir F)) Users)
                  Copy     (lsp.copy-runtime Dir)
                  Config   (lsp.write-config Dir Names Exe)
                  Warn     (lsp.warn-needs-eval (lsp.manifest-get "needs-eval" Manifest))
                  (output "yggdrasil/lisp: staged ~A (users: ~A) -> ~A~%"
                          Dir Names Exe)))
