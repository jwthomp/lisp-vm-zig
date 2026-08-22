;; mud/mudeus.lsp — bootstrap + interactive game loop (sqhn-pl0)
;;
;; Boots the demo world and runs the command loop:
;;   lisp-vm -f mud/mudeus.lsp
;;
;; Prompts for a character name, drops the player into the start room,
;; then reads commands until `quit` or end-of-input (clean shutdown).
;;
;; Tests: (def *no-autostart* 1) before importing skips main().

(import mud/world.lsp)

;; (start-game name) — create the player, describe the start room
(defn start-game (name)
  (do
    (if (str=? name "")
        (def player (create_player 'hero))
        (def player (create_player name)))
    (let ((room (get_room start-room)))
      (println (describe_room room))
      (enter_effects room))))

;; (game-loop) — read one line, dispatch it, repeat; stop on quit or EOF
(defn game-loop ()
  (let ((line (read-line)))
    (if (str=? line "")
        (println "Goodbye!")
        (let ((result (dispatch line)))
          (if (equal? result 'quit)
              nil
              (game-loop))))))

(defn main ()
  (do
    (println "Mudeus - a tiny dungeon crawl.")
    (println "Who are you? (name)")
    (start-game (read-line))
    (game-loop)))

(if (null? *no-autostart*) (main))
