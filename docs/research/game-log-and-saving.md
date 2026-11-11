# Game log and saving

Drafted by Cursor (Grok 4.7) for plans/006, read-only; saved, D37/D38 folded in and reviewed by the head (Claude). Status: proposal; product questions answered by the user 2026-11-10 (D37–D41).

Design spike for plan 006. Depends on plan 002's in-memory shape. No app behavior changes in this spike.

Assumed plan 002 shape, on top of today's `SettledShot` (`CueCoach/Live/LiveLogic.swift:457-467`) and `SessionShot` (`CueCoach/App/GameSessionModel.swift:7-17`):

- `before: [BallID: Vec2]` and `after: [BallID: Vec2]`, identified balls only, table metres.
- Balls that left the table are absent from `after`.
- A shot with an empty `before` has no `TableState` in review.
- `reviewData()` builds `pre` / `post` on `config.tableSize` (pocketed balls `.pocketed` in `post`).

Steady state matches `docs/research/mesh-identity.md` §2.5 and `docs/RATINGS.md` (only the host runs the engine, badge after settle). No conflict with those docs. Partition behavior below is the exception that §2.5 already specifies.

## 1. Who rates

The host rates. It is the only phone that turns a camera record into a `ShotOutcome` and appends `GameEvent.shot`.

Each phone, host included, builds its `shots`, badge, and turn by folding the committed log. `GameState = fold(log)` (`docs/research/mesh-identity.md` §2.5; `CueCoach/Mesh/MeshMessage.swift:93-97`). The host is the only log writer (`CueCoach/Mesh/MeshMessage.swift:155-156`, `CueCoach/Mesh/MeshNode.swift:664-676`). A client `append` is a proposal. The host assigns `seq` and `term`.

Today `RuleRating.rate` is a pure function of the outcome and the prior rules state (`CueCoach/Live/LiveLogic.swift:313-327`). Fold runs that same function, so every phone shows the same class. When the real engine replaces `RuleRating`, the host writes `decisionRating` on the shot record and the others display that value. The class stays the one the host showed (`docs/RATINGS.md`: the class does not change after display).

A joiner's camera still draws the local overlay. Its `settledShot` does not append and does not record. The host can use a joiner's table detections later (`MeshUpdate.tableState`, `CueCoach/Mesh/MeshNode.swift:258-259`). That path is not wired: `MeshGameLink` reads only roster changes (`CueCoach/App/MeshGameLink.swift:34-35`). Until fusion exists, the host rates from its own camera.

`MeshShotRecord` today has `shotID`, `shooterTeam`, `outcome`, and `postState` (`CueCoach/Mesh/MeshMessage.swift:86-91`). It has no `preState`, rating, or `isGuess`. Those three need optional fields with a decoder that treats a missing key as empty. Old peers ignore extra JSON keys. This is a mesh minor, not a SwiftData change.

### Failure cases

**Host leaves mid-shot.** The in-flight shot is not in the log, so it is not committed. §2.5 says the new host re-runs it from the last committed `TableState`, and uses "needs tap" when no tracker is confident. `MeshNode` collects survivors' tails and continues the log (`CueCoach/Mesh/MeshNode.swift:643-661`). It does not re-run the shot. Until that follow-up lands, the shot is absent and the turn stays with the previous shooter.

**Split brain.** §2.5: a phone that loses the host and cannot reach a majority enters island mode. In a two-phone game that is both phones. Each may show a provisional local rating. Neither writes SwiftData. On heal, `IslandMerge` builds one log and the highest term hosts. `MeshNode` has no `IslandShot` type. Until the follow-up lands, a partition commits nothing new, and a kill drops the in-memory log.

**Late joiner.** `Welcome` carries the log head and `commitSeq`, then the tail (`CueCoach/Mesh/MeshMessage.swift:13-19`, `CueCoach/Mesh/MeshNode.swift:626-629`). The joiner folds from seq 1. It does not rate past shots and it does not write the store.

**Unacked entry.** Committed means acked by a majority, host included (`CueCoach/Mesh/MeshNode.swift:722-728`). With two phones the joiner's ack is the majority. Fold the badge and the turn from the committed prefix. A provisional tail can show in memory and is replaced if the host's log wins (`CueCoach/Mesh/MeshNode.swift:697-699`).

## 2. How corrections travel

`handTurn` becomes a proposal. The local function does not call `passTurn()`.

Today the disc calls `LiveSession.handTurn`, which returns while aiming (`CueCoach/App/AppRouter.swift:51-53`) and then `GameSessionModel.handTurn` runs `passTurn()` once (`CueCoach/App/GameSessionModel.swift:102-106`). Nothing is sent on the mesh. The comment on the disc says it hands the turn over (`CueCoach/App/InGameChrome.swift:145`).

Proposed path:

1. The tap proposes `GameEvent.shooterCorrection(shotID:team:)` for the latest shot (`CueCoach/Mesh/MeshMessage.swift:97`).
2. The host appends it. Clients already forward proposals (`CueCoach/Mesh/MeshNode.swift:344-345`).
3. Every phone folds the committed entry.
4. Fold sets that shot's team. The shooter id is the player in that team's D17 slot at that index. Rotation is replayed from there, so later shots and the next shooter move with it.
5. `attributionSource` for that shot becomes `.tap`.

A tap with no shot yet has no `shotID`. `GameEvent` has no separate "hand the opening break" case (`CueCoach/Mesh/MeshMessage.swift:94-98`). That tap waits until a shot exists. Adding a case would break decoding of `logEntries` on an older build, so this spike does not add one.

Mid-game `swap` is also local only (`CueCoach/App/GameSessionModel.swift:111-116`). Fold assumes the lineup from `GameConfig` at start. A swap on one phone will diverge until a later plan logs `StoredTeam.orderChanges`.

This encoding reassigns the last shot. Today's `handTurn` does not edit `shots`. Whether the disc should do that is a product question below. The transport (propose, then fold) stays either way.

## 3. Shot fields

Sources after plan 002. "Skip" means the row can still be stored for review, and the stats projection must leave it out of `Aggregates`.

| Field | Source | What to store |
|---|---|---|
| `id`, `index` | Host shot id and log order | Required. `Game.id` is the first committed shot id, so a new host writes the same game. |
| `shooterID` | D17 slot while folding | Required. Identity is not on this path. |
| `attributionSource` | Shell | `.turnOrder`. A folded correction stores `.tap`. Do not store `.auto`. |
| `preState`, `postState` | Plan 002 `before` / `after`, same `TableState` rules as `reviewData()` | Required blobs. Empty `before` stores an empty ball map. Review already treats that as unavailable (`CueCoach/Screens/Review/ReviewData.swift:121-126`). |
| `calledPocket` | Not observed | `nil`. Rules already treat nil as not called (`Packages/CueCore/Sources/Rules/Types.swift:27-29`). |
| `firstContact` | `ShotOutcome.firstContact` from `RuleRating.outcome` | The value when Live has it. A D31 guess has none (`docs/INTERFACES.md` D31 note). `nil` does not create a foul. |
| `railsAfterContact` | Not observed. `ShotOutcome.anyRailAfterContact` is optional; the column is `Int` | Store `0`. Stats does not read it (`CompetitiveShot` has no such field). Do not treat `0` as "no rail" when a trace arrives. |
| `pocketed`, `fouls` | Rules via `SettledShot` | Store them. Fold recomputes fouls with `RulesEngine.apply`. |
| `features` | `ShotFeatures.extract(pre:post:trace:)` with an empty trace | Run it when `pre` contains the cue ball (`Packages/CueCore/Sources/Stats/ShotFeatures.swift:164-166`). Otherwise store `ShotFeatures.neutral` and skip the shot in `Aggregates`. |
| `made` | Derived | True when an object ball (not the cue) is in `pocketed`. |
| `onTarget` | Derived | If `calledBall` is nil, store `made` (the rules give an uncalled shot the benefit of the doubt). If a ball was called, store whether that ball was pocketed. |
| `cueResult` | Engine position zone, not wired | `.notApplicable`. `Aggregates` ignores that case (`Packages/CueCore/Sources/Stats/Aggregates.swift:104-108`). |
| `decisionRating` | Host `RuleRating`, later the engine value on the log | Store the folded class. |
| `executionRating` | Derived from `made` | `.made` or `.miss`, position `.notApplicable`. The decode fallback is `.miss` (`CueCoach/Persistence/CompetitiveModels.swift:236-237`), which would mark a made ball as a miss. |
| `wpaDelta` | Engine, not wired. Live review already stores `0` (`CueCoach/App/GameSessionModel.swift:157`) | Store `0` and an empty `Game.winProbSeries`. Career total WPA sums this column (`Aggregates.swift:100`). The profile skips WPA for a game whose series is empty. |
| `isClutch` | Needs win probability. No threshold is in the schema | `false`. The clutch rate only counts `true` shots (`Aggregates.swift:129`), so these shots stay out of Ice Veins. |
| `timeOnShot` | Not measured | `-1`. The mean ignores non-finite and negative times (`Aggregates.swift:102`). |
| `clipRef` | Out of this design | `nil`. |

`features` is the field that corrupts archetypes if filled blindly. `Aggregates` records pot rate by cut, distance, pocket, and kind for every non-break, non-safety shot (`Aggregates.swift:121-128`). `ShotFeatures.neutral` is a short straight corner pot (`ShotFeatures.swift:130`). Writing that for every shot makes Cut Artist, Long Gun, and the pot rate lie.

Shots that have the cue ball use `extract` with an empty trace. Cut, distance, and pocket then come from the positions. Bank, kick, combo, jump, and safety need a trace or a called intent (`ShotFeatures.swift:241-297`). Those kinds will under-count until a trace exists. Safety Chess and Bank Wizard stay short of their sample minimum instead of filling with fake safeties. That bias is accepted for this schema.

`isGuess` is the field that cannot be stored honestly. See the migration stop below. A guessed pocket saved as a normal make would enter pot % (`Aggregates.swift:121-124`).

## 4. Who writes, and when

One writer. That is the host, or the solo phone.

Solo: `sessionTag == nil` leaves `mesh` nil (`CueCoach/App/AppRouter.swift:92-95`). That phone is the authority and writes at the end of the rack.

Mesh: `MeshSession.append` (`CueCoach/Mesh/MeshSession.swift:25-26`). Only the current host calls `GameRecorder`. A joiner folds the same log and writes nothing. `Aggregates.career` dedupes by game id, and the shared id is the first committed shot id, so a later host updates one row.

The log grows one committed shot at a time, in memory (`MeshNode.log`). SwiftData is one `save` of the finished rack, after `commitSeq` covers that rack and this phone still has a majority. `Game.endedAt` and `winnerTeam` come from the folded rules state. `GameSessionModel.reviewData` already treats a mid-rack quit as unfinished (`CueCoach/App/GameSessionModel.swift:146-162`). The saved review uses `endedAt != nil` (`CueCoach/Screens/Review/ReviewData.swift:140`).

`endGame` builds review in memory and `finishReview` drops it (`CueCoach/App/AppRouter.swift:104-126`). The recorder runs in `endGame` before the stage becomes review, so a kill on the review screen keeps a finished rack.

Crash and kill follow the product answer below. The three hooks:

- **Discard.** Write only when the rack has a winner, or when the player ends a rack that already has one. A kill mid-rack leaves no row. The log is RAM, so it dies with the process.
- **Unfinished.** Also write on background and on `endGame` with `endedAt == nil`. `Aggregates.game` still counts that rack's shots and sets `games = 1` (`Aggregates.swift:94-100`). The stats projection must skip games with `winnerTeam == nil`, or unfinished racks enter archetypes.
- **Resume.** Same row as unfinished, plus a launch prompt that folds those shots back into a `GameSessionModel`. Needs the island follow-up before a killed mesh game can resume. This spike does not build it.

Do not write while the phone is in a partition. Two hosts would insert two games.

Nothing in the app inserts `Game` or `Shot` on the live path today. The models exist (`CueCoach/Persistence/CompetitiveModels.swift:109`, `:159`). Backup import is the only writer.

## 5. Training isolation

The writer is reachable only from a game `GameSessionModel`.

- Training starts with `game: nil` (`CueCoach/App/AppRouter.swift:99-100`).
- `endGame` returns when there is no game (`CueCoach/App/AppRouter.swift:104-105`).
- `LiveModel.shotSettled` calls `settledShot` only in `.game`. Training calls `ballsSettled` (`CueCoach/Live/LiveModel.swift:264-270`).
- `GameRecorder` is called from the host/solo finish path on `GameSessionModel` only.

The stores are already separate containers (`CueCoach/Persistence/PersistenceStack.swift:4-6`). `StoreIsolationTests.writingTrainingDataLeavesCompetitiveCountsUnchanged` covers a direct training insert (`CueCoachTests/Persistence/PrivacyAndIsolationTests.swift:96-104`).

New test, in the save follow-up: `GameRecorderTests.trainingNeverWritesACompetitiveGame`. Start a training `LiveSession`, settle a shot, call `liveClosed` and `endGame`, and expect `Game` and `Shot` counts in `competitiveContext` to stay 0.

## 6. Privacy

The row is ball positions, pocketed balls, fouls, shooter id, and ratings. `clipRef` stays nil. No `Highlight`, so no clip file. No frame, embedding, or track metadata.

Recognition stays in `Recognition.store`. One-tap delete empties that store and leaves profiles, games, and stats (`CueCoach/Persistence/PersistenceStack+Privacy.swift:112-115`). `RecognitionPrivacyTests.deleteMyRecognitionDataRemovesOnlyEmbeddings` already expects the `Shot` rows to remain (`CueCoachTests/Persistence/PrivacyAndIsolationTests.swift:8-22`).

That delete does not need to cover saved games. These rows are not recognition data. Guest profiles are still removed at session end, and the shot keeps the guest id as plain history (`CueCoach/Persistence/PersistenceStack+Privacy.swift:137-138`).

Clips can show people (`docs/research/mesh-identity.md` §7.4). They are not part of this writer. A later clip save has to delete them with the game. One-tap recognition delete still would not cover them.

## Sequence: one shot, two phones

```
Host camera                         Host log                          Joiner
balls settle
RuleRating + before/after
append .shot(MeshShotRecord) -----> LogEntry(seq N, term)
                                    logEntries -----------------------> store entry, ack
                                    <--------------------------------- LogAck
                                    commitSeq = N (majority)
fold prefix through N
badge, turn, SessionShot            ---------------------------------> fold the same prefix
                                                                      badge, turn, SessionShot
rack over, this phone is host, majority intact
GameRecorder.record(FinishedGame)                                     (no SwiftData write)
```

The joiner's own settle callback does not appear in this sequence.

## Migration stop

Saving `isGuess` needs a SwiftData change. This spike does not write it.

`Shot` in Competitive schema V2 has no guess flag (`CueCoach/Persistence/SchemaVersions.swift:69-73`, `CueCoach/Persistence/CompetitiveModels.swift:158-272`). `GameReviewData.init(game:)` never sets `ReviewShot.isGuess`, so it stays false (`CueCoach/Screens/Review/ReviewData.swift:119-129`).

A guessed shot written as a normal row would count as a real make. Until a Competitive V3 migration adds `Shot.isGuess` (Bool, default false) and the review adapter reads it, the writer skips `isGuess == true` shots. They remain on the in-memory review for this launch only.

No other `Shot` or `Game` column has to change for the field table above. `endedAt` nil already means unfinished.

## Product questions

These are not decided.

1. ~~Joiner badge now or after the host?~~ **Decided: D39**, wait for the host's committed rating.
   Recommended: wait for the host's committed entry. One badge, and it matches the log.

2. ~~Mid-game close?~~ **Decided: D40**, discard; only finished racks are saved.
   Recommended: discard. The log is memory only, and an unfinished row still counts as a game in `Aggregates` unless a later filter skips it.

3. ~~Should ✕ in a game ask before ending it?~~ **Decided: D37** (user, 2026-11-10). ✕ asks "End game?". On confirm, an open shot finishes settling before review opens, so it is never silently dropped. The recorder therefore runs after that last settle.

4. ~~After a lost-tracking shot with no guess, who shoots next?~~ **Decided: D38** (user, 2026-11-10). The turn discs pulse until someone taps the shooter, and the review shows the shot as an unknown gap. In a mesh game the tap is a proposal like any correction (§2), and the gap needs a log event or a `MeshShotRecord` with no outcome. Fold-the-log follow-up plan 1 must cover it.

5. ~~Turn disc reassigns the last shot?~~ **Decided: D41**, next shooter only.
   Recommended: only change who shoots next. That is what `handTurn` does today (`CueCoach/App/GameSessionModel.swift:102-106`). Use `shooterCorrection` when someone fixes a named shot. This needs a log event the enum does not have yet, so it waits on this answer.

## Follow-up plans

Worker-sized, test first. Order:

1. **Fold the shot log.** Host appends `.shot` and `.shooterCorrection`. Every phone folds the committed prefix into `SessionShot`, including plan 002 `before` / `after`. A client settle does not record. Fake `MeshSession` in `GameSessionModelTests`. No SwiftData. Add the optional `MeshShotRecord` fields with missing-key defaults. Per D41 the disc changes only the next shooter, so it needs a 'next shooter' log event; `.shooterCorrection` stays for fixing a recorded shot. The fold tests for both events can be written before that answer.
2. **Mesh link forwards the log.** `MeshGameLink` surfaces `logChanged` (`CueCoach/Mesh/MeshNode.swift:50`) to `GameSessionModel`. Depends on 1.
3. **Save the finished rack.** `GameRecorder` on the host or solo phone, current V2 schema, field table above, skip `isGuess` shots, training test from §5. Depends on 1. D40: write only finished racks; D37: the recorder runs after the last settle.
4. **`Shot.isGuess` migration.** Competitive V3 only. Review reads the flag. Guessed shots can then be saved and kept out of pot %. Blocked until that migration is approved. Do not start it inside plan 3.
5. **Host loss and island mode.** §2.5 re-run and `IslandMerge`. No SwiftData write while partitioned. Depends on 1. Resume (question 2's third option) depends on this.
