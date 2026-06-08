;; Max of list — list traversal with let
;; Tests: defn, fn, if, null?, cdr, car, >, let
(defn max-list
  (fn (lst)
    (if (null? (cdr lst))
        (car lst)
        (let ((rest-max (max-list (cdr lst))))
          (if (> (car lst) rest-max)
              (car lst)
              rest-max)))))
