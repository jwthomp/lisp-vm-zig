;; Let scoping — nested bindings
;; Tests: let, nested let, shadowing, variable visibility
(defn test-shadowing
  (fn ()
    (let ((x 10))
      (let ((x 20))
        (let ((y 30))
          (+ x y))))))

(defn test-visibility
  (fn ()
    (let ((a 1)
          (b (+ a 10)))
      b)))
