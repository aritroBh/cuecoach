# Mesh + player identity: research and design proposal (SPEC §5.7, §5.8, D3)

Compiled 2026-11-06. Research and design only, no code. Every external claim has a source key from the table below. **Unverified** means I could not confirm it from a primary source. **Assumption** means a number I picked that we have to measure on the two real phones.

> **Blocking finding: needs a user decision before Phase 5 starts.** Apple deprecated the whole
> Multipeer Connectivity framework in Xcode 27 [TN3213]. `MCSession` availability now reads
> "iOS 7.0 – 27.0" [MCS]. The spec (§2, §5.7) and `CLAUDE.md` say "MultipeerConnectivity only".
> I recommend **Network framework (Bonjour + peer-to-peer Wi-Fi) behind a `MeshTransport` protocol**.
> It needs no entitlement, works with a Personal Team and makes no internet calls. MPC stays possible
> as a second adapter. Product ambiguity means we stop and ask, so this is Open Question **Q1** (§10).
> The rest of this doc is written so the design holds whichever transport the user picks.

## Sources

| Key | Source | URL |
|---|---|---|
| TN3213 | Apple TN3213 "Moving from Multipeer Connectivity to Network framework" (republished 2026-07-14) | https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework |
| TN3179 | Apple TN3179 "Understanding local network privacy" (rev. 2026-10-06) | https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy |
| MCS | Apple docs, `MCSession` (8-peer limit, availability metadata) | https://developer.apple.com/documentation/multipeerconnectivity/mcsession |
| MPC | Apple docs, Multipeer Connectivity framework overview (background behavior) | https://developer.apple.com/documentation/multipeerconnectivity |
| MAXP | Apple docs, `MCBrowserViewController.maximumNumberOfPeers` (default/max 8) | https://developer.apple.com/documentation/multipeerconnectivity/mcbrowserviewcontroller/maximumnumberofpeers |
| Q776069 | Apple DTS (Quinn), "Moving from Multipeer Connectivity to Network Framework" forum post | https://developer.apple.com/forums/thread/776069 |
| F803339 | Apple forums, "Multipeer Connectivity connection is flaky on iOS 26" (DTS replies) | https://developer.apple.com/forums/thread/803339 |
| F811978 | Apple forums, MPC stuck in `.connecting` with Mobile Data on (DTS replies) | https://developer.apple.com/forums/thread/811978 |
| F836124 | Apple forums, MPC background operation (DTS: stops once suspended) | https://developer.apple.com/forums/thread/836124 |
| WWDC25-250 | WWDC25 session 250, Network framework async API (`NetworkConnection`/`Listener`/`Browser`, `Coder`, TLV) | https://developer.apple.com/videos/play/wwdc2025/250 |
| P2P-sample | Apple sample "Building a custom peer-to-peer protocol" | https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol |
| WIFIAWARE | Apple docs, Wi-Fi Aware framework (iOS 26+, iPhone 12+, entitlement) | https://developer.apple.com/documentation/wifiaware |
| ESP-WA | Espressif, "Wi-Fi Aware ESP to iPhone" (Wi-Fi Aware is a *managed* capability; request form) | https://developer.espressif.com/blog/2026/08/wifi-aware-esp-to-iphone/ |
| CAPS | Apple "Supported capabilities (iOS)" | https://developer.apple.com/help/account/reference/supported-capabilities-ios |
| AWDL | Stute et al., "One Billion Apples' Secret Sauce" (AWDL), MobiCom '18 | https://arxiv.org/abs/1808.03156 |
| AWDL-lat | Blog measurement: LAN latency with AWDL on vs off (informal, single user) | https://adamlovattdevops.github.io/awdl-latency-killer/ |
| OBJC | objc.io, "Multipeer Connectivity in Games" (send modes, message sizes) | https://www.objc.io/issues/18-games/multipeer-connectivity-for-games |
| RFC5905 | NTPv4 (offset/delay equations, clock filter) | https://www.rfc-editor.org/rfc/rfc5905 |
| SYNCCLK | Apple docs, `AVCaptureSession.synchronizationClock` | https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock |
| VFP | Apple docs, `GenerateImageFeaturePrintRequest` (iOS 18+) | https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest |
| VFACEQ | Apple docs, `VNDetectFaceCaptureQualityRequest` | https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest |
| VFACEOBS | Apple docs, `VNFaceObservation` (landmarks/pose/quality, no identity field) | https://developer.apple.com/documentation/vision/vnfaceobservation |
| F79961 | Apple forums, "Face Recognition in Vision Framework?" (Vision = detection, not recognition) | https://developer.apple.com/forums/thread/79961 |
| VHUMAN | Apple docs, `VNDetectHumanRectanglesRequest.upperBodyOnly` | https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest/upperbodyonly |
| VINST | Apple docs, `VNGeneratePersonInstanceMaskRequest` (iOS 17+) | https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest |
| VSEG | Apple docs, `VNGeneratePersonSegmentationRequest` (iOS 15+, single matte) | https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest |
| VPOSE | Apple docs, `VNDetectHumanBodyPoseRequest` | https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest |
| VPOSE3D | Apple docs, `VNDetectHumanBodyPose3DRequest` (iOS 17+) | https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest |
| SFACE | OpenCV Zoo `face_recognition_sface` README (Apache-2.0, MobileFaceNet + SFace loss) | https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/README.md |
| INSIGHT | InsightFace repo (code MIT; pretrained models non-commercial research only) | https://github.com/deepinsight/insightface |
| OSNET | Zhou et al., "Omni-Scale Feature Learning for Person Re-ID" (OSNet) | https://arxiv.org/abs/1905.00953 |
| OSNET-LIC | LibreYOLO OSNet-AIN port (MIT weights from Torchreid; datasets have research terms) | https://huggingface.co/LibreYOLO/LibreReID-osnet |
| SWIFTCERT | apple/swift-certificates (Apache-2.0; create X.509 certs locally) | https://github.com/apple/swift-certificates |
| BIPA | Illinois Biometric Information Privacy Act, 740 ILCS 14 | https://www.ilga.gov/legislation/ilcs/ilcs3.asp?ActID=3004&ChapterID=57 |
| BIPA-txt | BIPA full text (Akin Gump copy) | https://www.akingump.com/a/web/101105/Biometric-Information-Privacy-Act-740-ILCS-14-1-et-seq..pdf |

---

## 1. Findings: the transport

### 1.1 Multipeer Connectivity on iOS 27

| Topic | Finding | Source |
|---|---|---|
| Status | "Xcode 27 deprecates the entire Multipeer Connectivity framework … plan to migrate your code to Network framework." `MCSession` availability: iOS 7.0–27.0. It still runs on iOS 27, but every use now builds with a deprecation warning. | TN3213, MCS |
| Max peers | "Sessions currently support up to 8 peers, including the local peer." The constant is informational; Quinn says it is hard-coded. More than 8 needs multiple sessions. | MCS, MAXP |
| Topology | Fully connected: "every peer is effectively connected to every other peer." | TN3213 |
| Send modes | `.reliable` / `.unreliable`. Best-effort fits latency-sensitive data where a retransmit would arrive stale. `send(_:)` suits small event data of a few kB. | TN3213, OBJC |
| Throughput / latency | DTS: "good latency but poor throughput". **No flow control (back pressure).** No published benchmark numbers found. | Q776069 |
| Big payloads | `sendResource(at:…)` sends a file with an `NSProgress`. Streams use `NSStream`, which is "scheduled for deprecation" for networking. | MCS, Q776069 |
| Reliability on iOS 26+ | DTS-acknowledged regressions: (a) peers go `.connecting` → `.notConnected` again and again. Suspected cause: AWDL torn down before MPC finishes. It shows when Wi-Fi is on but not joined to a network, and works when both devices share a Wi-Fi network. (b) With Mobile Data on, peers stay in `.connecting` forever. DTS: there is no supported way to detect or recover; "stop using Multipeer." | F803339, F811978 |
| Background | "If the app moves into the background, the framework stops advertising and browsing and disconnects any open sessions." On return, the app must re-establish sessions. | MPC, F836124 |
| Security | `MCEncryptionPreference` none / optional / required. Required needs a PKI identity. Optional "doesn't yield any actual security benefits". | TN3213 |
| Side effect | MPC always turns on peer-to-peer Wi-Fi (AWDL), which can hurt network performance. Informal measurement: LAN latency averaged 25.4 ms with AWDL on vs 4.3 ms off. | Q776069, AWDL-lat |

### 1.2 Network framework (the recommended replacement)

| Topic | Finding | Source |
|---|---|---|
| API | iOS 26+ Swift-concurrency API: `NetworkListener` (with `.bonjour(name:type:txtRecord:)`), `NetworkBrowser(for: .bonjour(...))` and `withNetworkConnection(to:using:)`. The protocol stack is a builder (`TLS()`, `QUIC(alpn:)`, `TCP()`). | TN3213, WWDC25-250 |
| Architecture | Supports client–server: "Many apps work better with the client-server architecture … If you previously struggled with the fully connected network architecture, use this opportunity to switch." This matches our host-owns-state model (§5.7). | TN3213 |
| Peer identity | Use your own random `UUID` as peer ID. Remove duplicate connections by ID. Think about privacy before you persist it, and rotate it if you do. | TN3213 |
| Send modes | QUIC gives many reliable streams plus **one best-effort datagram channel** (`connection.datagrams`). "If you're not sure which reliable protocol to use, choose QUIC." | TN3213 |
| Framing | Built-in `TLV(type:length:)` and `Coder(Message.self, using: .json)` framers. | TN3213, WWDC25-250 |
| Flow control | Async `send` waits when the send buffer is full, so a plain loop gives back pressure. Skipping it risks jetsam. **This is how we send clips.** | TN3213 |
| Resources | No `sendResource` equivalent. Build file transfer on a stream with flow control. | TN3213 |
| Peer-to-peer Wi-Fi | Off by default. Turn it on with `.peerToPeerIncluded(true)`. It "can reduce network performance" for this app and others; stop browsing as soon as you pick a peer. | TN3213 |
| Security | QUIC always has TLS. Mutual TLS with a custom validator is the pattern. Apple has **no API to create a digital identity locally**, so use a library such as swift-certificates. TLS-PSK works only with the old `NWConnection` API, has no TLS 1.3 and no QUIC. | TN3213, SWIFTCERT |
| Defaults to tune | By default TCP keepalives are off and the TCP send timeout is infinite. QUIC's idle timeout defaults to 30 s and QUIC keepalives are off. Tune all of these for a LAN. | TN3213 |
| Proven on iOS 26? | DTS asked reporters to test the Network-framework TicTacToe sample to isolate AWDL vs MPC. In F803339 the reporter's results are ambiguous (**unverified** whether the sample also failed when Wi-Fi was on but not joined). Every report agrees that shared infrastructure Wi-Fi worked. DTS says developers who migrated "often" no longer hit these issues. | F803339, F811978, P2P-sample |

### 1.3 Wi-Fi Aware (rejected for now)

Wi-Fi Aware is iOS 26+ on iPhone 12 and later, so both test phones qualify. It needs the `com.apple.developer.wifi-aware` entitlement [WIFIAWARE], which is a **managed capability granted by request form** [ESP-WA]. It is not on the standard capabilities list [CAPS]. A free Personal Team almost certainly can't get it (**unverified**: no source states this either way). Wi-Fi Aware with QUIC needs iOS 27 [TN3213]. **Decision: don't use it.** Reconsider only if the project moves to a paid team.

### 1.4 Local network privacy and Info.plist (applies to both transports)

- Add `NSLocalNetworkUsageDescription` and list the Bonjour type in `NSBonjourServices`. For an MPC service type `cuecoach` the entry is `_cuecoach._tcp` [TN3179]. With Network framework + QUIC the type is `_cuecoach._udp`, and TCP uses `_tcp` [TN3213]. **List both** (`_cuecoach._tcp`, `_cuecoach._udp`) so either adapter works.
- **No entitlement needed.** The multicast entitlement is only for arbitrary service types or browsing all types [TN3179]. Nothing on the Personal Team blocklist is involved.
- The alert shows on the first Bonjour operation. The OS **may deny that first operation before the user answers**, so use APIs that wait for connectivity or add retries. Detect denial with `kDNSServiceErr_PolicyDenied` (-65570) on the browser's `.waiting` state, or with `unsatisfiedReason == .localNetworkDenied` [TN3179].
- In the background with an undetermined state, operations are **denied silently**. Always start the mesh from the foreground lobby [TN3179].
- **The simulator doesn't support local network privacy.** Mesh QA has to run on real devices [TN3179].
- An iOS 18 bug (FB14321888) could desync privacy state; it was fixed in 18.6. Not relevant on 27, noted for completeness [TN3179].
- **Zero-network-calls rule:** Bonjour on the local link plus connections only to Bonjour endpoints found on the local network are local traffic, not internet. We never resolve a non-`.local` name. A unit test and a static lint enforce this (§9).

---

## 2. Design proposal

### 2.1 Shape

```
                ┌─────────────── host phone (elected) ───────────────┐
 peer phones →  │ MeshHost: GameLog (authoritative), RulesEngine,     │
 (≤7 clients)   │ ShotEngine, Fusion, ShooterAttribution, ClockMaster │
                └─────────────────────────────────────────────────────┘
 every phone: Capture → Perception → local Tracker → DetectionFrame (table coords, host-time stamped)
              own rolling video buffer (spec §5.7) · own profile/SwiftData · own consent state
```

- **Star (client–server) topology** over the transport. The host owns game state, rules and engine (§5.7). Clients send detections and stroke observations, and the host sends authoritative events. A star gives 7 links instead of 28 for 8 phones, and TN3213 recommends it.
- **Cap: 8 phones per session**, which matches MPC's limit and the 8-player maximum (§4). With Network framework the cap is ours to set (AWDL airtime, host CPU), not a hard limit.
- **One phone works alone** (§5.7). `MeshHost` runs in-process with a `LoopbackTransport`, so single-phone mode uses exactly the same code path. The mesh only adds views.
- **Everything except the socket adapter is pure Swift in `Packages/CueCore/Mesh`** (D8): codec, versioning, clock sync, election, log replication, clip scheduler, and identity matching/attribution math. Then `swift test` covers it with a simulated network (§9).

### 2.2 Transport abstraction (proposed addition to `docs/INTERFACES.md`; contract-first rule)

```swift
// CueCore (pure, no Network/MPC import)
public struct PeerID: Hashable, Codable, Sendable { public let raw: UUID }     // per-session random (TN3213 privacy)
public enum Channel: Sendable { case control /*reliable, ordered*/, realtime /*best-effort datagrams*/, bulk /*reliable, flow-controlled*/ }
public protocol MeshTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }          // .peerUp(PeerID), .peerDown(PeerID, reason), .received(PeerID, Channel, Data), .denied(LocalNetworkDenied)
    func send(_ bytes: Data, to: PeerID, on: Channel) async throws   // .bulk suspends under back-pressure
    func advertise(session: SessionAdvert) async throws; func browse() -> AsyncStream<[SessionAdvert]>
    func connect(to: SessionAdvert) async throws; func disconnect(_ peer: PeerID) async
}
// App target adapters: NetworkFrameworkTransport (QUIC: control=stream 0, bulk=stream per clip, realtime=datagrams;
// .peerToPeerIncluded(true); browse stopped once connected), MPCTransport (optional, behind flag), LoopbackTransport, SimTransport (tests).
```

`MeshSession` (already listed in INTERFACES) sits on `MeshTransport` and exposes typed `MeshMessage`s.

### 2.3 Discovery and join (lobby only, foreground only)

1. The host starts `NetworkListener(.bonjour(name: <random session name>, type: "_cuecoach._udp", txtRecord:))`. Per TN3213's privacy note, the **TXT record carries no profile or device name**: just `{v: protocolMajor, s: sessionID (random), n: peerCount}`.
2. A joining phone browses and shows nearby tables as **big host-avatar tiles** (avatar colour plus icon, no text). Tap to join. **Stop browsing right after the tap** [TN3213].
3. **Security: mutual TLS over QUIC with per-install self-signed P-256 identities.** We create them with swift-certificates (Apache-2.0, Apple's own open source, no network) [SWIFTCERT, TN3213]. Neither side can check a CA, so the custom validator accepts the peer's cert and both sides derive a **short authentication string (SAS)** from `SHA256(hostCertSPKI ‖ clientCertSPKI ‖ sessionID)`. Both screens then show the **same 4 icons from a fixed 64-icon pool** (24 bits; a MITM has to beat 1-in-16.7M per attempt). The host owner taps ✓. This is visual, needs no text, and takes one glance. QR-code pinning could be an optional alternative (Q2).
4. Hello/Welcome do **version negotiation** (§3.3). Then come the `ProfileSummary` and, if the player opted in, `IdentityTemplate` (§6).
5. **Permission denied** (§1.4): show the "one-phone" icon state with a Settings deep-link glyph. The game still works with one phone.

### 2.4 Host election

Run it at lobby close and again on host loss. It is **deterministic**: every peer computes the same ranking from the same `PeerStatus` gossip, so there is no vote round.

`rank = (onPower, thermalState ≤ .fair, batteryBucket (10% steps), deviceClassRank, −joinOrder, peerID)`, sorted lexicographically, highest wins.
- `deviceClassRank` stands in for the spec's "newest device": 17 Pro Max > 15 Pro Max. It's a static table keyed by `utsname.machine`, with unknown models ranked lowest.
- Battery is bucketed so the host doesn't flap between 81% and 79%. **Hysteresis**: a sitting host is only replaced on loss or a graceful hand-off, never because a peer pulled ahead.
- **Terms** (Raft-style epoch numbers) stop split-brain. Each `HostClaim` carries `term`. A peer obeys only the highest term it has seen. A deposed host that comes back sees a higher term and rejoins as a client.

### 2.5 State replication and host migration (Phase 5 gate: "killing host keeps game")

- **Game state is an append-only, sequence-numbered event log** (`GameEvent`: roster/order edits, rule vote result, `ShotRecorded` (outcome + shooter + clip ref), `RuleApplied`, `ShooterCorrected`, `PlayerOptionChosen`, ...). Because `RulesEngine` is deterministic, `GameState = fold(log)` on any phone. **Every client keeps a full replica.**
- The host appends, broadcasts `GameEvent(seq, term)` on `.control`, and clients reply `LogAck(seq)`. An event counts as committed once it is acked by a majority of connected clients, or immediately in 1–2 phone sessions. The host UI shows a shot's result as soon as it's appended. Commit only matters for migration.
- **Heartbeat** host→all every 250 ms (*assumption*) carries `term`, `commitSeq` and the **succession list** (the ranking from §2.4 minus the host).
- **Failure detection:** connection failure, or 4 missed heartbeats (≈1 s). The first live peer in the succession list claims `term+1` once it has the highest `commitSeq` it knows of. Peers with a longer log hand over the missing tail on connect. Everyone else connects to the new host's listener (every peer pre-starts a dormant listener during the session, advertised only after a claim).
- **Mid-shot host loss:** a shot being tracked when the host dies is **discarded and re-run from the last committed `TableState`**. The new host asks for the post-shot `TableState` from the peers' trackers. If none is confident, the turn result is "needs tap" and any phone confirms it visually.
- Engine results (ratings, eval) aren't replicated state. The new host recomputes the last evaluation from the log.

### 2.6 Detection streaming and fusion inputs

- Each phone runs its own detector and tracker and sends `DetectionFrame` on `.realtime` (best-effort; a stale frame is useless [TN3213]).
- Size: header 24 B plus per ball `{id u8, x f16, y f16, σ f16, flags u8}` = 8 B, so 16 balls ≈ 152 B/frame. At 30 fps that's **≈4.6 kB/s per peer, ≈32 kB/s into the host at 7 peers**. That's trivial next to any Wi-Fi or AWDL link. Datagram size stays well under any MTU, so no fragmentation.
- Every frame carries `captureHostTime` (the sender's capture clock, §4) and that peer's current **offset estimate and uncertainty**. The host converts to its own timeline, interpolates each peer's track onto a common 30 Hz grid, and fuses with confidence weights (calibration residual × detector confidence × view angle). Fusion itself belongs to the perception/tracking design; this doc only fixes the inputs.
- Peers also send `StrokeObservation` (stroke start/end time, cue-line direction, and person-track evidence for attribution, §7) on `.control`.

### 2.7 Clip transfer (D3)

D3: "Best-angle clip (~5 s) is sent to the host over MPC after balls settle, never while anyone is aiming."

1. When the host commits `ShotRecorded`, it broadcasts `PhaseChange(.settled, shotID)`.
2. Every phone replies `ClipOffer(shotID, viewScore, byteSize)`. `viewScore` is a pure function in CueCore: how many shot balls were visible, the fraction of the cue-ball path in frame, occlusion by bodies (person mask), distance and angle. The host picks the best one, and the host's own clip wins ties (no transfer).
3. The host sends `ClipRequest` to the winner only. The winner trims its buffer (3 s before stroke → 2 s after settle, §9), encodes HEVC at 720p30 (*assumption*: ≈ 4–6 Mbit/s → **≈ 2.5–4 MB**), and streams `.bulk` in 256 kB chunks with a flow-controlled send loop [TN3213]. Chunks carry a SHA-256 for resume and integrity.
4. **"Never while aiming" gate:** the host broadcasts `PhaseChange(.aiming)` as soon as it sees the next shooter address the cue ball (pose + cue near the cue ball) *or* 2 s after settle, whichever comes first. *Assumption*: at ~20 Mbit/s effective (unmeasured; see risk R4), 3 MB takes ~1.2 s and usually fits. On `.aiming`, every sender **pauses at the next chunk boundary**, keeps its offset, and resumes after the next `.settled`. The `ClipScheduler` state machine in CueCore owns this and is property-tested (§9). If the user prefers to drop a clip rather than pause and resume it, see Q6.
5. Clips the host misses are fine. SotG needs only the chosen shot, and the source phone keeps its buffer until game end.

---

## 3. Protocol message list

### 3.1 Envelope (every message, both transports)

```
struct Envelope: Codable, Sendable {
  magic: "CUE"            // 3 B, reject foreign traffic
  major: UInt8            // breaking changes
  minor: UInt8            // additive changes
  type: UInt16            // MessageType raw value; unknown types are ignored (not an error)
  sessionID: UUID; sender: PeerID; term: UInt32
  seq: UInt64             // per-sender, per-channel monotonic
  sentHostTime: Int64     // sender clock, ns (for latency stats only)
  payload: Data           // binary for .realtime, JSON (Coder) for .control
}
```

### 3.2 Messages

| # | Type | Dir | Channel | Purpose / key fields |
|---|---|---|---|---|
| 1 | `Hello` | C→H | control | `supportedMajor: ClosedRange`, `minor`, `appBuild`, `deviceClass`, `capabilities` (bitset: `lidar`, `foundationModels`, `identityOptIn`) |
| 2 | `Welcome` | H→C | control | chosen `major/minor`, `assignedPeerID`, `term`, roster snapshot, `logSnapshot` (or `seq` to request a tail) |
| 3 | `Reject` | H→C | control | `reason`: `.versionTooOld/.versionTooNew/.sessionFull/.sasDeclined/.gameInProgressLocked` → icon on the client |
| 4 | `SASConfirm` | both | control | `accepted: Bool` (after the icon comparison) |
| 5 | `Leave` | both | control | graceful departure |
| 6 | `PeerStatus` | C→H, H→all | control | battery bucket, onPower, thermal, fps, calibration residual bucket, table-coverage mask (which table regions this view sees well) |
| 7 | `Heartbeat` | H→all | control | `term`, `commitSeq`, `succession: [PeerID]`, `phase` |
| 8 | `HostClaim` | new H→all | control | `term+1`, `lastSeq` |
| 9 | `HostHandoff` | H→successor | control | graceful migration (host low battery or leaving) |
| 10 | `TimePing` | C→H | realtime | `t0`, `pingID` |
| 11 | `TimePong` | H→C | realtime | `pingID`, `t0`, `t1`, `t2` |
| 12 | `ProfileSummary` | C→H→all | control | `playerID` (random per profile), avatar, colour, display initials, skill-model summary for the engine. **No history.** |
| 13 | `IdentityTemplate` | C→H→all | control | only if opted in: `playerID`, `modelID+version`, face embedding(s), optional appearance seed; `expiresAt = session end` |
| 14 | `IdentityRevoke` | any→all | control | `playerID`: purge the template now (delete or opt-out mid-session) |
| 15 | `RosterUpdate` | H→all | control (log) | teams, shooting order, guests |
| 16 | `RuleVoteOpen` / `RuleBallot` / `RuleVoteResult` | H↔all | control (log) | §3 poll; `Vote.winner` already in CueCore |
| 17 | `CalibrationReport` | C→H | control | homography + residual, plane offset applied, table size estimate (D12) |
| 18 | `DetectionFrame` | C→H | realtime | §2.6 binary layout |
| 19 | `StrokeObservation` | C→H | control | stroke t-start/t-end (host time), cue line, `[PersonEvidence]` (§7.3) |
| 20 | `PhaseChange` | H→all | control | `.aiming(shooter)`, `.inMotion`, `.settled(shotID)`, `.gameOver` (also gates clips) |
| 21 | `GameEvent` | H→all | control | `seq`, `term`, `event` (log entry, §2.5) |
| 22 | `LogAck` | C→H | control | `seq` |
| 23 | `LogTailRequest` / `LogTail` | any | control | catch-up after reconnect or migration |
| 24 | `ShooterCorrection` | any→H | control | `shotID`, `playerID`. Any phone's tap; becomes `GameEvent.shooterCorrected` |
| 25 | `ClipOffer` | C→H | control | `shotID`, `viewScore`, `byteSize`, `duration` |
| 26 | `ClipRequest` / `ClipCancel` | H→C | control | `shotID`, `resumeOffset` |
| 27 | `ClipChunk` | C→H | bulk | `shotID`, `offset`, bytes, `sha256(chunk)` |
| 28 | `ClipComplete` | C→H | control | `shotID`, `sha256(file)` |
| 29 | `PostShotCard` | H→all | control | ratings + eval swing for each phone's card (or recomputed locally from the log) |

### 3.3 Versioning rules

- **`major`** goes up for any change that breaks decoding or meaning. The session runs on `max(intersection of supported majors)`. With no overlap the client gets `Reject(.versionTooOld/.versionTooNew)`, shown as an "update" icon on the older phone. This matters because Personal Team builds expire every 7 days, so phones will be on different builds.
- **`minor`** is additive only: new optional JSON fields (decoders tolerate unknown keys and default missing ones) and new message types (unknown `type` is ignored and counted in the debug HUD).
- Binary `.realtime` layouts are versioned through `major` plus a per-message `layout: UInt8`.
- The `IdentityTemplate` carries `modelID+version`. A receiver that can't compare that model ignores it, and attribution falls back to turn order for that player.
- Golden fixture files (`Fixtures/mesh/v1/*.bin|json`) are frozen per major. Decoding old fixtures stays a test forever (§9).

---

## 4. Clock synchronization algorithm

**Goal:** fuse detections from different phones on one timeline. **Target:** |offset error| ≤ 5 ms p95 (*assumption*, a sixth of a 30 fps frame). That keeps a ball at 2 m/s within 1 cm of fusion misalignment.

**Timebase:** every phone stamps frames with the `CMSampleBuffer` PTS converted to the **host time clock** (`CMClockGetHostTimeClock`, mach ticks → ns). `AVCaptureSession.synchronizationClock` says which clock output timestamps are on, and lets us convert to the input port's original clock if needed [SYNCCLK]. Ping timestamps use the same clock, so capture stamps and sync samples share a timebase. Sleep and wake don't matter because the session keeps the screen awake.

**Algorithm (NTP-style, client ↔ host master) [RFC5905 §8, §10]:**

1. Client sends `TimePing(t0)` on the best-effort channel; host records arrival `t1` and sends `TimePong(t0,t1,t2)`; client records `t3`.
   `offset θ = ((t1 − t0) + (t2 − t3)) / 2`, `delay δ = (t3 − t0) − (t2 − t1)`.
2. **Burst at join:** 16 pings 20 ms apart, then **1 Hz** steady state (≈ 100 B/s).
3. **Clock filter:** keep the last 64 samples. Use the samples in the **lowest-delay quartile** only, because the true offset is within ±δ/2 of each sample and low-δ samples are the least affected by queuing and AWDL channel-hopping asymmetry [RFC5905 clock filter rationale; AWDL].
4. **Drift:** weighted least-squares line `θ(t) = a + b·t` over the filtered samples in a 60 s window, with weight ∝ 1/δ². `b` is skew (quartz, typically tens of ppm). Predict `θ` for any capture time. Report uncertainty `u = min(δ)/2 + residual σ`.
5. **Outlier rejection:** drop samples with `δ > 3 × median(δ)`. When an offset step > 10 ms persists over ≥ 5 low-δ samples, reset the fit (it handles a host change).
6. **Host migration:** each client keeps its fit against every peer it has pinged. The new host is already a known clock, so the switch is a one-step offset composition `θ_newHost = θ_oldHost − θ_oldHost→newHost`, refined by a fresh burst.
7. **Visual cross-check (QA + optional refinement):** the cue ball's first-motion instant and ball-ball collisions are sharp events every phone sees. The host compares their fused host-time stamps across views. The residual is a **direct measurement of sync error**, logged per shot in the debug HUD. If radio-derived sync drifts beyond 1 frame, the host can apply a per-peer correction from the median event residual. This needs at least 1 shared event per shot and only applies a correction when event residuals agree (MAD < 4 ms).

Where frames don't line up in phase (each camera's exposure phase is arbitrary), the host interpolates each peer's tracker state (Kalman, already in table coordinates) to the fusion tick instead of matching nearest frames.

---

## 5. Background, lifecycle, thermal

- **No background operation.** MPC drops sessions when the app backgrounds [MPC]. Network framework stops once the app is suspended [F836124]. During a session: `isIdleTimerDisabled = true`, camera running (we're on a tripod anyway), and a visible "paused" glyph if the app leaves the foreground.
- **Resume:** reconnect with `sessionID + playerID`, then `LogTailRequest(from: lastSeq)` and a clock re-burst. If the host backgrounded, the 1 s detector fires and migration (§2.5) moves the host. When the old host comes back, it rejoins as a client.
- **Local-network permission:** request it in the lobby on purpose, with a single visual "find nearby phones" step, never mid-game. Background operations are denied silently [TN3179].
- **Thermal/battery:** `PeerStatus` feeds election and an adaptive policy. A hot peer drops its `DetectionFrame` rate to 15 fps, or switches to "observer only" (strokes plus clip buffer, no streaming). This ties into the Phase 9 "fps never below 24" gate.
- **AWDL cost:** peer-to-peer Wi-Fi slows the venue Wi-Fi and the phones' own Wi-Fi [TN3213, AWDL-lat]. Stop browsing after joining [TN3213]. Prefer infrastructure Wi-Fi when both phones share a network (Network framework uses it with P2P enabled). Measure both paths (§9).

---

## 6. Identity: findings

| Need | Apple on-device option | Gap / note | Source |
|---|---|---|---|
| Find faces + quality | `VNDetectFaceRectanglesRequest`, `VNDetectFaceCaptureQualityRequest` (0–1; higher = better lit, sharper, more centred) | Use the quality score to pick enrolment frames and to gate matching | VFACEQ |
| **Face identity embedding** | **None.** `VNFaceObservation` has landmarks, roll/yaw/pitch and capture quality, but no identity vector. Developers asking about recognition were told Vision does detection, not recognition. | We need a Core ML face-embedding model | VFACEOBS, F79961 |
| Generic image embedding | `GenerateImageFeaturePrintRequest` → `FeaturePrintObservation` (iOS 18+, distance API) | General visual similarity, **not trained for identity**. Fine for the *session appearance* (clothing) cue, weak for faces | VFP |
| Find people | `VNDetectHumanRectanglesRequest` (`upperBodyOnly` default true; full body with rev 2) | Box per person | VHUMAN |
| Separate people | `VNGeneratePersonInstanceMaskRequest` (iOS 17+, per-person masks) vs `VNGeneratePersonSegmentationRequest` (one matte for all) | Use instance masks so clothing crops exclude the table and other people | VINST, VSEG |
| Who's in shooting pose | `VNDetectHumanBodyPoseRequest` (2D, 19 joints) + `VNDetectHumanBodyPose3DRequest` (iOS 17+) | Bent torso + forearm along the cue line + bridge hand near the cue ball | VPOSE, VPOSE3D |

**Face-embedding model candidates (license matters: public repo, D5):**

| Model | License | Notes |
|---|---|---|
| **SFace (OpenCV Zoo)** | **Apache-2.0** for the files in the zoo directory | MobileFaceNet backbone with SFace loss, ONNX → convert with `coremltools`. Tiny, fast on the ANE. Training-data terms upstream are **unverified**, so check before bundling [SFACE]. |
| InsightFace (ArcFace etc.) | Code MIT; **pretrained models are non-commercial research only** | Don't bundle [INSIGHT]. |
| OSNet (body re-ID) | Torchreid weights distributed as MIT; training datasets (Market/Duke/MSMT) have research terms | Optional upgrade for the clothing cue, needs a license decision [OSNET, OSNET-LIC]. |

**Practical constraint (reasoned, to verify in replays):** at a pool table the cameras are 2–4 m away and shooters are bent over, looking down the cue. Faces are small, steep and often turned away **at the moment that counts (stroke start)**. So face is the **check-in** cue and clothing/appearance is the **in-session** cue. That matches the spec's "clothing re-ID for the session".

---

## 7. Identity: design

### 7.1 Enrolment (opt-in, on the player's own phone)

- Profile → "Recognize me" toggle, **off by default**. A 3-panel visual explainer (icons plus ≤2-word labels, per the §2 text rule): *camera → stays on this phone → shared only at the table → one-tap delete*. **"Agree" is a separate, deliberate tap.** We store the consent record `{version, date}` locally.
- Capture: the front camera guides the player through a slow head turn (a visual ring fills in). Keep the 8–12 frames with `faceCaptureQuality ≥ 0.5` (*assumption*) across yaw buckets. Compute embeddings, **then discard the frames**. No photos are stored.
- Stored: `IdentityTemplate {playerID, modelID+version, [faceEmbedding] (L2-normalised), createdAt}`. It goes in a **separate file** (not the stats store), in Application Support, with `FileProtectionType.complete` and excluded from backup. It's **not** in the JSON export by default (Q5).

### 7.2 Session check-in (binds identity → appearance)

- In the lobby, each opted-in player's phone sends `IdentityTemplate` (§3.2 #13). Peers keep templates **in memory only** and drop them on `Leave`, session end, `IdentityRevoke`, or app termination.
- While players stand around the table in the lobby or after the break, the host matches face embeddings from all views against session templates. Each confident match (cosine ≥ τ_face, with a margin over the runner-up) **seeds a session appearance template** for that player: feature prints plus HSV histograms of the instance-masked upper body (shirt) and lower body, taken from several views.
- Players without face opt-in **or guests:** the shooter taps their avatar on any phone while standing in view, or the app grabs their appearance at their first turn (turn order is known). That's a session-only appearance template with no face data. **Guests** get a colour avatar and no profile (fate of their stats: Q3).
- Appearance templates are **session-scoped, never written to disk, and never leave the session**.

### 7.3 Shooter attribution at stroke start (§5.8)

For each phone at stroke start, `StrokeObservation.persons[]` gives `{trackID, poseScore (shooting-pose likelihood), distToCueBall (table plane), appearanceMatch: [playerID: score], faceMatch?: [playerID: score]}`. The host fuses them:

```
P(player p shot) ∝ Prior(p) × Π_views L_view(p)
Prior(p)   = 0.80 for the expected shooter by turn order/ball-in-hand rules, rest spread over others (assumption; tune on replays)
L_view(p)  = Σ_tracks w(track) · s_p(track),  w = softmax(poseScore − λ·distToCueBall)  // "person in shooting pose nearest the cue ball"
s_p        = calibrated similarity (Platt-scaled on labelled sessions) from appearance (and face if available)
```

- **Decide** when `max P ≥ 0.85` with a margin of 0.3 over the runner-up (*assumptions*). **Otherwise use turn order** (spec). Low confidence isn't shown during aiming (no text, no audio). After the shot, the card shows the shooter avatar with a subtle "tap to fix" affordance.
- **One-tap correction on any phone** → `ShooterCorrection` → log event. It also **updates that player's session appearance template** (adds the exemplar, removes it from the wrong player). That's the spec's "corrections become session training signal", and it stays session-only.
- **Teams:** the prior already narrows to the team in turn. Attribution mostly separates teammates, and in 1v1 it mostly confirms turn order.
- Phase 5 gate: **attribution ≥ 90% with the tap fallback** (§9 measurement).

### 7.4 Privacy design summary

| Rule (spec §2, CLAUDE.md) | Mechanism |
|---|---|
| Opt-in per player | Toggle off by default. A separate consent tap with a stored consent version. Re-ask when `modelID` or data use changes. |
| Embeddings only on the player's phone | Template file on the owner's phone only. Peers hold it in RAM for the session, enforced by a `TemplateStore` with no persistence API on the peer path, plus a test. |
| Shared only over the local mesh, active session | Sent only after SAS-confirmed mutual TLS (§2.3), only in `IdentityTemplate`, with `expiresAt = session end`. Never in TXT records, export, logs or crash data. |
| One-tap delete | Settings → "Delete my recognition data": wipe the template file and consent record, send `IdentityRevoke` to the current session (peers purge immediately), and clear any session appearance template tied to this player. Show visual confirmation. No undo. |
| Bystanders | Unmatched people get only ephemeral track IDs and appearance vectors in memory while in view. Nothing is stored or sent beyond `PersonEvidence` scores. |
| No images leave the phone | Only vectors and scores cross the mesh. Clips (D3) are table views. They may show people, stay in-app, and are deleted with the game unless the user saves them (Phase 7 decision). |
| Training ≠ competitive | Identity isn't used in Training mode (solo). |
| Legal note (not legal advice) | The user is in Illinois (UIUC, D7). BIPA covers "scan of … face geometry" and requires informed written consent and a public retention/destruction policy for a *private entity in possession* [BIPA, BIPA-txt]. We never hold anyone's data and it never leaves the phones. Even so, the consent tap, a stated retention rule (Q5: e.g. auto-delete a template unused for 180 days) and one-tap delete line the design up with BIPA's intent. **Flag for the user** before any public distribution. |

---

## 8. Risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | MPC deprecated (Xcode 27). Possible removal in a later SDK; iOS 26+ connect regressions with no supported recovery | High / High | Network framework adapter (Q1), transport protocol, MPC adapter only if the user insists |
| R2 | AWDL (peer-to-peer Wi-Fi) flakiness when Wi-Fi is on but not joined to a network, which affects Network framework too | Med / High | Prefer shared infrastructure Wi-Fi when present; retry with backoff on connect; QA matrix includes "no network joined" (§9); one-phone mode always works |
| R3 | Local network permission denied or delayed (first op may be denied before the user answers) | Med / Med | Lobby-time request; wait-capable APIs; detect `PolicyDenied`; one-phone fallback icon |
| R4 | Throughput unknown (no benchmarks); clip doesn't finish before the next aim | Med / Low | Measure (§9). 720p HEVC; pause/resume at chunk boundaries; SotG can fetch later |
| R5 | Clock sync error > 1 frame from asymmetric AWDL delays | Med / Med | Low-delay filter + drift fit + **visual-event cross-check** (§4.7) |
| R6 | Host migration loses a shot | Low / Med | Replicated log; mid-shot re-run; tap confirm |
| R7 | App versions differ (7-day Personal Team expiry, re-installs) | High / Low | Version negotiation, golden fixtures |
| R8 | Face recognition poor at table distance/angle | High / Med | Face only for check-in; clothing re-ID in session; turn-order prior; tap fix |
| R9 | Clothing collisions (team shirts, identical league jerseys) | Med / Med | Lower body + position history + turn-order prior; tap fix updates templates |
| R10 | Model licensing (face/re-ID weights, training-data terms) on a public repo | Med / High | SFace Apache-2.0 after upstream check; no InsightFace weights; OSNet only after review (Q4) |
| R11 | Biometric-law exposure (BIPA) if distributed | Low (personal use) / High | §7.4 design; user decision before distribution |
| R12 | Thermal: camera + detector + radio on all phones for 1 h | Med / Med | Adaptive detection rate; host on power; Phase 9 gate |
| R13 | Bandwidth from 7 peers' detections and AWDL airtime hurting the overlay (60 fps) | Low / Med | ~32 kB/s total; datagrams; no video streaming (spec) |
| R14 | Third-party crypto library (swift-certificates) vs "no SDKs that phone home" | Low / Low | Apple-maintained Apache-2.0, no network code; or an embedded static identity + SAS only (TN3213 workaround) if the user rejects the dependency (Q2) |

---

## 9. TDD / QA plan

### 9.1 Pure-Swift unit tests (`Packages/CueCore`, `swift test`, write them first)

| Module | Red tests to write first |
|---|---|
| `MeshCodec` | Round-trip every message; frozen golden fixtures per major decode forever; unknown `type` ignored; unknown JSON keys tolerated; truncated/garbage/foreign-magic input rejected without crashing (fuzz 10k random buffers); `DetectionFrame` ≤ 160 B for 16 balls |
| `VersionNegotiator` | Overlap → highest common major; no overlap → correct `Reject` reason; minor mismatch accepted |
| `ClockSync` | Sim network with fixed true offset/skew, asymmetric delay (e.g. 2 ms up / 9 ms down), jitter, 20% loss, AWDL-like periodic spikes → p95 error ≤ 5 ms after the burst, ≤ 2 ms after 60 s; tracks 50 ppm skew; step-reset on offset jump; offset composition across host change; visual-event residual correction applied only when MAD < 4 ms |
| `HostElection` | Same inputs → same host on every peer (property test, random permutations of gossip order); hysteresis (no flap); term monotonic; stale-term `HostClaim` ignored; split brain resolves to the highest term |
| `GameLog` / `Replication` | `fold(log)` equals the live `GameState`; majority commit; tail catch-up; **kill-host simulations** (random kill point over 1,000 seeded games on `SimTransport`): no committed event lost, all replicas equal after migration; mid-shot loss → shot re-run |
| `ClipScheduler` | **Property: zero chunk sends while phase == `.aiming`** (random phase traces); pause/resume keeps the offset; best-view pick from `viewScore`; host-own-clip short-circuit; SHA mismatch → retransmit chunk |
| `ViewScore` | Monotone in visible shot balls / path coverage; occlusion penalty |
| `ShooterAttribution` | Synthetic evidence: correct pick with strong evidence; falls back to turn order under threshold; correction updates templates (session only); team prior; never picks someone not in the roster |
| `IdentityMatcher` | Cosine/margin logic on synthetic L2-normalised vectors; model-version mismatch → ignored |
| `ConsentStore` / `TemplateStore` | Opt-out state blocks every send path; delete wipes file + emits `IdentityRevoke`; peer-side store has no persistence (spy file manager: zero writes); revoke purges in memory |
| `NoInternetLint` | Test or SwiftLint rule: no `URLSession`, no non-`.local` hostnames, `NWEndpoint` only from Bonjour results |

### 9.2 App-level (simulator, XCUITest, `CueCoach iPhone 15 Pro`)

- Lobby with `LoopbackTransport` and `SimTransport` (two in-process "phones"): join, SAS icons match, vote, roster.
- Consent flow: off by default, consent tap required, delete button wipes data (check file absence), accessibility ≥ 44 pt targets, **no text while aiming** (snapshot test: overlay layer has no `Text` views).
- The simulator **can't** test local network privacy or AWDL [TN3179]. Everything radio-related runs on devices.

### 9.3 Real devices (iPhone 15 Pro Max = perf gate, iPhone 17 Pro Max = second mesh phone; D6)

| Test | Method | Pass |
|---|---|---|
| Join matrix | {shared Wi-Fi, Wi-Fi on/not joined (AWDL only), Wi-Fi off, Mobile Data on/off} × {15 PM host, 17 PM host} × 20 joins | ≥ 19/20 joins in < 5 s per cell; record failures (F803339/F811978 cases) |
| Permission | Fresh install, deny, then allow in Settings | Denied → one-phone glyph; allow → auto-recovers |
| RTT / loss | 10 min ping on control + datagram | Report p50/p95/p99; budget for heartbeats |
| Throughput | 20 × 4 MB clip transfers in each network cell | Report MB/s; ≥ 90% finish before `.aiming` at a realistic 8 s settle→aim gap |
| **Clock sync truth** | Both phones film one event: phone A's torch strobes 10 Hz (or a third device's screen flash) in both views; compare host-time stamps of the flash onset | p95 \|error\| ≤ 5 ms; also log visual-event residuals during real shots |
| Kill host | Force-quit host at random points over 30 racks (between shots, mid-shot, during clip) | Game continues on the other phone with no committed shot lost; ≤ 2 s to resume |
| Background | Host and client each backgrounded 10 s, 60 s | Rejoin + log catch-up, no duplicate shots |
| Version skew | Install build N on one phone, N+1 (minor) and N+1 (major) on the other | Minor joins; major shows the update icon |
| Thermal | 1-hour 2-phone session, both streaming | fps ≥ 24 on 15 PM (Phase 9), no disconnect |
| Attribution | ≥ 3 recorded 2v2 sessions (local footage only, never committed, D5) with hand labels | ≥ 90% correct with tap fallback counted (Phase 5 gate); report face-only, clothing-only and fused separately |
| Privacy | After session end, inspect both containers (Xcode → Download Container) | No peer templates on disk; deleted user leaves no template |

Vendor rule: whoever writes `Mesh/` and `Identity/` doesn't review them (CLAUDE.md, D4). Record it in `docs/AGENTS.md`.

---

## 10. Open questions for the user (product ambiguity: stop and ask)

| # | Question | My recommendation |
|---|---|---|
| **Q1** | MPC is deprecated in Xcode 27 and has iOS 26+ connect bugs Apple won't work around. May we amend §2/§5.7 and `CLAUDE.md` to "local peer-to-peer only (Network framework + Bonjour; MPC optional)"? | **Yes, Network framework.** Same privacy, no entitlement, works on a Personal Team, client–server fits host-owns-state |
| Q2 | Join security: 4-icon SAS confirmation (needs swift-certificates for per-install certs), QR pinning, or no auth (open table)? | SAS icons + swift-certificates |
| Q3 | Guests: discard their stats at game end, or offer the host a share-sheet export? | Discard; optionally "claim" by the guest installing later (out of scope) |
| Q4 | Face model: SFace (Apache-2.0, upstream data terms to check), or ship clothing-only identity first? | Clothing + turn order first (Phase 5 gate needs only 90% *with* tap fallback); add SFace after the license check |
| Q5 | Template retention: keep until deleted, or auto-expire after N days unused? Include in JSON export? | Auto-expire at 180 days; exclude from export |
| Q6 | D3 reading: if aiming starts mid-transfer, pause and resume after the next settle (my reading), or drop the clip? | Pause/resume |
| Q7 | Election weights: does "newest device / highest battery" mean device first or battery first? | On-power → thermal → battery bucket → device class |
