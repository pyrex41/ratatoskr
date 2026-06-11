;;; Yggdrasil 2.0 - stage-2 Common Lisp driver (SBCL / CLISP / ECL).
;;;
;;; Run with the staged directory as the working directory:
;;;     sbcl  --non-interactive --no-userinit --no-sysinit --load driver.lsp
;;;     clisp -norc -q driver.lsp
;;;     ecl   --norc --load driver.lsp
;;;
;;; Expects alongside this file (staged by builders/lisp/build.shen):
;;;     package.lsp primitives.lsp native.lsp shen-utils.lsp overwrite.lsp
;;;     kernel.lsp <user>.lsp yggdrasil.config.lsp
;;;
;;; Mirrors the minimal subset of shen-cl's boot.lsp:
;;;     package -> primitives -> native -> shen-utils -> kernel ->
;;;     overwrite -> (shen.initialise) -> user modules -> executable.
;;;
;;; SBCL and CLISP capture all of that in a saved image whose toplevel runs
;;; the user code.  ECL cannot dump images: it compiles every module to an
;;; object file and links a real executable with c:build-program, so the
;;; load->overwrite->initialise->user sequence runs at program startup
;;; instead (see the epilogue).  shen-cl's runtime .lsp sources and the
;;; kl->lisp output are implementation-portable; only this driver varies.
;;; CCL is unsupported here: no native Apple Silicon build exists.

(in-package :cl-user)

(setq *load-verbose* nil
      *load-print* nil
      *compile-verbose* nil
      *compile-print* nil)

#+clisp (setq custom:*compile-warnings* nil
              custom:*suppress-check-redefinition* t)
#+ecl   (require 'cmp)
#+ecl   (setq c::*suppress-compiler-warnings* t
              c::*suppress-compiler-notes* t)

(load "package.lsp")

(in-package :shen)

(proclaim '(optimize (debug 0) (speed 3) (safety 3)))
#+sbcl (declaim (sb-ext:muffle-conditions warning sb-ext:compiler-note))
#+sbcl (setf sb-ext:*muffled-warnings* t)

;; Build parameters: yggdrasil-user-names (user module base names, in
;; manifest order) and yggdrasil-exe (path for the saved executable).
(load "yggdrasil.config.lsp")

(defun yggdrasil-exit (code)
  #+sbcl  (sb-ext:exit :code code :abort (/= code 0))
  #+clisp (ext:exit code)
  #+ecl   (si:quit code))

;; overwrite.lsp patches kernel functions with platform-native versions and
;; must apply after the kernel (boot.lsp order), before (shen.initialise).
;; A shaken kernel omits functions the program never reaches, and a few
;; overwrite forms grab their patch target at load time (fdefinition / #'),
;; so eval form by form and skip patches whose kernel target is absent.
;; A skipped patch is sound exactly when its target lies outside the
;; shaken footprint.
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

;; shen-cl's native pr override is #+(or ccl sbcl); elsewhere the kernel's
;; KL pr runs and needs the optional stream primitives (the manifest's
;; primitive-optional= pair plus the char-stream predicates).  Installed
;; only when missing, after overwrite.lsp has had its chance.
(defun yggdrasil-install-stream-fallbacks ()
  (unless (fboundp '|shen.char-stoutput?|)
    (setf (symbol-function '|shen.char-stoutput?|)
          (lambda (s)
            (if (subtypep (stream-element-type s) 'character) '|true| '|false|))))
  (unless (fboundp '|shen.char-stinput?|)
    (setf (symbol-function '|shen.char-stinput?|)
          (lambda (s)
            (if (subtypep (stream-element-type s) 'character) '|true| '|false|))))
  (unless (fboundp '|shen.write-string|)
    (setf (symbol-function '|shen.write-string|)
          (lambda (x s)
            (write-string x s)
            (force-output s)
            x)))
  (unless (fboundp '|shen.read-unit-string|)
    (setf (symbol-function '|shen.read-unit-string|)
          (lambda (s)
            (let ((c (read-char s nil nil)))
              (if c (string c) ""))))))

;; Run each user module's |yggdrasil.toplevel-<name>| (its toplevel
;; non-defun forms, in source order), in manifest order; then exit.
(defun yggdrasil-toplevel ()
  (let ((*package* (find-package :shen)))
    ;; Streams captured at image-save time may be dead on restart (CLISP
    ;; keeps the closed object; SBCL transparently revives fd streams).
    (setq |*stoutput*| *standard-output*
          |*stinput*|  *standard-input*)
    (when (boundp '|*sterror*|)
      (setq |*sterror*| *error-output*))
    (handler-case
        (progn
          (dolist (name yggdrasil-user-names)
            (funcall
             (or (find-symbol (concatenate 'string "yggdrasil.toplevel-" name)
                              :shen)
                 (error "yggdrasil: missing toplevel function for ~A" name))))
          (force-output |*stoutput*|)
          (yggdrasil-exit 0))
      (error (c)
        (format *error-output* "~&yggdrasil: uncaught error: ~A~%" c)
        (force-output *error-output*)
        (yggdrasil-exit 1)))))

#-ecl
(progn
  (defun yggdrasil-import (file)
    (load (compile-file file :verbose nil :print nil)))

  (yggdrasil-import "primitives.lsp")
  (yggdrasil-import "native.lsp")
  (yggdrasil-import "shen-utils.lsp")
  (yggdrasil-import "kernel.lsp")
  (yggdrasil-load-overwrite "overwrite.lsp")
  (yggdrasil-install-stream-fallbacks)

  ;; Builder contract: load kernel, call (shen.initialise), load user code.
  ;; Image-based implementations initialise at build time and capture the
  ;; result in the image, exactly as shen-cl's own boot does.
  (|shen.initialise|)

  (dolist (name yggdrasil-user-names)
    (yggdrasil-import (concatenate 'string name ".lsp"))))

#+sbcl
(sb-ext:save-lisp-and-die yggdrasil-exe
  :executable t
  :save-runtime-options t
  :toplevel #'yggdrasil-toplevel)

#+clisp
(progn
  (ext:saveinitmem yggdrasil-exe
                   :executable t
                   :quiet t
                   :norc t
                   :init-function #'yggdrasil-toplevel)
  (ext:exit 0))

;; ECL: compile every module to an object file and link an executable.
;; The epilogue replays the boot order at startup: overwrite patches
;; (interpreted form-by-form for the skip-on-missing-target behavior),
;; then initialise, then the user toplevels.  overwrite.lsp and
;; yggdrasil.config.lsp therefore ship inside the binary's directory is
;; NOT needed - both are baked in: the config was already loaded above
;; (its defparameters compile into the prologue object), and the
;; overwrite source text is embedded as a literal.
#+ecl
(let* ((modules (append '("package" "yggdrasil.config"
                          "primitives" "native" "shen-utils" "kernel")
                        yggdrasil-user-names))
       (overwrite-text
        (with-open-file (in "overwrite.lsp")
          (let ((s (make-string (file-length in))))
            (subseq s 0 (read-sequence s in)))))
       ;; The epilogue must be self-contained: build-program links only the
       ;; compiled modules plus this form, so nothing defined in THIS driver
       ;; process (which exits after linking) can be referenced from it.
       (epilogue
        `(progn
           (in-package :shen)
           (with-input-from-string (in ,overwrite-text)
             (loop with eof = (list :eof)
                   for form = (read in nil eof)
                   until (eq form eof)
                   do (handler-case (eval form)
                        (error (c) (declare (ignore c)) nil))))
           (unless (fboundp '|shen.char-stoutput?|)
             (setf (symbol-function '|shen.char-stoutput?|)
                   (lambda (s) (if (subtypep (stream-element-type s) 'character) '|true| '|false|))))
           (unless (fboundp '|shen.char-stinput?|)
             (setf (symbol-function '|shen.char-stinput?|)
                   (lambda (s) (if (subtypep (stream-element-type s) 'character) '|true| '|false|))))
           (unless (fboundp '|shen.write-string|)
             (setf (symbol-function '|shen.write-string|)
                   (lambda (x s) (write-string x s) (force-output s) x)))
           (unless (fboundp '|shen.read-unit-string|)
             (setf (symbol-function '|shen.read-unit-string|)
                   (lambda (s) (let ((c (read-char s nil nil))) (if c (string c) "")))))
           (|shen.initialise|)
           (handler-case
               (progn
                 (dolist (name ',yggdrasil-user-names)
                   (funcall
                    (or (find-symbol (concatenate 'string "yggdrasil.toplevel-" name) :shen)
                        (error "yggdrasil: missing toplevel function for ~A" name))))
                 (force-output |*stoutput*|)
                 (si:quit 0))
             (error (c)
               (format *error-output* "~&yggdrasil: uncaught error: ~A~%" c)
               (si:quit 1)))))
       (objects
        (mapcar (lambda (name)
                  (compile-file (concatenate 'string name ".lsp")
                                :system-p t :verbose nil :print nil))
                modules)))
  (c:build-program yggdrasil-exe
                   :lisp-files objects
                   :epilogue-code epilogue)
  (si:quit 0))
