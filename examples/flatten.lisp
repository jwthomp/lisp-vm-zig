;; Flatten nested lists
;; Tests: defn, fn, if, null?, list?, car, cdr, cons, recursive, conditional
(defn flatten
  (fn (lst)
    (if (null? lst)
        nil
        (if (list? (car lst))
            (append-lst (flatten (car lst)) (flatten (cdr lst)))
            (cons (car lst) (flatten (cdr lst)))))))
