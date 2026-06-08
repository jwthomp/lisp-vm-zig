;; Fibonacci — classic recursion
;; Tests: defn, fn, if, <=, +, -, recursion
(defn fib
  (fn (n)
    (if (<= n 1)
        n
        (+ (fib (- n 1)) (fib (- n 2))))))
