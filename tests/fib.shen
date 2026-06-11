\\ Fixture: function definition, recursion, arithmetic.
(define fib
  0 -> 0
  1 -> 1
  N -> (+ (fib (- N 1)) (fib (- N 2))))

(output "fib 20 = ~A~%" (fib 20))
