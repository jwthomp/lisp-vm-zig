;; Map example — higher-order function with closure
;; Tests: defn, fn, if, null?, cons, car, cdr, closures
(defn my-map
  (fn (fn lst)
    (if (null? lst)
        nil
        (cons (fn (car lst)) (my-map fn (cdr lst))))))

(defn double
  (fn (x)
    (+ x x)))
