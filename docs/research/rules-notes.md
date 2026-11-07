# Rules research notes (for `RulesEngine`, SPEC §3)

Compiled 2026-11-06. Research only, no code. Every WPA item cites a rule number from the text I read. "Unverified" means I could not confirm it against a primary source.

## Sources

| Key | Document | Edition / date | URL |
|---|---|---|---|
| **WPA** | WPA *Rules of Play* | **Effective 2026-10-21** (current; linked from wpapool.com/rules-of-play/) | https://wpapool.com/wp-content/uploads/2026/10/WPA-Rules-2026-10-21-211.pdf |
| **WPA-Reg** | WPA *Playing Regulations* | Effective 2026-10-21 | https://wpapool.com/wp-content/uploads/2026/10/WPA-Regs-2026-10-21-211.pdf |
| WPA-2025 | WPA *Rules of Play* (previous) | Effective 2025-09-15 | https://www.hkbilliardsports.org.hk/wp-content/uploads/2026/03/2025.09.15-WPA-Rules-WPA-Regs-NP.pdf |
| **DD** | Dr. Dave, "8-ball and 9-ball rules summary" (based on WPA) | undated | https://drdavepoolinfo.com/resource_files/rules_summary.pdf |
| DD-bar | Dr. Dave, "Bar rules" FAQ | live page | https://drdavepoolinfo.com/faq/rules/bar-rules/ |
| DD-lg | Dr. Dave, "League rule differences" FAQ | live page | https://drdavepoolinfo.com/faq/rules/league-rule-differences/ |
| CM | Cornerman Billiards "Bar Rules 8-Ball" (F. Agnir, linked by DD-bar) | 2019-11-06 | https://drdavepoolinfo.com/resource_files/Cornerman_Bar_Rules.pdf |
| **APA** | APA *Pool Rules for League Play* (online) | live, mentions league years 26/27–28/29 | https://rules.poolplayers.com/game-rules/ (subpages: `breaking/`, `after-the-break/`, `fouls/`, `how-to-win-a-game/`, `otm-pocketed-balls/`, `balls-on-the-floor/`) |
| **CSI** | *Official Rules of CueSports International* (BCAPL / USAPL) | file dated 2025-08-12 | https://www.playcsipool.com/uploads/7/3/5/9/7359673/official_rules_of_csi__08122025.pdf |
| VNEA | VNEA 8-ball rules | 2025 | https://www.vnea.com/Data/Sites/1/media/8-ball_rules_only_2025.pdf |

**Edition note.** I did a normalized word diff of the 2025-09-15 and 2026-10-21 editions over General Rules (§1–3), 8-Ball (§4) and 9-Ball (§5). The only changes are "player"→"athlete", typography, and 3.11 ("in front of" → "below" the Head String). Nothing changes the logic. Austrian/Swiss federation notes also list a Feb-2026 change set (e.g., hand-off-cue no longer a foul), which doesn't affect tracking. **Cite "WPA Rules of Play, eff. 2026-10-21" in code comments.**

---

## 1. General rules relevant to automatic detection (WPA §1–3)

| Topic | WPA rule | What the text says (paraphrase, key words quoted) | Engine note |
|---|---|---|---|
| Fouls apply only if listed | 3 (intro) | Fouls in §3 apply "when included in the specific rules of the game." If several fouls occur on one shot, **only the most serious one is enforced**. A foul not called before the next shot "is assumed not to have happened." | Resolve each shot to one foul, picking the most severe. |
| Legal shot | 2.19 | A shot begins at tip contact with a forward stroke and ends when all balls stop moving and spinning. It is "legal if the shooter did not foul." | Evaluate a shot only after the last ball stops. |
| Scratch / cue ball off table | 3.1, 2.17 | Foul if the cue ball is pocketed or driven off the table. | |
| Wrong ball first | 3.2 | Foul if the cue ball first contacts a non-legal ball. **Tie rule:** if the legal and non-legal ball are hit "at approximately the same instant" and it can't be determined which was first, assume the legal ball was first. | Resolve ambiguous first contact in the shooter's favour. |
| No contact | 3.3 | Covered by 3.3: "the cue-ball must contact an object-ball" when nothing is pocketed. With 3.2 in effect, missing every ball is also a wrong-ball-first situation. | Report it as its own foul for UX, but it maps to 3.3 (and 3.2). |
| No rail after contact | 3.3, 2.7 | If **no ball is pocketed**, then after the cue ball contacts an object ball, at least one ball (cue ball or object ball) must be **driven to a rail**. Tie rule: if the legal ball and a cushion are hit at the same instant, assume the ball was first. | See "driven to a rail" below. |
| Driven to a rail | 2.7 | The ball must not be touching the rail and then touch it. A ball **frozen** to a rail at the start doesn't count unless it leaves and returns. **A pocketed or off-table ball counts as driven to a rail.** A ball is assumed not frozen unless someone declares it (Reg 26). | Frozen-ball state comes from pre-shot positions plus a tolerance. Default is "not frozen". |
| Object ball off table | 3.5, 2.6 | Driving an object ball off the table is a foul. Whether it is spotted depends on the discipline. **Off table** means it comes to rest off the playing surface without being pocketed, or would have except for hitting a light, chalk, a person, etc. A ball that touches the **rail top and returns** to the bed or enters a pocket is **not** off the table. | "Jumped" in WPA means driven off the table. A jump shot (2.9) is a different thing. |
| Pocketed | 2.2 | Pocketed means at rest in a pocket below the playing surface, or entered the ball return. A ball **hanging, supported by another ball**, counts as pocketed if removing the support would drop it. A ball that sits motionless at the edge for **5 s after the shot** and then drops is **not** pocketed (play is suspended during those 5 s). A ball that rebounds out of a pocket is not pocketed. **If the cue ball touches an already-pocketed ball, the cue ball counts as pocketed.** | Wait about 5 s after motion stops before finalizing "pocketed". Rebounds count as on-table. |
| Balls settling | 1.8 | A ball that settles into a pocket is restored. If it affects the shot, the shot is replayed. | Edge case. Allow a manual "restore" override. |
| Ball in hand | 1.6 | Ball in hand allows placement **anywhere on the playing surface** unless the discipline restricts it to **above the Head String** (most break situations). The cue ball can be moved until the shot is played. | |
| Head String restriction | 3.10, 3.11, 2.1 | 3.10: when restricted, it's a foul to play from **on or below** the Head String. "Above the Head String" excludes the line itself (2.1). 3.11: if the first ball contacted is also above the Head String, it's a foul unless the cue ball **crossed the Head String first**. The cue ball must either cross the Head String or contact a ball on or below it. | Detectable: compare the cue-ball centre (2.13 uses the centre projection) with the Head String. |
| Spot request | 1.6 (para 2) | With ball in hand above the Head String and **all legal balls above the Head String**, the shooter may ask for the legal ball nearest the Head String to be spotted. | Conflicts with 8-ball 4.7 ("No other object-ball is ever spotted"). See Ambiguities. |
| Spotting procedure | 1.5, 2.20 | Spot on the Long String as close as possible to the Foot Spot, between the Foot Spot and the Foot Rail, without moving other balls. Freeze it to an interfering ball if possible, but keep a gap from the cue ball. If the whole line below the spot is blocked, spot above the Foot Spot. | The engine outputs a "spot ball X" instruction. The AR overlay shows where. |
| Three consecutive fouls | 3.13, Reg 8 | Three fouls with no intervening legal shot is a serious foul. In rack-scored games (9-Ball) they must be in **one rack**. **"Some games such as 8-Ball do not include this rule."** A **warning is mandatory** when a shooter on two fouls comes to the table, "Otherwise, a possible third foul will be considered to be only the second." Reg 8: a **visible scoreboard foul count satisfies the warning**. | 9-ball only. The app's on-screen "ON 2 FOULS" banner satisfies Reg 8. |
| Stalemate | 1.13 | Referee warns, then each player gets 3 more turns. If there's still no progress, it's a stalemate. Players may agree to skip the 3 turns. | Manual trigger only. |
| Referee uncertainty | Reg 25 | "If the referee cannot determine whether an athlete fouled, the shot will be considered legal." | **Low-confidence tracking means no foul.** Good default for the engine. |

---

## 2. WPA 8-Ball (§4)

### 2.1 Break (4.3)

| Situation | WPA | Outcome |
|---|---|---|
| Cue ball placement | 4.3(a) | Ball in hand **above the Head String**. |
| Called / first contact | 4.3(b) | No call. Any ball may be hit first. |
| Legal break requirement | 4.3(d) | Pocket ≥1 object ball, **or** drive **≥4 object balls to one or more rails**. |
| Ball pocketed, no foul | 4.3(c) | Breaker continues. **Table stays open** (pocketed balls don't assign groups). |
| Illegal break (no ball pocketed and fewer than 4 to rail) | 4.3(d) | Incoming player chooses: (1) accept the table in position, (2) re-rack and break, or (3) re-rack and have the offender break again. |
| **8 pocketed on a legal break** | 4.3(e) | **Not a foul, not a win.** Breaker chooses: (1) spot the 8 and accept the position, or (2) re-break. |
| **8 pocketed + foul (incl. scratch) on break** | 4.3(f) | Opponent chooses: (1) re-spot the 8 and shoot with **ball in hand above the Head String**, or (2) re-break. **Not a loss.** |
| Any object ball off the table on the break | 4.3(g), 4.7 | **Foul.** Those balls stay out, **except the 8, which is spotted**. Incoming player chooses: (1) accept the table in position, or (2) ball in hand above the Head String. |
| Any other break foul (e.g., scratch without the 8) | 4.3(h) | Incoming player chooses: (1) accept the table in position, or (2) ball in hand above the Head String. |
| Loss-of-rack conditions on the break | 4.8 (last line) | 4.8 losses "do not apply to the break shot." 8 off the table on the break is handled by 4.3(g) and 4.7 (spot it), not loss. |

### 2.2 Open table, groups, calling

| Topic | WPA | Rule |
|---|---|---|
| Open table | 4.4 | The table is open before groups are set. Any ball **except the 8** may be hit first. **Hitting the 8 first on an open table is a foul**, unless a group has been completely pocketed. Then the shooter may temporarily claim that group and play the 8 for the win. |
| Group determination | 4.4 | Each shot, the shooter calls his intended ball. **Legally pocketing the called ball** gives him that group, and the opponent gets the other. If he fails, the table stays open and play passes. Combinations across groups aren't prohibited (only 8-first is). |
| Wrong ball first (groups set) | 4.9 / 3.2 | The first ball contacted must be from the shooter's group, or the 8 once the group is cleared. |
| Call-shot requirements | 4.6, 1.7 | Every shot except the break is called. Call the **ball and pocket only**, and only if "not obvious". Cushions, kisses and other balls are **irrelevant**. Only one ball per shot. The shooter may call **"safety"**. Play then passes and any ball pocketed **stays pocketed**. |
| Obvious shots | 1.7 | WPA gives no formal definition. The referee must be "satisfied that the intended shot was made." The shooter should call banks, combos and similar shots. (CSI defines "not obvious" as bank, kick, combo, non-incidental carom/kiss/cushion, or the referee's judgment.) |
| Continuing | 4.5 | The shooter stays at the table while he **legally** pockets group balls (i.e., the called ball). |
| Extra or uncalled balls | 4.6, 4.7 | Not stated directly. Since "no other object-ball is ever spotted" (4.7), uncalled balls **stay down**. Turn continuation needs the called ball (4.5). |
| Spotting | 4.7 | Only the 8, and only on the break. "No other object-ball is ever spotted." Object balls driven off the table after the break stay out (foul under 3.5). |

### 2.3 Loss of rack (4.8 / 4.10)

| Condition | WPA |
|---|---|
| Pocket the 8 **and foul** on the same shot (incl. scratch) | 4.8(a) |
| Pocket the 8 **before the group is cleared** | 4.8(b) |
| Pocket the 8 in an **uncalled pocket** | 4.8(c) |
| Drive the 8 **off the table** | 4.8(d) |
| **8 + last group ball on the same shot** | **Not stated explicitly.** Follows from 4.8(b) plus 4.6 ("each called ball must be from the athlete's group until the group is cleared ... and then the 8-ball is the called ball"). At the start of that shot the group isn't cleared, so the 8 is pocketed "before his group is cleared". SPEC §3 already mandates a loss. Comment it as "4.8(b) + 4.6 (interpretation)". APA and CSI 2-10(c) state it outright. |
| Scratch/foul while shooting the 8 **without** pocketing it | Standard foul only (4.9). Not a loss. |
| Serious-foul penalty | 4.10: the 4.8 conditions lose the rack. |

### 2.4 Fouls, ball in hand, misc

| Topic | WPA |
|---|---|
| Penalty for a standard foul | 4.9: ball in hand **anywhere** (1.6). |
| Standard fouls listed | 4.9: 3.1–3.12, 3.14, 3.15. **3.13 (three fouls) is not listed**, so there's no 3-foul rule in 8-ball. |
| Behind-head-string cases in 8-ball | Only after break fouls: 4.3(f)(1), 4.3(g)(2), 4.3(h)(2). |
| Stalemate | 4.11: the original breaker re-breaks. |
| Wrong groups discovered | Reg 10: the rack is replayed with the original breaker. |

---

## 3. WPA 9-Ball (§5)

| Topic | WPA | Rule |
|---|---|---|
| Rack | 5.2 | Diamond. 1 at the apex toward the head, 9 in the middle **on the Foot Spot**. |
| Break placement | 5.3(a) | Ball in hand above the Head String. |
| First contact on the break | 5.7 / 3.2 | 3.2 applies "on each shot": the first ball contacted must be the **lowest-numbered (the 1)**. 5.3 doesn't repeat this. It comes from 5.7. |
| 4-ball rule | 5.3(b) | If no ball is pocketed, **≥4 object balls to rails**, "or the shot is a foul". Ball in hand anywhere for the opponent (5.7). |
| Three-ball rule | 5.3(c), Reg 16 | Fewer than 3 object balls **pocketed or crossing the Head String** (ball centre beyond the line) is an "illegal break". The incoming player may accept the table as is (**no push-out allowed**, Reg 16(3)) or hand it back. If handed back, the breaker **may push out**, and the opponent may again play or hand back (Reg 16(4)). If the 9 is pocketed on such a break, it's **spotted** (Reg 16(5)). Reg 16 is mandatory for WPA ranking events. Make it a toggle. |
| Push-out eligibility | 5.4 | Only on the **shot immediately after a break with no foul**. "The shooter" means the breaker if he pocketed a ball and continues, otherwise the incoming player (also DD #16). He **must announce it**. |
| Push-out mechanics | 5.4 | **3.2 (wrong ball first) and 3.3 (no rail) are suspended.** All other fouls still apply (scratch, off table, double hit, etc.). If there's no foul, **the other player chooses who shoots next**. |
| Balls pocketed on a push-out | 5.5, 5.6 | The shooter does **not** continue (5.5 excludes push-outs). The **9 is spotted** (5.6). Other balls **stay down** (5.6 "No other object-ball is ever spotted"). |
| Push-out with a foul | 5.4, 5.7 | Standard foul: ball in hand anywhere for the opponent. (Push-outs count as turns in doubles, Reg 27(4).) |
| Lowest ball first | 5.7 / 3.2 | Every shot: the first contact must be the lowest-numbered ball on the table. Slop counts. Nothing is called. |
| Continuing | 5.5 | Legally pocket any ball and continue. With no foul and no pocket, the incoming player plays from the position left (no ball in hand). |
| Win | 5 (intro), 5.5 | Legally pocketing the 9 on any shot except a push-out wins, **including on the break** (subject to Reg 16(5)). |
| 9 pocketed on a foul | 5.6 | **Spotted.** Opponent gets ball in hand. |
| 9 off the table | 5.6, 5.7/3.5 | Spotted (and it's a foul). "The only jumped object-ball that is spotted is the 9-ball." |
| Other balls off the table | 5.7/3.5 | Foul, ball **stays out** (not spotted). |
| Fouls | 5.7 | 3.1–3.10, 3.12, 3.14, 3.15. **Ball in hand anywhere** after all fouls, including break fouls. 3.11 isn't listed because there's no head-string ball in hand after a foul. |
| Three consecutive fouls | 5.8, 3.13, Reg 8 | **Loss of rack.** Fouls must be in a single rack. **Warning required** when a player on 2 fouls comes to the table. Without it, the third foul counts as the second. A visible scoreboard satisfies this (Reg 8). |
| Stalemate | 5.9 | The original breaker re-breaks. |

---

## 4. Bar / slop 8-ball conventions (US)

There is no single authority for this. CM and DD-bar describe *old-school* bar rules: call every detail, kitchen ball in hand on a scratch only. APA is the largest US amateur league and the de facto modern "slop" rule set. Its rules are slop plus mark the 8, ball in hand anywhere, 8 on the break wins. **Recommendation: APA as the base.** Each row below is a `RULES.md` decision point.

| # | Decision point | Most common convention (pick) | Source | Main alternative(s) |
|---|---|---|---|---|
| B1 | Slop counts (no calling except the 8) | **Yes.** Any legally pocketed group ball counts. Only the 8's pocket is called. | APA `otm-pocketed-balls/` ("does not need to designate ... except ... the 8-ball"). DD-lg ("Slop counts") | Call-shot ball+pocket (CSI 1-16, WPA 4.6). Old bar "call all the details" (CM §2, DD-bar). |
| B2 | Legal break requirement | **≥4 balls to rails or ≥1 ball pocketed.** Illegal break: **same breaker re-breaks** after the opponent re-racks. | APA `breaking/` | Just hit the rack (CM §6). Opponent's choice: accept, re-break, or make the offender re-break (VNEA B.2, WPA 4.3(d)). |
| B3 | Groups from the break | **Take what you make.** Only one group pocketed on the break gives the breaker that group. Both groups pocketed leaves the table open. | APA `after-the-break/` (c, d). CM §11. DD-bar | Majority group wins (DD-bar, some CM areas). Always open after the break (WPA 4.3(c), CSI 2-5, VNEA). |
| B4 | 8 pocketed on the break (no foul) | **Win.** | APA `after-the-break/`, DD-lg, DD-bar, CM §9, VNEA B.7 Option 1 | Spot or re-rack at breaker's choice (WPA 4.3(e), CSI 2-4.1, VNEA Option 2). |
| B5 | 8 on the break **+ scratch / cue ball off table** | **Loss.** | APA ("unless the shooter also fouls the cue ball ... loss"), DD-bar, CM §9, VNEA Option 1 | Opponent may spot the 8 + ball in hand, or re-rack (WPA 4.3(f): kitchen; CSI 2-4.2: anywhere). |
| B6 | Scratch on the break (no 8) | **Not a loss.** Opponent gets **ball in hand behind the head string** and must shoot a ball outside the kitchen or cross the line first. Pocketed balls stay down. | APA `fouls/` and `after-the-break/` (league years 26/27+), VNEA B.3/B.5, CM §7, DD-bar. WPA 4.3(h) is also kitchen. | Ball in hand anywhere (CSI 2-3.4). APA *illegal* break + scratch: **opponent re-breaks** (APA `breaking/`). |
| B7 | Ball in hand after a normal foul | **Anywhere on the table.** | APA `fouls/`, VNEA, CSI, WPA 4.9 | Old bar: only a scratch gives ball in hand, in the kitchen. Other fouls are loss of turn only (CM §15, DD-bar). |
| B8 | Which fouls give ball in hand | **Cue-ball fouls only.** Scratch or cue ball off the table, **wrong ball first**, **no ball contacted**, **no rail after contact**, touching or double-hitting the cue ball. Accidentally moving an object ball isn't a foul. | APA `fouls/` (a–k: "the only fouls resulting in ball-in-hand"). DD-lg ("Only CB fouls"). | All-ball fouls (WPA 3.6). Bar: wrong ball first and no rail aren't penalized, or are loss of turn only (CM §12, DD-bar). |
| B9 | Scratch while shooting the 8 (8 not pocketed) | **Loss of game.** | APA `how-to-win-a-game/` ("scratches or knocks the cue ball off the table when playing the 8-ball"), DD-lg ("even if missed"), DD-bar, CM §21 | Foul only, ball in hand (WPA 4.8 / 4.9, CSI 2-9.2). |
| B10 | Non-scratch foul on the 8 (e.g., wrong ball first, 8 not pocketed) | **Foul only (ball in hand), not a loss.** | APA (only the listed loss conditions apply) | Loss if you hit the opponent's ball before the 8 and the 8 drops (CM §21). Loss of turn only (DD-bar). |
| B11 | Calling or marking the 8 pocket | **Required.** Mark the intended pocket (coaster, chalk). An unmarked 8 loses if the opponent calls it. | APA `how-to-win-a-game/`, DD-lg. CM §20. SPEC §3 | Verbal call only (most bars). App: auto-infer per SPEC (predicted line plus tap to override). |
| B12 | 8 in the wrong pocket | **Loss.** | APA, CSI 2-10(a), WPA 4.8(c), CM §21 | None common. |
| B13 | 8 pocketed early (group not cleared) | **Loss.** | APA ("out-of-turn"), WPA 4.8(b), CSI 2-10(a), CM §21 | None common. |
| B14 | 8 + last group ball, same shot | **Loss.** | APA `how-to-win-a-game/`, CSI 2-10(c), CM §20–21 | None common. WPA reaches the same result by interpretation. |
| B15 | 8 off the table | **Loss** (on any shot after the break). | APA `balls-on-the-floor/`, CSI 2-10(b), WPA 4.8(d), CM §19 | On the break: spot it (WPA 4.3(g), CSI 2-3.5). VNEA: loss even on the break (DD-lg). Pick: **loss on the break too** (APA has no break exception; unverified for APA). |
| B16 | 8 must go "clean" (no combo or kiss) | **No.** Any legal pocketing of the 8 in the marked pocket wins. | APA (only requires a marked pocket) | 8 can't be pocketed by combo or carom, and you lose if it is (CM §21, DD-bar "cannot be used in a combination or kiss"). |
| B17 | Hitting the 8 first on an open table | **Foul** (APA: ball in hand). The 8 can't be first in a combo. | APA `after-the-break/` ("which would be a foul ... never neutral"), WPA 4.4, CSI 2-5 | VNEA: allowed (DD-lg). Old bar: loss of turn (CM §11). |
| B18 | Ball pocketed on a foul / uncalled | **Stays down.** It counts for whoever owns that group. | CSI 2-3.4, 2-7.2. CM §18. WPA 4.7. APA: not stated explicitly (inferred from its slop rule; unverified) | Spot accidental balls (DD #11 note, only on non-coin tables). |
| B19 | Object ball off the table (non-8) | **Spotted on the foot spot.** Not a foul per APA (spotted at end of turn). | APA `balls-on-the-floor/`, CM §8/§19 (spotted + loss of turn) | Not spotted, counts as pocketed for its owner, foul (WPA 3.5/4.7, CSI 2-7.2). |
| B20 | "Two shots" / "two visits" after a foul | **Not a US convention. Don't implement.** It's a UK pub / old blackball rule. Even WPA Blackball now uses a single "free shot" (WPA 8.13). | WPA §8 (Blackball "Free Shot", 8.13) | Optional house-rule toggle only. Unverified as a US bar practice (no US source found). |
| B21 | Three-foul rule | **None.** | WPA 3.13 ("8-Ball do not include"), APA (none listed) | None. |
| B22 | Safeties | **Allowed** (APA allows calling a safety; unverified). Irrelevant to automatic detection: with slop, any pocketed group ball continues the turn unless a safety is declared. | | Old bar: safeties are "dirty pool" (DD-bar, CM §13). Not enforceable. |
| B23 | Push shot, double hit, scoop jump | Double hit is a ball-in-hand foul (APA h). Intentional scoop is a foul (APA e). | APA `fouls/` | Not called in bars (DD-bar). Not detectable anyway (§5). |
| B24 | Stalemate | Re-rack, same breaker. | APA `stalemates/` (title only; unverified detail), WPA 4.11 | "Whack it" (CM §22). |
| B25 | Who breaks next | Winner breaks (bar "challenge table"). | CM §4 | Alternate breaks (WPA 1.3, leagues). |

---

## 5. WPA details that are hard or impossible to detect from overhead tracking (scope-out list)

| WPA rule | Detail | Why it's hard | Suggested handling |
|---|---|---|---|
| 3.4 | No foot on floor | Off-camera | Out of scope |
| 3.6 | Touched ball (hand, cue, clothing, bridge moves a ball) | Partly detectable (a ball moves with no ball-ball contact), but the cause can't be attributed | Flag "unexplained ball motion" for manual confirmation |
| 3.7 | Double hit / frozen-ball push-through | Tip-ball contacts last milliseconds and the tip is occluded overhead. Needs high-fps side view | Out of scope |
| 3.8 | Push shot (prolonged tip contact) | Same as above | Out of scope |
| 2.9, 2.11 | Jump legality (legal elevated jump vs scoop or miscue) and miscue | Overhead 2D can't see ball height or the stroke. An unintentional miscue jump counts as legal | Out of scope. Treat every jump as legal. |
| 2.7, 3.7, Reg 26 | **Frozen** status (ball to rail, cue ball to ball) | Requires a declaration, and pixel gaps below about 1 mm aren't resolvable | Auto-flag "possibly frozen" under a threshold. The user confirms. |
| 3.2 / 3.3 | Near-simultaneous first contact (ball-ball or ball-cushion) | Needs sub-frame timing | Use the rule's own tie-break: legal ball first (3.2/3.3), plus Reg 25 (uncertain means legal) |
| 2.6 | Off table after hitting a light, chalk or person and returning; ball resting on the rail top | Ball leaves the frame or is occluded. Rail-top balls are hard to tell from on-table balls | Track disappearance outside the bed polygon. Allow manual override. |
| 2.2 | Ball supported in the pocket jaws by another ball; 5-second hanging rule; rebounds | Pocket interior occlusion | Use a 5 s settle timer plus a disappearance heuristic. Allow manual override. |
| 1.8 | Settling ball drops later | Timing and intent | Manual "restore" |
| 1.10 | Outside interference | Context | Manual "replay shot" |
| 3.9 | Balls still moving (spinning) when the next shot starts | Translation is detectable. Spin in place is weakly detectable | Detect translation only |
| 3.12 | Playing out of turn | Depends on identifying the shooter (SPEC §5.8) | Detect if player ID is reliable. Otherwise manual |
| 3.14 | Slow play / shot clock | Detectable but a policy choice | Optional shot clock |
| 3.15, 3.16, Reg 17 | Rack template foul, unsportsmanlike conduct, deflecting the cue ball on the break | Intent / off-table objects | Out of scope |
| 1.7 | Call shot "obvious" judgment | Subjective | SPEC: auto-infer the pocket at stroke start, tap to override |
| 1.6 | Moving the cue ball in hand with a forward stroke | Ambiguous with the start of a shot | Treat the first forward-stroke contact as the shot |
| Reg 10 | Wrong group shot and noticed later | Needs a replay | Not an issue: the engine knows groups and will flag it immediately |

**Detectable** (in scope): scratch (3.1), cue or object ball off table (3.1/3.5, with caveats), wrong ball first and no contact (3.2), no rail after contact (3.3), head-string placement and crossing (3.10/3.11), Reg 16 head-string crossing count, pocketed balls and pockets (2.2), 4-balls-to-rail on the break (4.3(d), 5.3(b)).

---

## Ambiguities and decisions to flag

1. **8 + last group ball (WPA):** not explicit in 4.8. It's implied by 4.8(b) + 4.6. SPEC mandates a loss, which matches CSI 2-10(c) and APA.
2. **WPA 4.3(e) "spot the 8 and accept balls in position":** the text doesn't say whether the breaker keeps shooting. 4.3(c) suggests yes (a ball was pocketed without a foul). CSI 2-4.1 also reads as the breaker continuing. Proposal: breaker continues.
3. **WPA 4.3(h)(1) "accept the table in position" after a scratch on the break:** this is meaningless when the cue ball is in the pocket. In practice only option (2), kitchen ball in hand, applies. Proposal: on a break scratch, auto-select kitchen ball in hand. Offer option (1) only for non-scratch break fouls.
4. **WPA 1.6 spot request vs 8-ball 4.7 "no other ball is ever spotted":** in 8-ball, after a break foul with every legal ball above the Head String, 1.6 allows a spot but 4.7 forbids it. 4.7 is discipline-specific, so it overrides general rules ("except when contradicted", §1 intro). Proposal: no spot in 8-ball. In 9-ball there's never kitchen ball in hand after a foul, so the question doesn't come up.
5. **9-ball break first contact:** 5.3 omits "must hit the 1 first". It comes from 5.7 / 3.2 "on each shot". DD agrees (lowest ball always first).
6. **Reg 16 (three-ball rule)** is a Regulation, not a Rule, and it's mandatory only for WPA ranking events. Expose it as a 9-ball toggle (default on to match 5.3(c)).
7. **APA break-scratch placement changed:** the APA site says ball in hand behind the head string applies for league years 26/27–28/29. Earlier years said only "ball-in-hand for the opponent". I used the current text. CSI uses anywhere.
8. **Bar rules have no canonical text.** Old-school bar rules (CM, DD-bar) contradict APA-style slop on calling, ball-in-hand placement, rails, and the 8 going clean. SPEC wants slop, so APA is the natural base. B9 (scratch on the 8 loses even if the 8 isn't pocketed) is the main rule that surprises WPA players.
9. **APA items marked unverified:** ball-on-foul stays down (B18), 8 off the table on the break (B15), safety call (B22), stalemate detail (B24). The APA pages I read don't state them explicitly.
