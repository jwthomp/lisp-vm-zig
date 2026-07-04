;; Standard Library for the Lisp VM
;; Contains high-level functions built on core primitives

;; (list 1 2 3) creates a list (1 2 3)
(defn list
  (args)
  (if (null? args)
      nil
      (cons (car args) (list (cdr args)))))

;; (first lst) returns the first element of a list
(defn first
  (lst)
  (car lst))

;; (second lst) returns the second element of a list
(defn second
  (lst)
  (car (cdr lst)))

;; (third lst) returns the third element of a list
(defn third
  (lst)
  (car (cdr (cdr lst))))
