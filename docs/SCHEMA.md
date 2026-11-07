# SwiftData schema (proposal — awaiting user review)

Two **separate `ModelContainer`s with separate store files**. Training data cannot leak into competitive
stats by construction: no model type is registered in both, and no relationship crosses stores.

```
Competitive.store                          Training.store
├─ PlayerProfile ──1:1── RecognitionData   ├─ TrainingProfile (playerID: UUID, no relationship)
├─ Session ──1:N── Game ──1:N── Shot       ├─ DrillProgress ──1:N── TrainingAttempt
├─ ArchetypeSnapshot (N per player)        └─ BiasRecord
└─ Highlight (N per game)
```

## Competitive store

| Model | Fields | Notes |
|---|---|---|
| `PlayerProfile` | `id: UUID` (unique), `name`, `avatarSymbol`, `avatarColor`, `isLocalOwner: Bool`, `createdAt`, `skillModel: SkillModel` (Codable: aim/speed/spin noise σ, n samples) | One local owner per phone; peers' profiles cached only for the session (`isSessionGuest`) and purged on session end. |
| `RecognitionData` | `faceEmbedding: Data?`, `appearanceEmbedding: Data?`, `optedInAt`, `version` | Separate entity, `.cascade` from profile. "Delete my recognition data" = delete this row. Never exported in JSON backups unless the user ticks it. |
| `Session` | `id`, `startedAt`, `endedAt?`, `ruleSet: RuleSetID`, `format: GameFormat`, `tableSize: TableSize`, `peerDeviceNames: [String]`, `voteTally: [RuleSetID: Int]` | |
| `Game` | `id`, `session`, `index`, `ruleSet`, `teams: [Team]` (Codable: member player IDs, shooting order), `winnerTeam: Int?`, `winProbSeries: [Double]`, `startedAt`, `endedAt?` | Shooting order editable mid-game → stored as order-change events inside `teams`. |
| `Shot` | `id`, `game`, `index`, `shooterID: UUID`, `attributionSource` (auto/turnOrder/tap), `preState: TableState`, `postState: TableState`, `calledPocket: Pocket?`, `firstContact: BallID?`, `railsAfterContact: Int`, `pocketed: [BallID: Pocket]`, `fouls: [Foul]`, `features: ShotFeatures` (cut bucket, distance bucket, pocket type, kind bank/combo/kick/rail/jump/safety), `made`, `onTarget`, `cueResult` (inZone/outOfZone/nA), `decisionRating`, `executionRating`, `wpaDelta: Double`, `isClutch`, `timeOnShot: Double`, `clipRef: String?` | Table states stored as Codable value types from `Geometry`. |
| `ArchetypeSnapshot` | `playerID`, `computedAt`, `gamesCount`, `shotsCount`, `vector: [String: Double]`, `tags: [ArchetypeTag]`, `proComp: ProComp?` | Append-only → evolution history. |
| `Highlight` | `game`, `shotID`, `kind` (shotOfGame/mvp), `clipFile: String` (relative path in app container), `label: String` (≤2 words), `score: Double` | Clips stay in-app (no Photos export). |

Per-game and career aggregates are **computed** from `Shot` rows by `Stats` (pure Swift) and cached in
memory, not persisted, so they can never drift from source data.

## Training store

| Model | Fields |
|---|---|
| `TrainingProfile` | `playerID: UUID` (plain value, not a relationship), `createdAt` |
| `DrillProgress` | `drill: DrillID`, `level: Int (1–4)`, `recentResults: [Bool]` (rolling window), `levelHistory: [LevelChange]` |
| `TrainingAttempt` | `progress`, `at`, `setup: TableState`, `result: TableState`, `made`, `features: AttemptFeatures` (signed cut error, signed speed error, cue-ball landing error, spin intended vs observed) |
| `BiasRecord` | `drill`, `axis` (cut/side/speed/cueDistance/spin), `sign`, `attemptsWindow`, `detectedAt`, `resolvedAt?` |

## Backup JSON
`BackupV1 { version: 1, exportedAt, competitive: {profiles, sessions, games, shots, archetypes}, training: {...}, includesRecognition: Bool }`
— plain `Codable` DTOs (not the `@Model` classes) so the format is stable. Import merges by UUID; the newer
`updatedAt` wins. Clips aren't included (size); highlights keep their metadata.
