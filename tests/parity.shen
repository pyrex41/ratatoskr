\\ Fixture: behavioural parity gate (GitHub issue #8).
\\
\\ Exercises content-addressed memoisation -- the hash / interning /
\\ iteration-order axis where byte-identical KL can still EXECUTE differently
\\ per target (this is the failure shape shen-cas hit on shen-rust). A memo is
\\ keyed by (hash Term ...); the printed value is a pure function of the term,
\\ so a correct implementation is deterministic (the golden is stable) while a
\\ host whose hashing/interning misbehaves returns stale/wrong cached values
\\ and diverges.
\\
\\ Parity-fixture convention: print two IDENTICAL passes (the same work run
\\ twice in one process) separated by a line that is exactly "===". The parity
\\ gate diffs the two passes to catch in-process boot-order/state nondeterminism
\\ (shen-cas#5), each artifact against itself across two boots, and every target
\\ against the reference.  Stays non-eval so it shakes to the small slice.

\\ A tiny content-addressed memo: a global assoc list of [HashKey Value].
(set parity-memo [])

(define memo-lookup
  _ [] -> parity-unset
  K [[K V] | _] -> V
  K [_ | Rest] -> (memo-lookup K Rest))

(define memo-store
  K V -> (do (set parity-memo [[K V] | (value parity-memo)]) V))

\\ Content hash of the whole term (explode handles structured terms).
(define key
  Term -> (hash Term 1024))

\\ Pure work we memoise: a deterministic checksum of the term's shape.
(define work
  [] -> 0
  [H | T] -> (+ (+ 1 (work H)) (work T))
  _ -> 1)

(define demand
  Term -> (let K (key Term)
            (let Hit (memo-lookup K (value parity-memo))
              (if (= Hit parity-unset)
                  (memo-store K (work Term))
                  Hit))))

(define show
  Term -> (output "~A => ~A~%" Term (demand Term)))

(define pass
  -> (do (show [a b c])
         (show [x [y z] w])
         (show [])
         (show [a [b [c [d]]]])
         (show [a b c])))

(define main
  -> (do (set parity-memo [])
         (pass)
         (output "===~%")
         (pass)))

(main)
