;; Factorial — recursion with multiplication
;; Tests: defn, fn, if, <=, *, recursive call
(defn factorial
  (n)
    (if (<= n 1)
        1
        (* n (factorial (- n 1))))))
