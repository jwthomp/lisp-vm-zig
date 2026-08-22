;; mud/engine.lsp — room engine (sqhn-yl0)
;;
;; Data model (pure Lisp lists; no hash tables in the VM):
;;   rooms  — global, flat list: ('gate <room> 'square <room> ...)
;;   room   — ('room name desc exits)
;;   exits  — flat list: ('north 'square 'south 'gate ...)
;;   player — global: ('player name hp pos inv), see state.lsp
;;
;; `rooms` and `player` are bound by world.lsp / mudeus.lsp.

(defn cddr (l)
  (if (null? l)
      nil
      (let ((d (cdr l)))
        (if (null? d) nil (cdr d)))))

;; (make_room name desc exits) → room record
(defn make_room (name desc exits)
  (cons 'room (cons name (cons desc (cons exits nil)))))

(defn room_name (r) (car (cdr r)))
(defn room_desc (r) (car (cdr (cdr r))))
(defn room_exits (r) (car (cdr (cdr (cdr r)))))

;; (get_room name) → room record or nil
(defn get_room (name)
  (if (null? (member name rooms))
      nil
      (car (cdr (member name rooms)))))

;; (exit_target room dir) → target room name or nil
(defn exit_target (room dir)
  (if (null? room)
      nil
      (let ((exits (room_exits room)))
        (if (null? (member dir exits))
            nil
            (car (cdr (member dir exits)))))))

;; (exit_list exits) → "north, south" (or "none")
(defn exit_list (exits)
  (if (null? exits)
      "none"
      (if (null? (cddr exits))
          (str (car exits))
          (str-cat (str (car exits)) ", " (exit_list (cddr exits))))))

;; (describe_room room) → concatenated name + description + exit list
(defn describe_room (room)
  (if (null? room)
      "unknown room"
      (str-cat
        (room_name room)
        " — "
        (room_desc room)
        " [exits: "
        (exit_list (room_exits room))
        "]")))

(defn make_player (name hp pos inv)
  (cons 'player (cons name (cons hp (cons pos (cons inv nil))))))

(defn player_name (p) (car (cdr p)))
(defn player_hp (p) (car (cdr (cdr p))))
(defn player_pos (p) (car (cdr (cdr (cdr p)))))
(defn player_inv (p) (car (cdr (cdr (cdr (cdr p))))))

(defn set_player_pos (p pos)
  (make_player (player_name p) (player_hp p) pos (player_inv p)))

;; (move dir) — validate the exit from the player's current room,
;; update the global player position, return the new room record (nil if no exit).
(defn move (dir)
  (if (null? player)
      nil
      (let ((target (exit_target (get_room (player_pos player)) dir)))
        (if (null? target)
            nil
            (do
              (def player (set_player_pos player target))
              (get_room target))))))
