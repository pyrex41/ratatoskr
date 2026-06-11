\\                                    Package for Generating Common Lisp
\\                                    (c) Mark Tarver 2023, 3 clause BSD

\\ No package wrapper (41.1 has no stlib package); see yggdrasil.shen.

(put "lsp" compiler (fn lisp-compiler))

\\ shen-cl 41.1 names its KL->Lisp compiler shen-cl.kl->lisp
\\ (src/compiler.shen); earlier shen-cl releases used cl.kl-to-lisp.
(define lisp-compiler
  [defun fail |_] -> "(DEFUN fail () 'shen.fail!)"
  X -> (make-string "~R~%" ((foreign shen-cl.kl->lisp) X)))

(put "lsp" boilerplate "(SETF (READTABLE-CASE *READTABLE*) :PRESERVE)

(PROCLAIM '(OPTIMIZE (DEBUG 0) (SPEED 3) (SAFETY 3)))

#+SBCL
(DECLAIM (SB-EXT:MUFFLE-CONDITIONS SB-EXT:COMPILER-NOTE)) 

#+SBCL
(SETF SB-EXT:*MUFFLED-WARNINGS* T) 

#+CLISP
(SETQ *LOAD-VERBOSE* NIL
      *COMPILE-VERBOSE* NIL
      CUSTOM:*COMPILE-WARNINGS* NIL)
      
(DEFUN cl.wrapper (V14179)
  (COND ((EQ 'true V14179) T) 
        ((EQ 'false V14179) NIL)
        (T (ERROR c#34;boolean expectedc#34;))))      
        
(DEFUN set (X Y) (SET X Y))        

(SETQ *language* c#34;Common Lispc#34;
      *implementation* (LISP-IMPLEMENTATION-TYPE)
      *porters* c#34;Mark Tarverc#34;
      *port* 3.2
      *os* (SOFTWARE-TYPE))

#+SBCL      
(SETQ *release* c#34;2.0.0c#34;)      

#+CLISP
(SETQ *release* c#34;2.49c#34;)")
      
(put "lsp" driver (fn lispdriver))

(define lispdriver
  BoilerFile PrimFiles GlobalFile KernelFile UserFiles 
  -> (make-string "(LOAD ~S)~%(MAPC 'LOAD (LIST ~A))~%(LOAD ~S)~%(LOAD ~S) ~%(MAPC 'LOAD (LIST ~A))"
                       BoilerFile (files PrimFiles) GlobalFile KernelFile (files UserFiles)))
                       
(define files
  [] -> ""
  [File | Files] -> (@s (str File) " " (files Files)))                       
      
(put if "lsp" ["Primitives/CL/if.lsp"])
(put and "lsp" ["Primitives/CL/and.lsp"])
(put or "lsp" ["Primitives/CL/or.lsp"]) 
(put cond "lsp" [])
(put intern "lsp" ["Primitives/CL/intern.lsp"])
(put pos "lsp" ["Primitives/CL/pos.lsp"])
(put tlstr "lsp" ["Primitives/CL/tlstr.lsp"])
(put cn "lsp" ["Primitives/CL/cn.lsp"])
(put str "lsp" ["Primitives/CL/str.lsp"])
(put string? "lsp" ["Primitives/CL/isstring.lsp"])
(put n->string "lsp" ["Primitives/CL/n-to-string.lsp"])
(put string->n "lsp" ["Primitives/CL/string-to-n.lsp"])
(put set "lsp" ["Primitives/CL/set.lsp"])
(put value "lsp" ["Primitives/CL/value.lsp"])
(put simple-error "lsp" ["Primitives/CL/simple-error.lsp"])
(put trap-error "lsp" ["Primitives/CL/trap-error.lsp"])
(put error-to-string "lsp" ["Primitives/CL/error-to-string.lsp"])
(put cons "lsp" ["Primitives/CL/cons.lsp"])
(put hd "lsp" ["Primitives/CL/hd.lsp"])
(put tl "lsp" ["Primitives/CL/tl.lsp"])
(put cons? "lsp" ["Primitives/CL/iscons.lsp"])
(put absvector "lsp" ["Primitives/CL/absvector.lsp"])
(put address-> "lsp" ["Primitives/CL/address-send.lsp"])
(put <-address "lsp" ["Primitives/CL/address-get.lsp"])
(put absvector? "lsp" ["Primitives/CL/isabsvector.lsp"])
(put write-byte "lsp" ["Primitives/CL/write-byte.lsp"])
(put read-byte "lsp" ["Primitives/CL/read-byte.lsp"])
(put open "lsp" ["Primitives/CL/open.lsp"])
(put close "lsp" ["Primitives/CL/close.lsp"])
\\ prolog-memory and vector are kernel-defined in 41.1, no longer primitives.
(put + "lsp" ["Primitives/CL/arith.lsp"])
(put - "lsp" ["Primitives/CL/arith.lsp"])
(put * "lsp" ["Primitives/CL/arith.lsp"])
(put / "lsp" ["Primitives/CL/arith.lsp"])
(put > "lsp" ["Primitives/CL/arith.lsp"])
(put < "lsp" ["Primitives/CL/arith.lsp"]) 
(put >= "lsp" ["Primitives/CL/arith.lsp"])
(put <= "lsp" ["Primitives/CL/arith.lsp"])
(put number? "lsp" ["Primitives/CL/arith.lsp"])
(put defun "lsp" [])
(put lambda "lsp" ["Primitives/CL/lambda.lsp"])
(put let "lsp" ["Primitives/CL/let.lsp"])
(put = "lsp" ["Primitives/CL/equal.lsp"])
(put eval-kl "lsp" ["Primitives/CL/eval-kl.lsp"])
(put freeze "lsp" ["Primitives/CL/freeze.lsp"])
(put type "lsp" ["Primitives/CL/type.lsp"])
(put get-time "lsp" ["Primitives/CL/get-time.lsp"])
(put shen.char-stinput? "lsp" ["Primitives/CL/char-stinput.lsp"])
(put shen.char-stoutput? "lsp" ["Primitives/CL/char-stoutput.lsp"])
(put shen.write-string "lsp" ["Primitives/CL/write-string.lsp"])
(put shen.read-unit-string "lsp" ["Primitives/CL/read-unit-string.lsp"])
(put *stoutput* "lsp" ["Primitives/CL/stoutput.lsp"])
(put *stinput* "lsp"  ["Primitives/CL/stinput.lsp"])