;; Map example — higher-order function with closure
;; Tests: defn, if, null?, cons, car, cdr, closures
(defn my-map
  (f lst)
  (if (null? lst)
      nil
      (cons (f (car lst)) (my-map f (cdr lst)))))

(defn double
  (x)
  (+ x x))
