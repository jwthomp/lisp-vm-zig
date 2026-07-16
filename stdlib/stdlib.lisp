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

;; (last lst) returns the last element of a list
(defn last
  (lst)
  (if (null? (cdr lst))
      (car lst)
      (last (cdr lst))))

;; (butlast lst) returns the list without the last element
(defn butlast
  (lst)
  (if (null? (cdr lst))
      nil
      (cons (car lst) (butlast (cdr lst)))))

;; (concat lst1 lst2 ...) — concatenate lists (via append built-in, recursive)
(defn concat
  (list1 list2)
  (if (null? list1)
      list2
      (cons (car list1) (concat (cdr list1) list2))))

;; (take n lst) returns first n elements
(defn take
  (n lst)
  (if (or (null? lst) (= n 0))
      nil
      (cons (car lst) (take (- n 1) (cdr lst)))))

;; (drop n lst) returns list without first n elements
(defn drop
  (n lst)
  (if (= n 0)
      lst
      (drop (- n 1) (cdr lst))))

;; (not x) — returns 1 if x is nil, 0 otherwise
(defn not
  (x)
  (if (null? x) 1 0))

;; (atom? x) — returns 1 if x is not a list (nil is an atom)
(defn atom?
  (x)
  (if (list? x)
      0
      1))

;; (sum lst) — sum all numbers in a list
(defn sum
  (lst)
  (if (null? lst)
      0
      (+ (car lst) (sum (cdr lst)))))

;; (product lst) — product of all numbers in a list
(defn product
  (lst)
  (if (null? lst)
      1
      (* (car lst) (product (cdr lst)))))

;; (every? pred lst) — returns 1 if pred returns true for all elements
(defn every?
  (pred lst)
  (if (null? lst)
      1
      (if (= (call pred (car lst)) 0)
          0
          (every? pred (cdr lst)))))

;; (some? pred lst) — returns 1 if pred returns true for any element
(defn some?
  (pred lst)
  (if (null? lst)
      0
      (if (= (call pred (car lst)) 1)
          1
          (some? pred (cdr lst)))))

;; (flatten lst) — recursively flatten nested lists
(defn flatten
  (lst)
  (if (null? lst)
      nil
      (if (atom? (car lst))
          (cons (car lst) (flatten (cdr lst)))
          (concat (flatten (car lst)) (flatten (cdr lst))))))
