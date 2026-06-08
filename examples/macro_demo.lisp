;; Macro demo — when/unless pattern
;; Tests: defmacro, fn, list?, car, cdr, if, do, macro expansion
(defmacro unless
  (fn (pred . body)
    (list 'if (list 'not pred) (cons 'do body))))

(defmacro when
  (fn (pred . body)
    (list 'if pred (cons 'do body))))
