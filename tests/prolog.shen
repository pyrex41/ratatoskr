\\ Fixture: drags the Prolog engine into the footprint.
(defprolog likes
  peter chocolate <--;
  mary X <-- (likes peter X);)

(output "mary likes chocolate: ~A~%" (prolog? (likes mary chocolate)))
