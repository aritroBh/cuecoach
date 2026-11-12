# SwiftData schema (proposal — awaiting user review)

Three **separate `ModelContainer`s with separate store files**. Training data cannot leak into competitive
stats by construction: no model type is registered in two stores, and no relationship crosses stores.

```
Competitive.store (backed up)        Training.store (backed up)          Recognition/Recognition.store
├─ PlayerProfile                     ├─ TrainingProfile (playerID: UUID)  (NOT backed up, .complete)
├─ Session ──1:N── Game ──1:N── Shot ├─ DrillProgress ──1:N── Attempt     └─ RecognitionData (profileID: UUID)
├─ ArchetypeSnapshot                 └─ BiasRecord
└─ Highlight (N per game)
```

Schema versions: Competitive V1 (RecognitionData inside) → **V2** (custom stage moves every RecognitionData row
to Recognition.store, writes `.Competitive.scrub-pending`, deletes the rows here; every open then retries the
scrub (remove the old external-blob folder, VACUUM, WAL checkpoint(TRUNCATE) checked for busy) until it succeeds
and clears the marker; while it is pending Competitive.store and its sidecars are excluded from backup, so no
template bytes reach a device backup even after a crash or a failed scrub) → **V3** (D43, lightweight stage: adds
`Shot.isGuess`, default false, so every V2 row opens as not a guess; V1 and V2 list a frozen
`CompetitiveSchemaV2.Shot`). Training V1. Recognition V1.

## Competitive store

| Model | Fields | Notes |
|---|---|---|
| `PlayerProfile` | `id: UUID` (unique), `name`, `avatarSymbol`, `avatarColor`, `isLocalOwner: Bool`, `createdAt`, `skillModel: SkillModel` (Codable: aim/speed/spin noise σ, n samples), `recognitionRevokedAt: Date?` (V2; revocation tombstone, exported, merged max-wins) | One local owner per phone; peers' profiles cached only for the session (`isSessionGuest`) and purged on session end (with their templates). A backup profile that matches a guest id is promoted to a saved profile; promotion drops the guest's session templates (and tells the galleries) unless the person consents then (`importBackup(_:keepingRecognitionOf:)`, `promoteSessionGuest(_:keepRecognition:)`); without consent it also moves `recognitionRevokedAt` to now, so a late session capture is refused. |
| `Session` | `id`, `startedAt`, `endedAt?`, `ruleSet: RuleSetID`, `format: GameFormat`, `tableSize: TableSize`, `peerDeviceNames: [String]`, `voteTally: [RuleSetID: Int]` | |
| `Game` | `id`, `session`, `index`, `ruleSet`, `teams: [Team]` (Codable: member player IDs, shooting order), `winnerTeam: Int?`, `winProbSeries: [Double]`, `startedAt`, `endedAt?` | Shooting order editable mid-game → stored as order-change events inside `teams`. |
| `Shot` | `id`, `game`, `index`, `shooterID: UUID`, `attributionSource` (auto/turnOrder/tap), `preState: TableState`, `postState: TableState`, `calledPocket: Pocket?`, `firstContact: BallID?`, `railsAfterContact: Int`, `pocketed: [BallID: Pocket]`, `fouls: [Foul]`, `features: ShotFeatures` (cut bucket, distance bucket, pocket type, kind bank/combo/kick/rail/jump/safety), `made`, `onTarget`, `cueResult` (inZone/outOfZone/nA), `decisionRating`, `executionRating`, `wpaDelta: Double`, `isClutch`, `timeOnShot: Double`, `clipRef: String?`, `isGuess: Bool` (V3, default false; `pocketed` is a D31 best guess; never counted in pot %, cut, distance or pocket stats) | Table states stored as Codable value types from `Geometry`. |
| `ArchetypeSnapshot` | `playerID`, `computedAt`, `gamesCount`, `shotsCount`, `vector: [String: Double]`, `tags: [ArchetypeTag]`, `proComp: ProComp?` | Append-only → evolution history. |
| `Highlight` | `game`, `shotID`, `kind` (shotOfGame/mvp), `clipFile: String` (relative path in app container), `label: String` (≤2 words), `score: Double` | Clips stay in-app (no Photos export). |

Per-game and career aggregates are **computed** from `Shot` rows by `Stats` (pure Swift) and cached in
memory, not persisted, so they can never drift from source data.

## Recognition store

Directory `Application Support/Recognition/`, `isExcludedFromBackup` on the directory and every file, file
protection `.complete`. D26: face and appearance templates persist with the profile, no automatic expiry.

| Model | Fields | Notes |
|---|---|---|
| `RecognitionData` | `id`, `profileID: UUID`, `faceEmbedding: Data?`, `appearanceEmbedding: Data?` (external storage), `optedInAt`, `version`, `updatedAt` | One row per profile (`storeRecognition` replaces). Refused if opted in at or before the profile's `recognitionRevokedAt`. Orphans pruned on open; `deleteProfile` removes both. **Never exported.** |

"Delete recognition data" (one tap): `beginRecognitionDeletion()` snapshots the rows in memory, removes them
from the context unsaved, writes an empty `.pending-delete` marker, and tells every `RecognitionGallery`
`.purgedAll`. Undo → `undoRecognitionDeletion(_:)`. Window closes / app backgrounds → `deleteMyRecognitionData()`:
deletes every row, destroys the store files (`deleteAllData`), stamps every profile's `recognitionRevokedAt`
(the store held rows for any of them), then removes the marker. A
marker found at launch means the app died in the window: the stack commits the delete.

## Training store

| Model | Fields |
|---|---|
| `TrainingProfile` | `playerID: UUID` (plain value, not a relationship), `createdAt` |
| `DrillProgress` | `drill: DrillID`, `level: Int (1–4)`, `recentResults: [Bool]` (rolling window), `levelHistory: [LevelChange]` |
| `TrainingAttempt` | `progress`, `at`, `setup: TableState`, `result: TableState`, `made`, `features: AttemptFeatures` (signed cut error, signed speed error, cue-ball landing error, spin intended vs observed) |
| `BiasRecord` | `drill`, `axis` (cut/side/speed/cueDistance/spin), `sign`, `attemptsWindow`, `detectedAt`, `resolvedAt?` |

## Backup JSON
`BackupV1 { version: 1, exportedAt, competitive: {profiles, sessions, games, shots, archetypes}, training: {...} }`
Recognition templates are never exported; a legacy file's `includesRecognition` / `recognition` keys are ignored.
A shot record's `isGuess` is optional: a file without it (written before V3) imports as `false`; the version stays 1.
Non-finite Doubles are written as the strings `"Infinity"`, `"-Infinity"`, `"NaN"`. Dates must be valid calendar instants (no roll-over). Import refuses while a store has unsaved edits.
— plain `Codable` DTOs (not the `@Model` classes) so the format is stable. Import merges by UUID; the newer
`updatedAt` wins. Clips aren't included (size); highlights keep their metadata.
