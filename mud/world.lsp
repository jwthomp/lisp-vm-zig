;; mud/world.lsp — demo world (sqhn-t97)
;;
;; Layout:
;;   South Gate ↔ Central Square → Watchtower (door locked without a key)
;;   South Gate ⇕ Crypt (hidden passage: down/up)
;; Each room has a unique description and one item lying in it.
;;
;; Imports engine + state + cmds, rebinds `move` with world rules
;; (the tower door lock), and provides take/use game logic.

(import mud/engine.lsp)
(import mud/state.lsp)
(import mud/cmds.lsp)

;; --- rooms ---------------------------------------------------------------

(def rooms (append
  (cons 'gate (cons (make_room 'gate
    "A weathered gate at the edge of town. Banners snap in the wind."
    (cons 'north (cons 'square (cons 'down (cons 'crypt nil))))) nil))
  (cons 'square (cons (make_room 'square
    "The old square, quiet tonight. A watchtower rises to the north."
    (cons 'south (cons 'gate (cons 'north (cons 'tower nil))))) nil))))

(def rooms (append rooms
  (cons 'tower (cons (make_room 'tower
    "A stone tower. The wooden door is barred from the outside."
    (cons 'south (cons 'square nil))) nil))))

(def rooms (append rooms
  (cons 'crypt (cons (make_room 'crypt
    "Cold air, old bones, and a passage leading back up to the gate."
    (cons 'up (cons 'gate nil))) nil))))

;; flat room→item map: ('room item ...)
(def room_items (append
  (cons 'gate (cons 'lantern nil))
  (cons 'square (cons 'key nil))
  (cons 'crypt (cons 'amulet nil))
  (cons 'tower (cons 'potion nil))))

;; (room_item room) → item lying in room, or nil
(defn room_item (room)
  (if (null? (member room room_items))
      nil
      (car (cdr (member room room_items)))))

;; (remove_item_entry room items) → items with room's entry removed
(defn remove_item_entry (room items)
  (if (null? items)
      nil
      (if (equal? (car items) room)
          (cddr items)
          (cons (car items) (remove_item_entry room (cdr items))))))

;; --- world rules ---------------------------------------------------------

;; (move dir) — engine move plus world rules: the tower door needs the key
(defn move (dir)
  (if (null? player)
      nil
      (let ((target (exit_target (get_room (player_pos player)) dir)))
        (if (null? target)
            nil
            (if (equal? target 'tower)
                (if (= (has_item 'key) 1)
                    (do
                      (def player (set_player_pos player target))
                      (get_room target))
                    (do
                      (println "The tower door is locked. A key would help.")
                      nil))
                (do
                  (def player (set_player_pos player target))
                  (get_room target)))))))

;; (take_cmd item) — pick up the item lying in the current room
(defn take_cmd (item)
  (if (null? item)
      (println "I don't know that item.")
      (let ((here (room_item (player_pos player))))
        (if (null? here)
            (println "There is nothing here to take.")
            (if (equal? here item)
                (do
                  (add_item item)
                  (def room_items (remove_item_entry (player_pos player) room_items))
                  (println (str-cat "You pick up the " (str item) "."))
                  1)
                (do
                  (println (str-cat "You can't take the " (str item) " here."))
                  0))))))

;; (use_cmd item) — use an item from the inventory
(defn use_cmd (item)
  (if (null? item)
      (println "Use what?")
      (if (equal? item 'potion)
          (if (= (has_item 'potion) 1)
              (do
                (drop_item 'potion)
                (def player (with_hp player
                  (if (> (player_hp player) 75) 100 (+ (player_hp player) 25))))
                (println "You feel healthier.")
                1)
              (do
                (println "You have no potion to drink.")
                0))
          (do
            (println "You can't use that.")
            0))))
