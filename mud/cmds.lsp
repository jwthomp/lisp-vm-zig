;; mud/cmds.lsp — command parsing & dispatch (sqhn-z5h)
;;
;; Parses raw input lines and routes them to game commands.
;; Depends on globals `rooms` and `player` (from engine.lsp / state.lsp).
;; (dispatch line) routes one input line; returns 'quit when the player quits,
;; which the bootstrap loop (mudeus.lsp) uses to stop — clean shutdown.

(import mud/engine.lsp)
(import mud/state.lsp)

;; --- input parsing -----------------------------------------------------

;; (find-space s i) → index of first " " at/after i, else nil
;; Note: substr's third arg is an exclusive end index, not a length
(defn find-space (s i)
  (if (= (str-len s) i)
      nil
      (if (str=? (substr s i (+ i 1)) " ")
          i
          (find-space s (+ i 1)))))

;; (parse-verb line) → text before first space (whole line if none)
(defn parse-verb (line)
  (let ((sp (find-space line 0)))
    (if (null? sp) line (substr line 0 sp))))

;; (parse-arg line) → text after first space, else nil
(defn parse-arg (line)
  (let ((sp (find-space line 0)))
    (if (null? sp) nil (substr line (+ sp 1)))))

;; ponytail: hard-coded direction table — add new directions here and in world.lsp
(defn dir-symbol (s)
  (if (str=? s "north") 'north
      (if (str=? s "south") 'south
          (if (str=? s "east") 'east
              (if (str=? s "west") 'west
                  (if (str=? s "up") 'up
                      (if (str=? s "down") 'down nil)))))))

;; --- commands ----------------------------------------------------------

;; (cmd-walk arg) — arg is the raw text after "walk", or nil
(defn cmd-walk (arg)
  (if (null? arg)
      (println "Walk where? (north, south, east, west, up, down)")
      (let ((dir (dir-symbol arg)))
        (if (null? dir)
            (println "No such direction.")
            (let ((room (move dir)))
              (if (null? room)
                  (println "You can't go that way.")
                  (do
                    (println (describe_room room))
                    (enter_effects room))))))))

(defn cmd-look ()
  (println (describe_room (get_room (player_pos player)))))

;; (enter_effects room) — notice an item lying in the room.
;; `room_items` is a global set by world.lsp; nil when no world is loaded.
(defn enter_effects (room)
  (if (null? room)
      nil
      (let ((rname (room_name room)))
        (if (null? (member rname room_items))
            nil
            (println (str-cat "You see a " (str (car (cdr (member rname room_items)))) " here."))))))

;; (inv-text l) → comma-joined inventory string; "nothing" when empty
(defn inv-text (l)
  (if (null? l)
      "nothing"
      (let ((rest (cdr l)))
        (if (null? rest)
            (str (car l))
            (str-cat (str-cat (str (car l)) ", ") (inv-text rest))))))

(defn cmd-inv ()
  (println (str-cat "You are carrying: " (inv-text (player_inv player)))))

;; ponytail: hard-coded item table — add new items here and in world.lsp
(defn item-symbol (s)
  (if (str=? s "key") 'key
      (if (str=? s "lantern") 'lantern
          (if (str=? s "amulet") 'amulet
              (if (str=? s "potion") 'potion
                  (if (str=? s "sword") 'sword nil))))))

;; (cmd-take arg) / (cmd-use arg) — arg is raw text; take_cmd/use_cmd live in world.lsp
(defn cmd-take (arg)
  (if (null? arg)
      (println "Take what?")
      (take_cmd (item-symbol arg))))

(defn cmd-use (arg)
  (if (null? arg)
      (println "Use what?")
      (use_cmd (item-symbol arg))))

(defn cmd-help ()
  (println "Commands:")
  (println "  walk <dir>  - move (north, south, east, west, up, down)")
  (println "  look        - describe the current room")
  (println "  inv         - show your inventory")
  (println "  take <item> - pick up an item in the current room")
  (println "  use <item>  - use an item from your inventory")
  (println "  help        - show this help")
  (println "  quit        - leave the game"))

;; quit → clean shutdown: prints farewell and returns the 'quit sentinel
(defn cmd-quit ()
  (println "Goodbye!")
  'quit)

;; (dispatch line) → route one raw input line to its command
(defn dispatch (line)
  (let ((verb (parse-verb line)))
    (if (str=? verb "walk")
        (cmd-walk (parse-arg line))
        (if (str=? verb "look")
            (cmd-look)
            (if (str=? verb "inv")
                (cmd-inv)
                (if (str=? verb "take")
                    (cmd-take (parse-arg line))
                    (if (str=? verb "use")
                        (cmd-use (parse-arg line))
                        (if (str=? verb "help")
                            (cmd-help)
                            (if (str=? verb "quit")
                                (cmd-quit)
                                (println "Unknown command. Try: help")))))))))
