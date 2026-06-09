;; append using recursion
;; Tests: defn, fn, if, null?, cons, car, cdr, recursive call
(defn append-lst
  (x y)
    (if (null? x)
        y
        (cons (car x) (append-lst (cdr x) y)))))
