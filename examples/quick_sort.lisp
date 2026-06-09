;; Quick sort — advanced recursion with list ops
;; Tests: defn, fn, if, null?, car, cdr, cons, >, append, let
(defn quicksort
  (lst)
    (if (null? (cdr lst))
        lst
        (let ((pivot (car lst))
              (rest (cdr lst)))
          (quicksort-help pivot rest)))))

(defn quicksort-help
  (pivot rest)
    (let ((smaller (filter-smaller pivot rest))
          (larger (filter-larger pivot rest)))
      (append-lst (quicksort smaller)
                  (cons pivot (quicksort larger))))))

(defn filter-smaller
  (pivot lst)
    (if (null? lst)
        nil
        (if (< (car lst) pivot)
            (cons (car lst) (filter-smaller pivot (cdr lst)))
            (filter-smaller pivot (cdr lst))))))

(defn filter-larger
  (pivot lst)
    (if (null? lst)
        nil
        (if (>= (car lst) pivot)
            (cons (car lst) (filter-larger pivot (cdr lst)))
            (filter-larger pivot (cdr lst))))))

(defn append-lst
  (x y)
    (if (null? x)
        y
        (cons (car x) (append-lst (cdr x) y)))))
