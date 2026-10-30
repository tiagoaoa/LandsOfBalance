# Night hunt

Desktop playtest: `./test_coop_ai.sh paladin`.

Stay with the archer, follow his fire into the grass, and find Bobba. Fire
reveals enemies; terrain still blocks sight. Unlit enemies outside five metres
do not appear in lock-on or the combat HUD. The objective and the archer's
current task appear at the top of the screen.

The companion starts beside the player and lights their direction of travel
(or their view when standing still). During a fight he keeps shooting, draws
before releasing, leads moving targets, and holds a prepared shot briefly for
Bobba's next windup. He follows when separated and falls back behind the paladin
when pressured.

A fire arrow during Bobba's windup or guard gives a 1.35-second opening, with
nine seconds between fire interrupts. An arrow also kindles him for eight
seconds: paladin hits deal 20% more damage and 45% more posture damage. Body
fire does not stack. Fire is a way to create and see openings; ground fire no
longer makes Bobba abandon every attack.

Bobba circles between exchanges, leaps to close a gap, and uses fists when the
player is too close for the axe. His strikes follow the animated hands or axe
head, with sweeps between poses and one hit per player per swing. He commits
his direction after the early tell and leaves a stationary recovery window.

Regression scenes: `tests/night_hunt.tscn`, `tests/combat_feel.tscn`,
`tests/souls_combat.tscn`, `tests/archer_aim.tscn`, `tests/archer_trajectory.tscn`.
Run them headless with `--singleplayer --character-class=paladin --no-mcp-runtime`.

`tools/review_night_hunt.tscn` captures the real desktop renderer at spawn,
before and after a support arrow, and during combat. Run with `--singleplayer
--coop --character-class=paladin --no-mcp-runtime`. Images are written to
`docs/presentation/night-hunt/`. The first comparison holds Bobba still; the
last capture restores his AI. These captures and the combat scenarios check
behavior and rendering, not how difficult or enjoyable a human finds the fight.
