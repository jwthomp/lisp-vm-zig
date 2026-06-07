;; Standard Library — core functions implemented in pure Lisp
;; All functions use only: cons, car, cdr, null?, number?, symbol?, list?,
;;                        =, <, >, +, -, *, /, let, if, fn, do

;; --- List Manipulation ---

;; (append x y) — concatenate two lists
(defn append-lst
  (fn (x y)
    (if (null? x)
        y
        (cons (car x) (append-lst (cdr x) y)))))

;; (reverse x) — reverse a list
(defn reverse-lst
  (fn (x)
    (let ((acc nil))
      (if (null? x)
          acc
          (do
            (set-acc! acc (cons (car x) acc))
            (reverse-lst (cdr x)))))))

;; (member x lst) — return sublist starting at first match, nil if not found
(defn member-lst
  (fn (x lst)
    (if (null? lst)
        nil
        (if (= x (car lst))
            lst
            (member-lst x (cdr lst))))))

;; (assoc key alist) — association list lookup
(defn assoc-lst
  (fn (key alist)
    (if (null? alist)
        nil
        (if (= key (car (car alist)))
            (car alist)
            (assoc-lst key (cdr alist))))))

;; (take n lst) — take first n elements
(defn take
  (fn (n lst)
    (if (or (= n 0) (null? lst))
        nil
        (cons (car lst) (take (- n 1) (cdr lst))))))

;; (drop n lst) — drop first n elements
(defn drop
  (fn (n lst)
    (if (or (= n 0) (null? lst))
        lst
        (drop (- n 1) (cdr lst)))))

;; (flatten lst) — recursively flatten nested lists
(defn flatten
  (fn (lst)
    (if (null? lst)
        nil
        (if (not (list? (car lst)))
            (cons (car lst) (flatten (cdr lst)))
            (append-lst (flatten (car lst)) (flatten (cdr lst)))))))

;; --- Predicates ---

;; (every? pred lst) — true if pred holds for all elements
(defn every?
  (fn (pred lst)
    (if (null? lst)
        1
        (if (= 0 (pred (car lst)))
            0
            (every? pred (cdr lst))))))

;; (some? pred lst) — true if pred holds for any element
(defn some?
  (fn (pred lst)
    (if (null? lst)
        0
        (if (= 1 (pred (car lst)))
            1
            (some? pred (cdr lst))))))

;; --- Utility ---

;; (null? x) — alias (already builtin)
;; (not x) — logical not
(defn not
  (fn (x)
    (if (null? x)
        1
        0)))

;; (atom? x) — true if not a list
(defn atom?
  (fn (x)
    (if (list? x)
        0
        1)))

;; (length lst) — length of list (alias, builtin exists)
;; (sum lst) — sum all numbers in list
(defn sum
  (fn (lst)
    (if (null? lst)
        0
        (+ (car lst) (sum (cdr lst))))))

;; (product lst) — product of all numbers in list
(defn product
  (fn (lst)
    (if (null? lst)
        1
        (* (car lst) (product (cdr lst))))))
