# Shot classes — the 10 ratings (D18)

Source of truth for how every shot is labelled. Your examples are built in. `docs/RATINGS.md` (research) may tune
the numbers but can't change the classes or the rules below. Players never see these numbers; they see an icon,
a color and ≤2 words after the balls settle.

## What the engine measures for each shot
| Signal | Meaning |
|---|---|
| **WP** | The shooter's team's win chance, from the engine (0–100%). |
| **Best** | The engine's top option from this position, for *this player's* skill. |
| **Loss** | Best option's expected WP − the chosen option's expected WP. This rates the **choice**. |
| **Swing** | WP after the shot actually happened − WP before. This rates the **result**. |
| **Difficulty** | How likely this player is to pull off the shot they chose (their own make/safety %). |
| **Intent** | Which candidate the shot matches (pot X in pocket Y, or a safety), inferred from aim and outcome. |

Each shot gets one label. Work down the table; the **first** row that matches wins.

## The classes
| # | Class | Rule | Example |
|---|---|---|---|
| 1 | **Book** | A break shot, a 9-ball push-out, or a re-break. Never rated beyond this. | Every break. |
| 2 | **Blunder** | **Game-altering.** Either the shot loses the rack (8 early, 8 in the wrong pocket, scratch on the 8, 3rd foul in 9-ball), or Swing ≤ −30 pts, or it hands the table over in a way the shooter won't get back soon (opponent's WP after ≥ 75% when the shooter was ≥ 50% before). | Sinking the 8 early; a careless shot that leaves the opponent a clear run-out. |
| 3 | **Mistake** | A foul that gives the opponent ball in hand without ending the game (scratch, no rail, wrong ball first, no contact), or Loss/Swing of 15–30 pts. | Scratching off the object ball. |
| 4 | **Miss** | A clear chance was missed by **choice**: Best was a high-percentage shot (Difficulty ≥ 70%, or it set up a run-out) and the player went for something else that's ≥ 10 pts worse. Covers missed chances after the opponent left an easy shot. | An easy ball was on, but they went for a harder one. |
| 5 | **Inaccuracy** | Wrong ball or wrong plan that still worked out: Loss 8–15 pts and no foul. | Pocketing a ball but leaving poor position for the next one, when a better ball was there. |
| 6 | **Brilliant** | See the special rules below. **At most one per game.** | Shot of the game: a lock-down safety, a near-impossible cut that wins the rack. |
| 7 | **Great** | See the special rules below. | A hard cut made with good position. |
| 8 | **Best** | Chose the top option (Loss ≤ 2 pts) and executed it. | Routine pot with correct position. |
| 9 | **Good** | Loss 2–5 pts, no foul. | A solid pot with slightly worse position than ideal. |
| 10 | **Okay** | Loss 5–8 pts, no foul, or a sound choice that was executed below its intent (made the ball but missed position, or a safety that left a moderate shot). | Made it, but now it's awkward. |

Negative rows are checked before special ones, so a shot can't be both Brilliant and a Mistake.

## Great vs Brilliant
Both need a **successfully executed** shot. That means the intended outcome happened: the ball went in the
intended pocket, or the safety did its job.

**Great: a really good shot. Several per game are fine.** All of:
- The choice was Best or close to it (Loss ≤ 3 pts).
- At least one of these:
  - **Hard shot:** Difficulty ≤ 50% for this player.
  - **Only good move:** every other option is ≥ 10 pts worse.
  - **Strong result:** Swing ≥ +15 pts.

**Brilliant: the play of the game. At most one per game, and it can be zero.** All of:
1. **It is the Shot of the Game.** It has the highest Shot-of-the-Game score in the game (SPEC: the WP swing weighted by
   how unlikely the shot was). If two shots qualify, only the top one is Brilliant; the other becomes Great.
2. **It was the right idea.** Loss ≤ 2 pts, so it really was the best option.
3. **It was really hard.**
   - For a pot: Difficulty ≤ 30% for this player.
   - For a safety or a deliberate miss: afterwards the opponent's best make chance is ≤ 20%, and the shooter's best pot before the shot was ≤ 40%.
4. **It changed the game.** Swing ≥ +25 pts, or it decides the rack: a game-winning shot from a position where the shooter's WP was ≤ 50%.
5. **It isn't a Book shot.** Breaks are never Brilliant.

Brilliant is decided **after the game ends**, when every shot can be compared. During play, a shot that might become Brilliant shows as **Great**.
In the game review it's upgraded and gets the Shot-of-the-Game clip.

Intentional misses can qualify. A safety that leaves the opponent nothing counts as executed when its goal
was met, so it can be Great or Brilliant (D2).

## Execution rating (separate, unchanged)
`ExecutionRating` records made / near miss / miss and whether position landed in the zone. The class above
judges the **choice and its impact**. Execution feeds Difficulty and the player's skill model.

## Badges (after the balls settle; icon + color + ≤2 words)
| Class | Icon (SF Symbol) | Color | Label |
|---|---|---|---|
| Brilliant | `sparkles` | cyan | Brilliant |
| Great | `star.fill` | green | Great |
| Best | `checkmark.seal.fill` | green | Best |
| Good | `checkmark` | ink | Good |
| Okay | `circle` | ink (muted) | Okay |
| Book | `book.closed.fill` | ink (muted) | Book |
| Inaccuracy | `exclamationmark` | yellow | Inaccuracy |
| Miss | `scope` | orange | Missed chance |
| Mistake | `questionmark` | orange | Mistake |
| Blunder | `xmark` | red | Blunder |

All thresholds are starting points. They're calibrated in Phase 2 against the 20 reference positions, and
are never shown to players.
