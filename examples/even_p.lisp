;; Even? predicate — arithmetic check
;; Tests: defn, fn, =, rem
(defn even?
  (fn (n)
    (= 0 (rem n 2))))
