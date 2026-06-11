;;; Yggdrasil 2.0 - stage-2 SBCL driver.
;;;
;;; Run with the staged directory as the working directory:
;;;     sbcl --non-interactive --no-userinit --no-sysinit --load driver.lsp
;;;
;;; Expects alongside this file (staged by builders/lisp/build.shen):
;;;     package.lsp primitives.lsp native.lsp shen-utils.lsp overwrite.lsp
;;;     kernel.lsp <user>.lsp yggdrasil.config.lsp
;;;
;;; Mirrors the minimal subset of shen-cl's boot.lsp:
;;;     package -> primitives -> native -> shen-utils -> kernel ->
;;;     overwrite -> (shen.initialise) -> user modules -> save executable.

(in-package :cl-user)

(setq *load-verbose* nil
      *load-print* nil
      *compile-verbose* nil
      *compile-print* nil)

(load "package.lsp")

(in-package :shen)

(proclaim '(optimize (debug 0) (speed 3) (safety 3)))
(declaim (sb-ext:muffle-conditions warning sb-ext:compiler-note))
(setf sb-ext:*muffled-warnings* t)

;; Build parameters: yggdrasil-user-names (user module base names, in
;; manifest order) and yggdrasil-exe (path for the saved executable).
(load "yggdrasil.config.lsp")

(defun yggdrasil-import (file)
  (load (compile-file file :verbose nil :print nil)))

(yggdrasil-import "primitives.lsp")
(yggdrasil-import "native.lsp")
(yggdrasil-import "shen-utils.lsp")
(yggdrasil-import "kernel.lsp")

;; overwrite.lsp patches kernel functions with platform-native versions and
;; must load after the kernel (boot.lsp order), before (shen.initialise).
;; A shaken kernel omits functions the program never reaches, and a few
;; overwrite forms grab their patch target at load time (fdefinition / #'),
;; so load form by form and skip patches whose kernel target is absent.
;; Every skip is reported in the build log; a skipped patch is sound exactly
;; when its target lies outside the shaken footprint.
(defun yggdrasil-load-overwrite (file)
  (with-open-file (in file)
    (loop with eof = (list :eof)
          for form = (read in nil eof)
          until (eq form eof)
          do (handler-case (eval form)
               (error (c)
                 (format t "~&;; yggdrasil: skipped overwrite form (~{~S~^ ~} ...): ~A~%"
                         (if (consp form)
                             (subseq form 0 (min 2 (length form)))
                             (list form))
                         c))))))

(yggdrasil-load-overwrite "overwrite.lsp")

;; Builder contract: load kernel, call (shen.initialise), load user code.
;; Initialisation happens here at build time and is captured in the image,
;; exactly as shen-cl's own boot does.
(|shen.initialise|)

(dolist (name yggdrasil-user-names)
  (yggdrasil-import (concatenate 'string name ".lsp")))

;; Each user module compiles to its DEFUNs plus one
;; |yggdrasil.toplevel-<name>| function holding the module's toplevel
;; non-defun forms in source order; run them in manifest order, then exit.
(defun yggdrasil-toplevel ()
  (let ((*package* (find-package :shen)))
    (handler-case
        (progn
          (dolist (name yggdrasil-user-names)
            (funcall
             (or (find-symbol (concatenate 'string "yggdrasil.toplevel-" name)
                              :shen)
                 (error "yggdrasil: missing toplevel function for ~A" name))))
          (force-output |*stoutput*|)
          (sb-ext:exit :code 0))
      (error (c)
        (format *error-output* "~&yggdrasil: uncaught error: ~A~%" c)
        (force-output *error-output*)
        (sb-ext:exit :code 1 :abort t)))))

(sb-ext:save-lisp-and-die yggdrasil-exe
  :executable t
  :save-runtime-options t
  :toplevel #'yggdrasil-toplevel)
