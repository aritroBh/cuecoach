# CueCoach spec (verbatim from the user, 2026-11-06). Decisions that amend it: `docs/DECISIONS.md`.

## 1. Product in one paragraph

Phones on tripods around a pool table watch the game. Each player has the app on their own phone, with their own profile and history. While a player lines up a shot, the screen draws GamePigeon-style aim lines over the live camera feed:
- cue ball → object ball
- object ball → pocket
- cue ball path after contact

It also shows suggested spin and power, and marks illegal targets with a red ring. After every shot the app rates it the way chess.com rates moves (Brilliant, Great, Mistake, Blunder...). The rating shows what the shot did to the game for both players. The app knows who is shooting and tracks stats per player. Over time it builds a play-style archetype for each player and compares them to pro players (Efren Reyes, Shane Van Boening, etc.). It picks a Shot of the Game clip and an MVP. A separate Training mode runs progressive drills: aim lines fade away as you level up, and you get big-picture visual feedback on your tendencies.

## 2. Hard constraints (non-negotiable)

- **Platform:** native iOS, Swift 6, SwiftUI. Minimum target is **iOS 27**. Target devices are iPhone 15 Pro / Pro Max or newer (8 GB RAM).
- **Signing:** a **free Apple Personal Team**. Do NOT use any capability a Personal Team can't provision: no iCloud/CloudKit, no Push Notifications, no App Groups, no Associated Domains, no restricted entitlements. Builds expire every 7 days; that's accepted. Check every capability against Apple's "Supported capabilities (iOS)" table before adding it.
- **All AI runs on-device.** No network calls of any kind, no backend, no analytics SDKs.
- **Sync** is peer-to-peer only, over the local mesh (MultipeerConnectivity). Profiles live on each player's own phone (SwiftData). Backup is a manual JSON export/import through the share sheet (AirDrop/Files).
- **No text and no audio while aiming.** Everything shown during a shot is visual: lines, rings, glows, color, a spin dot, a power meter. Post-shot rating badges may use an icon + color + at most 2 words ("Brilliant", "Blunder"). The post-game review may use short labels. Long text never appears anywhere.
- **Feedback is big-picture and never numeric-precise.** Never say "aim 20.2° left" or "hit at 63% power". Humans can't act on that. Say it visually: show the player's habitual line next to the correct line, a miss-direction heatmap, or a "softer/harder" arrow. Give general corrections ("you overcut thin cuts", "you hit long shots too hard"), never micro-adjustments.
- **Privacy.** Face and appearance recognition is opt-in per player. Embeddings are stored only on that player's own phone, and shared only over the local mesh with peers in an active session. Settings has a one-tap "delete my recognition data".

## 3. Rules (study and implement precisely)

Implement three rule sets as a pure-Swift, fully unit-tested state machine (`RulesEngine`):

1. **8-ball, bar rules / slop counts (DEFAULT).** No call-shots except the 8-ball (its pocket must be called). Use the common bar conventions; list each convention you pick in `RULES.md` so I can review it.
2. **8-ball, WPA Rules of Play** (current edition, effective 2026). Call-shot on every shot except the break. Open table until a group is legally pocketed. Hitting the 8 first on an open table is a foul. Pocketing the 8 early, in an uncalled pocket, with a foul, or off the table loses the rack. Potting the last group ball and the 8 on the same shot loses the frame. Ball in hand anywhere after a foul. Follow the WPA text for break and 8-on-break handling.
3. **9-ball, WPA.** The lowest-numbered ball must be contacted first. No calling. Legally pocketing the 9 wins. Push-out after the break. Ball in hand after a foul. 3-foul rule.

Common fouls to detect from tracking: scratch; wrong ball first or no contact; no rail after contact (no ball reaches a rail and nothing is pocketed); ball off the table.

Read the actual WPA PDFs (wpa-pool.com, and Dr. Dave's rules summaries at drdavepoolinfo.com) and cite the rule numbers in code comments.

**Rule-set vote:** at session start, every phone in the session gets a visual poll (rule-set icons). Majority wins. On a tie or no vote, use the default (8-ball slop).

**Called pocket in WPA mode:** inferred automatically. When the stroke starts, lock in the pocket the predicted object-ball line points to. The shooter can tap a pocket to override.

**Legality overlay:** when the aim line targets an illegal ball (for example the 8 before the group is cleared, or a non-lowest ball in 9-ball), draw a pulsing red ring around that ball and turn the line red. GamePigeon does exactly this.

## 4. Game formats

- 1v1, 2v2, 3v3, 4v4 (max 8 players). Teams alternate shooters in a set order, editable mid-game.
- **Solo Training** is a separate mode (§10).
- **Training stats are stored completely separately** from competitive stats and never mixed into game stats, archetypes, or pro comps.

## 5. Architecture

```
CueCoach/
  App/ Capture/ Calibration/ Perception/ Tracking/ Physics/ Rules/ Engine/ Overlay/ Mesh/
  Identity/ Stats/ Highlights/ Training/ Intelligence/ Persistence/ DevTools/
tools/   Python: detector training, CoreML export, physics validation, pro-profile pipeline
```
(Pure-Swift modules Physics/Rules/Engine/Stats/Training-logic live in `Packages/CueCore` — see DECISIONS.)

### 5.1 Capture and calibration
- Phone on a tripod at an angle that sees the whole table. Handheld must also work, with degraded accuracy.
- Auto-detect the cloth region, rails, and 6 pockets, then compute a homography from image to table plane. Fallback: the user taps the 4 corner pockets.
- **Ball centers sit one ball radius above the cloth.** Correct the homography for that plane offset. Re-validate calibration continuously and prompt for recalibration (visually) if the phone moves.
- Table presets: 7 ft, 8 ft, 9 ft. Standard 57.15 mm balls.

### 5.2 Perception
- **Ball detector:** YOLO-family (Ultralytics) → Core ML `.mlpackage`. 30+ fps on iPhone 15 Pro.
- **Training pipeline in `tools/`:** Roboflow Universe datasets (record licenses) + in-app data-collection frames with auto-proposed labels; train and export with `coremltools`.
- **Ball identity:** cue, 1-15, solids vs stripes. Small classifier on detector crops (hue + stripe white-ratio + number features), smoothed by the tracker.
- **Cue stick and stroke:** Vision (`VNDetectHumanBodyPoseRequest`) + line detection on the cue for live aim direction and stroke start/end.
- Vision for everything real-time. Never an LLM on the real-time path.

### 5.3 Tracking and shot segmentation
- Kalman-filter tracker in table coordinates.
- Shot starts when cue-ball velocity crosses a threshold right after a detected stroke; ends when every ball has been at rest for N frames.
- Each shot records: pre-shot state, shooter, first contact, rails hit, pocketed balls, final state, clip timestamps.

### 5.4 Physics engine
Deterministic 2D event-based simulator: sliding → rolling transition; rolling friction; ball-ball collisions with cut-induced and spin-induced **throw**; cushion rebound with speed-dependent restitution; top, draw, side spin; squirt/deflection; pocket capture geometry. Equations: Dr. Dave Alciatore (drdavepoolinfo.com).

**Validation:** fixtures from the open-source Python simulator **pooltool** (in `tools/`). Swift must match its trajectories within tolerance across a randomized suite.

The aim overlay uses this engine to predict in real time: (1) cue path to ghost-ball contact, (2) object-ball path to pocket with throw, (3) cue path after contact from suggested spin and speed (tangent line, 30° rule, draw/follow curves).

### 5.5 The Engine ("Stockfish for pool")
1. **Candidates.** Each legal target × pocket: direct, simple banks, simple combos, kicks. Safeties: hide the cue ball, or leave no makeable shot. Grid of speed × spin.
2. **Monte Carlo** with execution noise from a skill model (per-player noise learned from competitive history; default for new players).
3. **Value** = P(make) × value(resulting position) + (1 − P(make)) × value(position left to opponent). Position value = best next-shot value, 2-ply. Safety value = 1 − opponent's best P(make).
4. **Win probability** for the rack (balls per side, ball in hand, shooter, run-out probability) → chess.com-style **eval bar**.
5. **Two ratings:** Decision (Brilliant !!, Great !, Best, Good, Inaccuracy ?!, Mistake ?, Blunder ??) vs engine best EV; Execution (Made / Near miss / Miss + position-play result). Brilliant = non-obvious, at/near best EV, low baseline P(make) or creative safety/bank/kick, executed successfully. Blunder = far below best or a foul that swings win probability hard.
6. **How it affected the game:** eval-bar swing, before/after mini diagram, newly opened opponent shots glow green, newly blocked glow grey, ghost replay of the better shot for sub-optimal decisions.
7. Background actor; finish within ball-settling time (~2-4 s).

### 5.6 AR overlay
Project table-space geometry through the inverse homography; Metal or SwiftUI Canvas at 60 fps.
- Line 1 cue → ghost ball (+ ghost circle). Line 2 object → pocket with throw. Line 3 cue after contact (dashed).
- Color: green high P(make), yellow marginal, red illegal/near zero.
- Spin: cue-ball face diagram with strike dot. Power: 5-step meter, no numbers.
- Suggested shot as faint guide, toggleable in game; always available in Training (levels 1-3, see DECISIONS).
- Live aim follows the cue stick; converges visually with suggested aim.
- No text. No audio. Ever, during aiming.

### 5.7 Mesh
- MultipeerConnectivity; `NSLocalNetworkUsageDescription` + `NSBonjourServices`.
- Host election (newest device / highest battery); host owns game state, rules, engine.
- Peers stream timestamped table-coordinate detections (not video); host fuses with confidence weighting. NTP-style clock sync.
- Joining phone shares profile summary (+ embedding if opted in) for the session only.
- Each phone keeps its own rolling video buffer.
- **Everything works with one phone.**
- Host migration on disconnect without losing game state.

### 5.8 Player identity
- Opt-in face + upper-body embeddings at registration (Vision feature print or small Core ML model); clothing re-ID for the session.
- Shooter = person in shooting pose nearest the cue ball at stroke start, matched to session embeddings.
- Low confidence → expected turn order. One tap on any phone corrects; corrections become session training signal.

### 5.9 Apple Foundation Models (iOS 27)
On-device model with image input, guided generation (`@Generable`), tool calling; 4K context. Only for non-real-time: verify shot classification on keyframes, choose/label (≤2 words) Shot of the Game, name archetypes, post-game short labels. Always guided generation into typed structs. Every feature has a deterministic fallback. No third-party VLM without measuring a gap and asking.

## 6. Stats (competitive only)
**Per shot:** shooter, game, rule set; cut-angle bucket (0-15/15-30/30-45/45-60/60+), distance bucket (short/mid/long), pocket type (corner/side), bank/combo/kick/rail/jump; made/missed/on-target; cue-ball position result; decision + execution ratings, WPA delta; clutch flag; time on shot.
**Per game:** attempts, makes, misses, on-target %, pot % by bucket, break stats, safeties + success, fouls, run-outs, break-and-runs, total WPA, clutch conversion.
**Per player (career):** aggregates + trends.

## 7. Archetypes
Unlock after ≥3 competitive games and ≥50 shots. Feature vector → tags by z-score vs friend group and absolute baselines (Cut Artist, Long Gun, Side-Pocket Sniper, Ice Veins, Safety Chess, Cannon Break, Run-out Machine, Bank Wizard). Icon badge + 1-2 word label; radar chart; recompute after every game with history.

## 8. Pro comps
Bundled `ProProfiles.json` (same dims as archetype vector). Seed: Efren Reyes (priority), Shane Van Boening, Joshua Filler, Fedor Gorst, Earl Strickland, Ko Pin-Yi, Carlo Biado, Aloysius Yapp, Jayson Shaw, Francisco Sanchez Ruiz. (1) Stats + research with source URL + confidence per trait; never fabricate; qualitative → `"estimated": true`. (2) Dev-time video pipeline in `tools/` outputs only aggregate stats. Cosine similarity; "Plays like Efren" ring + top 2 shared traits; only after unlock threshold.

## 9. Highlights
Shot of the Game = max |WPA swing| × (1 − baseline P(make)), bonus for game winner. Clip ~3 s before stroke → ~2 s after settle, best-view angle, overlay of actual paths burned in. In-app only. Summary: clip → eval swing → before/after diagram → ≤2-word label (FM, rule fallback). MVP: team games highest total WPA; 1v1 winner's best-shot card.

## 10. Training (solo)
Drills: straight-ins, increasing cuts, long, rail, side-pocket, position play (glowing zone), spin control, banks. Setup ghost circles turn green when real balls match. Assist levels: 1 all lines + spin + power; 2 object→pocket only; 3 ghost circle only; 4 nothing (reveal after). Level up on rolling success over N attempts. Feedback engine: consistent same-sign bias over ≥8 attempts (overcut/undercut, left/right, hard/soft, cue long/short, spin vs intended) → visual only (average line vs correct line, miss heatmap, arrow), one correction at a time. Separate store.

## 11. Screens
Home; Session lobby (join, identity, format/teams, rule vote); Calibrate; Live game (camera + overlay + eval bar + shooter avatar + rule icons, no text); Post-shot card (auto-dismiss); Game review (timeline, 2D replay w/ engine alternative, win-prob graph, SotG, MVP); Player profile (stats, radar, badges, pro comp, history, Training tab); Training; Settings (privacy delete, export/import, rule defaults, table size, debug HUD).

## 12. Dev tools (early)
Virtual table (2D, physics-driven, drag aim, spin, power; exercises rules/engine/stats/archetypes/training). Replay mode (.mov through full pipeline). Data-collection mode. Debug HUD (fps, confidences, homography error, peers, host, latency).

## 13. Phases
| Phase | Build | Acceptance |
|---|---|---|
| 1 | Xcode project, SwiftData models, RulesEngine (3 rule sets), Physics, virtual table | 100% rules tests pass. Physics matches pooltool fixtures within tolerance. Full 8-ball and 9-ball game playable on virtual table. |
| 2 | Engine: candidates, Monte Carlo, win prob, ratings | Ratings sensible on 20 hand-built positions the user reviews. Eval < 3 s on device. |
| 3 | Capture, calibration, detector + Core ML, identity classifier, tracker, segmentation, replay | ≥30 fps on 15 Pro. Ball identity ≥95% on held-out video. Shot start/end correct in replays. |
| 4 | AR overlay | Stable lines; predicted object path matches real path in replays. |
| 5 | Mesh + fusion + host election/migration; identity + fallback | 2-3 phones fuse. Killing host keeps game. Attribution ≥90% with tap fallback. |
| 6 | Stats, archetypes, pro comps | Every pro trait sourced or `estimated`. Comps after unlock. |
| 7 | Highlights, MVP, review | SotG clip plays in-app with burned-in paths. |
| 8 | Training + feedback | Levels progress. Bias fires on synthetic biased data, quiet on unbiased. Training never touches competitive stats. |
| 9 | Polish, perf, thermal, privacy, export/import | 1-hour session, fps never below 24 from throttling. |

Git: feature branch per phase. Never `git push --force`, `git reset --hard` without backup branch, or `git clean -fd`.
