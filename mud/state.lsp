;; mud/state.lsp — player state & bookkeeping (sqhn-eri)
;; Depends on mud/engine.lsp for the player record shape + accessors.
;;
;; Player record: ('player name hp pos inv equip)
;;   inv/equip are flat lists of item symbols.

(import mud/engine.lsp)

(def start-room 'gate)
(def max-hp 100)

;; (create_player name) → fresh player record at the start room
(defn create_player (name)
  (make_player name max-hp start-room nil nil))

;; Record updaters — return new records, never mutate
(defn with_inv (p inv)
  (make_player (player_name p) (player_hp p) (player_pos p) inv (player_equip p)))

(defn with_equip (p equip)
  (make_player (player_name p) (player_hp p) (player_pos p) (player_inv p) equip))

(defn with_hp (p hp)
  (make_player (player_name p) hp (player_pos p) (player_inv p) (player_equip p)))

;; (without lst item) → lst with first occurrence of item removed
(defn without (lst item)
  (if (null? lst)
      nil
      (if (= (equal? (car lst) item) 1)
          (cdr lst)
          (cons (car lst) (without (cdr lst) item)))))

;; (has_item item) → 1 if the global player's inventory holds item
(defn has_item (item)
  (if (null? (member item (player_inv player))) 0 1))

;; (add_item item) → add item to the global player's inventory
(defn add_item (item)
  (def player (with_inv player (cons item (player_inv player))))
  item)

;; (drop_item item) → remove item from the global player's inventory
(defn drop_item (item)
  (def player (with_inv player (without (player_inv player) item)))
  item)

;; (equip item) → move item from inventory to equipment; 1 on success, 0 if not owned
(defn equip (item)
  (if (= (has_item item) 1)
      (do
        (def player (with_equip
                       (with_inv player (without (player_inv player) item))
                       (cons item (player_equip player))))
        1)
      0))

;; (unequip item) → move item from equipment back to inventory
(defn unequip (item)
  (if (null? (member item (player_equip player)))
      0
      (do
        (def player (with_inv
                       (with_equip player (without (player_equip player) item))
                       (cons item (player_inv player))))
        1)))

;; (apply_damage amount) → reduce HP by amount (floors at 0), returns new HP
(defn apply_damage (amount)
  (let ((new-hp (- (player_hp player) amount)))
    (def player (with_hp player (if (< new-hp 0) 0 new-hp)))
    (player_hp player)))

;; (save_state) → plain data structure: (state name hp pos inv equip)
(defn save_state ()
  (cons 'state
        (cons (player_name player)
              (cons (player_hp player)
                    (cons (player_pos player)
                          (cons (player_inv player)
                                (cons (player_equip player) nil)))))))

;; (load_state s) → restore the global player from a save_state structure
(defn load_state (s)
  (def player (make_player
                (car (cdr s))
                (car (cdr (cdr s)))
                (car (cdr (cdr (cdr s))))
                (car (cdr (cdr (cdr (cdr s)))))
                (car (cdr (cdr (cdr (cdr (cdr s))))))))
  1)
