# Mesh + player identity: research and design proposal (SPEC §5.7, §5.8, D3)

Compiled 2026-11-06, revised the same day after a critical review (rev 2). Research and design only, no code.
Every external claim has a source key from the table below. **Unverified** = I could not confirm it from a
primary source. **Assumption** = a number I picked that we must measure on the two real phones.
**Q-numbers** are user decisions (§10). Nothing marked Q is decided yet.

> **Blocking findings: user decisions needed before Phase 5 starts.**
> 1. **Transport (Q1).** Apple deprecated all of Multipeer Connectivity in Xcode 27 [TN3213]; `MCSession`
>    availability reads "iOS 7.0 – 27.0" [MCS]. The spec (§2, §5.7) and `CLAUDE.md` say
>    "MultipeerConnectivity only". I recommend Network framework (Bonjour + QUIC) behind a `MeshTransport`
>    protocol, at the cost of losing MPC's Bluetooth path (§1.2).
> 2. **Consent scope (Q8–Q10).** SPEC §2 says "Face **and appearance** recognition is opt-in per player",
>    while §5.8 says "clothing re-ID for the session". Rev 1 read §5.8 as allowing clothing re-ID of
>    everyone. That reading is withdrawn. This revision defaults to **no appearance or face processing
>    for anyone who has not opted in** (players, guests, bystanders) until the user decides.

## Sources

| Key | Source | URL |
|---|---|---|
| TN3213 | Apple TN3213 "Moving from Multipeer Connectivity to Network framework" (republished 2026-07-14) | https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework |
| TN3179 | Apple TN3179 "Understanding local network privacy" (rev. 2026-10-06) | https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy |
| MCS | Apple docs, `MCSession` (8-peer limit, availability metadata) | https://developer.apple.com/documentation/multipeerconnectivity/mcsession |
| MPC | Apple docs, Multipeer Connectivity overview (transports incl. Bluetooth PAN; background behaviour) | https://developer.apple.com/documentation/multipeerconnectivity |
| MAXP | Apple docs, `MCBrowserViewController.maximumNumberOfPeers` (default/max 8) | https://developer.apple.com/documentation/multipeerconnectivity/mcbrowserviewcontroller/maximumnumberofpeers |
| NWP2P | Apple docs, `NWParameters.includePeerToPeer` ("enables peer-to-peer link technologies") | https://developer.apple.com/documentation/network/nwparameters/includepeertopeer |
| SECEXP | Apple docs, `sec_protocol_metadata_create_secret` (TLS keying-material exporter) | https://developer.apple.com/documentation/security/sec_protocol_metadata_create_secret(_:_:_:_:) |
| Q776069 | Apple DTS (Quinn), "Moving from Multipeer Connectivity to Network Framework" forum post | https://developer.apple.com/forums/thread/776069 |
| F803339 | Apple forums, "Multipeer Connectivity connection is flaky on iOS 26" (DTS replies) | https://developer.apple.com/forums/thread/803339 |
| F811978 | Apple forums, MPC stuck in `.connecting` with Mobile Data on (DTS replies) | https://developer.apple.com/forums/thread/811978 |
| F836124 | Apple forums, MPC background operation (DTS on background vs suspension) | https://developer.apple.com/forums/thread/836124 |
| WWDC25-250 | WWDC25 session 250, Network framework async API (`NetworkConnection`/`Listener`/`Browser`, `Coder`, TLV) | https://developer.apple.com/videos/play/wwdc2025/250 |
| P2P-sample | Apple sample "Building a custom peer-to-peer protocol" | https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol |
| WIFIAWARE | Apple docs, Wi-Fi Aware framework (iOS 26+, iPhone 12+, entitlement) | https://developer.apple.com/documentation/wifiaware |
| ESP-WA | Espressif, "Wi-Fi Aware ESP to iPhone" (Wi-Fi Aware is a *managed* capability; request form) | https://developer.espressif.com/blog/2026/08/wifi-aware-esp-to-iphone/ |
| CAPS | Apple "Supported capabilities (iOS)" | https://developer.apple.com/help/account/reference/supported-capabilities-ios |
| AWDL | Stute et al., "One Billion Apples' Secret Sauce" (AWDL), MobiCom '18 | https://arxiv.org/abs/1808.03156 |
| AWDL-lat | Blog measurement: LAN latency with AWDL on vs off (informal, single user) | https://adamlovattdevops.github.io/awdl-latency-killer/ |
| OBJC | objc.io, "Multipeer Connectivity in Games" (send modes, message sizes) | https://www.objc.io/issues/18-games/multipeer-connectivity-for-games |
| RFC5905 | NTPv4 (offset/delay equations, clock filter) | https://www.rfc-editor.org/rfc/rfc5905 |
| RFC6189 | ZRTP (hash commitment limits a MITM to one SAS guess, §4.4.1.1) | https://www.rfc-editor.org/rfc/rfc6189 |
| SYNCCLK | Apple docs, `AVCaptureSession.synchronizationClock` | https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock |
| VFP | Apple docs, `GenerateImageFeaturePrintRequest` (iOS 18+) | https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest |
| VFACEQ | Apple docs, `VNDetectFaceCaptureQualityRequest` | https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest |
| VFACEOBS | Apple docs, `VNFaceObservation` (landmarks/pose/quality, no identity field) | https://developer.apple.com/documentation/vision/vnfaceobservation |
| F79961 | Apple forums, "Face Recognition in Vision Framework?" (Vision = detection, not recognition) | https://developer.apple.com/forums/thread/79961 |
| VHUMAN | Apple docs, `VNDetectHumanRectanglesRequest.upperBodyOnly` | https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest/upperbodyonly |
| VINST | Apple docs, `VNGeneratePersonInstanceMaskRequest` (iOS 17+) | https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest |
| VSEG | Apple docs, `VNGeneratePersonSegmentationRequest` (iOS 15+, single matte) | https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest |
| VPOSE | Apple docs, `VNDetectHumanBodyPoseRequest` | https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest |
| SFACE | OpenCV Zoo `face_recognition_sface` README (Apache-2.0; **no training dataset named**) | https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/README.md |
| SFACE-paper | Zhong et al., "SFace: Sigmoid-Constrained Hypersphere Loss" (trained on CASIA-WebFace, VGGFace2, MS-Celeb-1M) | https://arxiv.org/abs/2205.12010 |
| MSCELEB | Irish Times / FT: Microsoft deletes MS-Celeb-1M (2019) | https://www.irishtimes.com/business/technology/microsoft-quietly-deletes-largest-public-face-recognition-data-set-1.3916825 |
| DUKE | Biometric Update: MS-Celeb, DukeMTMC and other datasets taken down (2019) | https://www.biometricupdate.com/201906/ms-celeb-and-other-facial-biometrics-datasets-taken-down |
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
| Status | "Xcode 27 deprecates the entire Multipeer Connectivity framework … plan to migrate your code to Network framework." `MCSession` availability: iOS 7.0–27.0. It still runs on iOS 27; every use builds with a deprecation warning. | TN3213, MCS |
| Transports | "In iOS, the framework uses infrastructure Wi-Fi networks, peer-to-peer Wi-Fi, and **Bluetooth personal area networks**." | MPC |
| Max peers | "Sessions currently support up to 8 peers, including the local peer." More than 8 needs multiple sessions. | MCS, MAXP |
| Topology | Fully connected: "every peer is effectively connected to every other peer." | TN3213 |
| Send modes | `.reliable` / `.unreliable`. `send(_:)` suits small event data of a few kB. | TN3213, OBJC |
| Throughput / latency | DTS: "good latency but poor throughput". **No flow control (back pressure).** No published benchmark. | Q776069 |
| Big payloads | `sendResource(at:…)` sends a file with an `NSProgress` (no resume from an offset). Streams use `NSStream`, "scheduled for deprecation" for networking. | MCS, Q776069 |
| Reliability on iOS 26+ | (a) Peers flap `.connecting` → `.notConnected`. The reporter: "as soon as Bluetooth is involved in establishing a connection, the pairing process becomes flaky", always when Wi-Fi is off or not joined, fine on a shared Wi-Fi network. DTS saw AWDL torn down in the logs. **Apple's Network-framework sample did not reproduce it** ("Done, and as assumed, I didn't reproduce it"), while MPC still failed when run side by side. (b) With Mobile Data on, peers stay `.connecting` forever; DTS: no supported way to detect or recover, "stop using Multipeer." | F803339, F811978 |
| Background | "If the app moves into the background, the framework stops advertising and browsing and disconnects any open sessions." | MPC, F836124 |
| Security | `MCEncryptionPreference` none / optional / required. Required needs a PKI identity. Optional "doesn't yield any actual security benefits". | TN3213 |
| Side effect | MPC always turns on peer-to-peer Wi-Fi (AWDL). Informal measurement: LAN latency 25.4 ms with AWDL on vs 4.3 ms off. | Q776069, AWDL-lat |

### 1.2 Network framework (the recommended replacement)

| Topic | Finding | Source |
|---|---|---|
| API | iOS 26+ Swift-concurrency API: `NetworkListener` (`.bonjour(name:type:txtRecord:)`), `NetworkBrowser`, `withNetworkConnection(to:using:)`; builder stack (`TLS()`, `QUIC(alpn:)`, `TCP()`). | TN3213, WWDC25-250 |
| Architecture | "Many apps work better with the client-server architecture … use this opportunity to switch." Matches host-owns-state (§5.7). | TN3213 |
| Peer identity | Own random `UUID` as peer ID; dedupe connections by ID; think about privacy before persisting it. | TN3213 |
| Send modes | QUIC: many reliable streams plus **one best-effort datagram channel**. | TN3213 |
| Framing | `TLV(type:length:)` and `Coder(Message.self, using: .json)`. | TN3213, WWDC25-250 |
| Flow control | Async `send` waits when the send buffer is full, so a plain loop gives back pressure. **This is how we send clips.** | TN3213 |
| Peer-to-peer Wi-Fi | Off by default; opt in with `.peerToPeerIncluded(true)`. TN3213: "Enabling peer-to-peer Wi-Fi can reduce network performance both for your app and for other apps on the device. **Only enable it if it's a significant benefit to your app. Consider using Wi-Fi Aware instead.**" Stop browsing as soon as the user picks a service. | TN3213 |
| Bluetooth | **Lost vs MPC.** Apple documents only "peer-to-peer link technologies" for `includePeerToPeer`; TN3213 names Apple peer-to-peer Wi-Fi and Wi-Fi Aware, never Bluetooth. **Unverified** that NF has no Bluetooth path, but nothing documents one. Practical effect: **Wi-Fi radio off = no mesh** (one-phone mode). | NWP2P, TN3213, MPC |
| Path choice infra vs AWDL | **Unverified.** No Apple source I found says how Network framework picks between a shared infrastructure network and AWDL when both are allowed. We measure it (§9.3) and log the chosen interface per connection; we do not rely on it. | — |
| Security | QUIC always has TLS. Mutual TLS + custom validator is the pattern. **No Apple API creates a digital identity locally**; use e.g. swift-certificates. Embedding one identity in the app and disabling trust evaluation lets you "use QUIC **without any meaningful security**." | TN3213, SWIFTCERT |
| TLS exporter | `sec_protocol_metadata_create_secret` exports a keying secret from a TLS session. **Unverified** that it is reachable from the new `NetworkConnection` API; the SAS (§2.3) does not depend on it. | SECEXP |
| Defaults to tune | TCP keepalives off, TCP send timeout infinite, QUIC idle timeout 30 s, QUIC keepalives off. Tune for a LAN. | TN3213 |
| Bonjour type | "If you deploy an app that uses a new service type, register that service type with the IANA." Optional housekeeping before public distribution. | TN3213 |
| Background | DTS: "our other networking APIs *do* work in the background just fine … they don't work when the app is *suspended* in the background." | F836124 |

### 1.3 Wi-Fi Aware (Apple's own suggestion, blocked for us)

TN3213 suggests Wi-Fi Aware instead of peer-to-peer Wi-Fi, and QUIC over Wi-Fi Aware needs iOS 27 [TN3213]. Both
test phones qualify (iPhone 12+) [WIFIAWARE]. But it needs `com.apple.developer.wifi-aware`, a **managed capability
granted by request form** [ESP-WA], not on the standard list [CAPS]. A Personal Team almost certainly can't get it
(**unverified**). **Not usable now**; it is the first thing to revisit if the project moves to a paid team.

### 1.4 Local network privacy and Info.plist (both transports)

- `NSLocalNetworkUsageDescription` + `NSBonjourServices`: list `_cuecoach._tcp` (MPC) and `_cuecoach._udp` (QUIC) [TN3179, TN3213].
- **No entitlement needed** for a declared service type [TN3179].
- The alert shows on the first Bonjour operation, which **may be denied before the user answers**: use wait-capable APIs or retry. Detect denial via `kDNSServiceErr_PolicyDenied` (-65570) or `unsatisfiedReason == .localNetworkDenied` [TN3179].
- Background with undetermined state → **denied silently**. Start the mesh from the foreground lobby [TN3179].
- **The simulator doesn't support local network privacy**; mesh QA runs on devices [TN3179].
- **Zero-network-calls rule:** Bonjour on the local link and connections only to Bonjour endpoints are local traffic. Never resolve a non-`.local` name; a test + lint enforce it (§9).

---

## 2. Design proposal

### 2.1 Shape

```
                ┌─────────────── host phone (elected) ───────────────┐
 peer phones →  │ MeshHost: GameLog (authoritative), RulesEngine,     │
 (≤7 clients)   │ ShotEngine, Fusion, ShooterAttribution, ClockMaster │
                └─────────────────────────────────────────────────────┘
          every client also holds a warm standby link to the successor (§2.5)
 every phone: Capture → Perception → local Tracker → DetectionFrame (table coords, host-time stamped)
              own rolling video buffer (spec §5.7) · own profile/SwiftData · own consent state
```

- **Star topology** for game traffic (host owns state, §5.7), recommended by TN3213. Plus one idle, authenticated **standby link** from each client to the successor so failover needs no discovery.
- **Cap: 8 phones** (= MPC limit = 8-player max).
- **One phone works alone:** `MeshHost` in-process over `LoopbackTransport`, same code path.
- **Pure Swift in `Packages/CueCore/Mesh`** (D8): codec, versioning, clock sync, election, replication + partition merge, clip scheduler, SAS, identity matching/attribution math. Tested with a simulated network (§9).

### 2.2 Transport abstraction (proposed addition to `docs/INTERFACES.md`; contract-first rule)

```swift
// CueCore (pure, no Network/MPC import)
public struct PeerID: Hashable, Codable, Sendable { public let raw: UUID }     // per-session random (TN3213 privacy)
public enum Channel: Sendable { case control /*reliable, ordered*/, realtime /*best-effort datagrams*/, bulk /*reliable, flow-controlled*/ }
public protocol MeshTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }          // .peerUp, .peerDown(reason), .received(PeerID, Channel, Data), .denied
    var guarantees: ChannelGuarantees { get }                // what this adapter really provides (below)
    func send(_ bytes: Data, to: PeerID, on: Channel) async throws   // .bulk suspends under back-pressure where supported
    func advertise(session: SessionAdvert) async throws; func browse() -> AsyncStream<[SessionAdvert]>
    func connect(to: SessionAdvert) async throws; func disconnect(_ peer: PeerID) async
}
```

**Channel guarantees per adapter** (rev 1 overstated that "the design holds whichever transport"):

| Channel | `NetworkFrameworkTransport` (QUIC) | `MPCTransport` (fallback) |
|---|---|---|
| control | QUIC stream 0, reliable ordered | `.reliable` send, reliable ordered |
| realtime | QUIC datagrams, best effort | `.unreliable` send, best effort |
| bulk | QUIC stream per clip, **real back-pressure**, resume by offset | **No back-pressure** [Q776069]. Either `sendResource` (whole file, progress, **no pause/resume**: cancel + restart) or app-chunked `.reliable` sends with app-level windowing (≤4 chunks in flight, ack per chunk). Pause at chunk boundary works only with the chunked mode. |
| peers | ours to set | hard 8 |
| link types | infra Wi-Fi + AWDL | infra Wi-Fi + AWDL + Bluetooth PAN |

The MPC adapter gets its **own** device test row (§9.3); it is not assumed equivalent.

### 2.3 Discovery, join and authentication (lobby only, foreground only)

1. **Advertise.** Host starts `NetworkListener(.bonjour(name: <random>, type: "_cuecoach._udp", txtRecord:))`. TXT = `{v: protocolMajor, s: sessionID (random 128-bit), n: peerCount, g: glyph (0–15), c: colour (0–7)}`. `g`/`c` are drawn at random per session and carry **no profile or device data**.
2. **Pick the right table.** The host's screen shows its session glyph huge (e.g. a green anchor). Browsing phones show one big tile per nearby session with the same glyph + colour. Player picks the tile that matches the host phone they can see. Host avatars appear **only after connect**. Before advertising, the host browses ~1 s and re-rolls `g/c` if another nearby session uses the same pair (128 combos). **Stop browsing right after the tap** [TN3213].
3. **mTLS.** QUIC with per-install self-signed P-256 identities made with swift-certificates (Apache-2.0, no network) [SWIFTCERT, TN3213]. The validator accepts any cert at this point; trust comes from step 4.
4. **Commit-then-reveal SAS** (the pattern of ZRTP / Bluetooth numeric comparison: a hash commitment "constrains the attacker to only one guess" [RFC6189 §4.4.1.1]):
   - C→H `SASCommit(h = SHA256(n_C))`, `n_C` = fresh 128-bit random
   - H→C `SASNonce(n_H)` (fresh 128-bit)
   - C→H `SASReveal(n_C)`; host checks `h`
   - Both: `SAS = first 24 bits of SHA256("cuecoach-sas-v1" ‖ hostSPKI ‖ clientSPKI ‖ n_C ‖ n_H)` → **4 icons from a 64-icon pool**.
   - **Both** owners compare and tap ✓ (`SASConfirm` from each side). Either ✗ or a 30 s timeout → abort.
   - The pin (peer SPKI) is kept **for this session only**.
5. **Real security level.** The commitment forces a MITM to fix its values before seeing the honest side's nonce, so it gets **one 1-in-2²⁴ guess per join attempt**, and every failed guess shows as mismatched icons. Rev 1's formula had no nonces, which allowed an offline ~2¹² birthday search; that is fixed. **Threat model:** a casual pool bar. An attacker needs a modified build on a phone in radio range during the join. What the SAS protects: game state integrity and, above all, opted-in identity templates (§7), which are **never sent to an unauthenticated peer**.
6. **Honest alternative (Q2): no authentication.** Plain QUIC with any-cert validation, no SAS. Simpler and faster to join. Then **no identity templates are ever sent** (face recognition is off for mesh sessions). Rev 1's "embedded static identity + SAS" fallback is **dropped**: with a shared, public-repo key and identical SPKIs on every install, it is no-auth that only looks secure [TN3213].
7. Hello/Welcome do version negotiation (§3.3), then `ProfileSummary`, then identity data only per §7.
8. **Permission denied** (§1.4): "one-phone" glyph + Settings deep-link glyph; the game still works.

### 2.4 Host election (ordering is Q7)

Deterministic: every peer computes the same ranking from the same `PeerStatus` gossip; no vote round. Run at
lobby close and on host loss. The **tuple order is undecided**; the spec says "newest device / highest battery"
without saying which wins. Options, presented neutrally:

| Option | Ranking (lexicographic, highest wins) | For | Against |
|---|---|---|---|
| A (spec-literal, device first) | deviceClass, batteryBucket, −joinOrder, peerID | Fastest phone runs the engine (<3 s eval) | The 17 PM nearly always hosts; 15 PM-as-host gets little real use |
| B (battery first) | batteryBucket, deviceClass, … | Longest session life | A weaker phone may host and miss the engine budget |
| C (power/thermal veto then A) | thermal ≤ .fair as a veto, onPower as a tie-breaker, then A | Avoids throttled hosts | Tripod phones are rarely on power, so onPower rarely matters |

- `deviceClass` = static table keyed by `utsname.machine`; unknown → lowest. Needs upkeep when new models ship.
- Battery bucketed (10 %) + **hysteresis**: a sitting host is replaced only on loss or graceful hand-off.
- **Terms** (Raft-style epochs) in every `HostClaim`; a peer obeys the highest term it has seen.
- **QA forces the 15 PM as host** in perf and thermal runs regardless of which option wins (§9.3).

### 2.5 State replication, host migration and partitions (Phase 5 gate: "killing host keeps game")

**Log.** Game state is an append-only, sequence-numbered `GameEvent` log; `GameState = fold(log)` on any phone
(RulesEngine is deterministic). Every client keeps a full replica. Host appends → broadcasts `GameEvent(seq, term)`
→ clients `LogAck`. **Committed = acked by a majority of all session members (host included).** With 2 phones that
means the other phone has acked. Unacked events are *provisional*.

**Failure detection.** Heartbeats on both the control stream and datagrams. `T_fail` (*assumption*: start at 1.5 s)
is **tuned from measured gaps**: `T_fail = clamp(1.5 × p99.9 inter-heartbeat gap, 1 s, 3 s)`, from the §9.3 RTT/gap
run over AWDL (channel hopping can produce gaps near 1 s [AWDL]). Suspicion at `T_fail/2` only dims the peer
glyph; nothing else happens.

**Warm standby (makes failover discovery-free).** At join, each client also opens an mTLS connection to the
current successor (#1 in the succession list). The host sends each client the successor's SPKI over the
SAS-authenticated host link, so the standby link is pinned without a second SAS. It carries only keepalives
(every 2 s, *assumption*) and, when needed, `HostClaim`. If the successor changes mid-game, clients briefly browse
for the new one (lobby-style; accepted cost).

**Clean host loss (host dead, ≥1 other phone sees nobody else lose it):** successor claims `term+1` over the
standby links, collects `LogTail`s, becomes host. Target: resume ≤ `T_fail + 0.5 s`. With `T_fail` = 1.5 s that is
≤ 2 s; if measurement forces `T_fail` higher, the ≤2 s gate is relaxed to `T_fail + 0.5 s` and reported (Q13). If
the successor is also gone, the next peer claims and clients must re-browse (≤ 10 s, relaxed gate).

**Partitions (the real 2-phone case).** A phone cannot tell "host died" from "link blipped". So:

1. Any phone that loses its host and **cannot reach a majority** enters **island mode**. In a 2-phone session that
   is both phones after any loss. An island keeps tracking, keeps the overlay, and records shots as
   `IslandShot{islandID, strokeHostTime, preStateDigest, outcome, postState, confidence}`. The successor-side island
   claims `term+1` so play continues if the host is truly dead; the old host's island keeps its term.
2. Ratings/eval cards still show locally (they are recomputable), marked provisional internally.
3. **Heal → deterministic merge** (pure function in CueCore, `IslandMerge`):
   - Align shots across islands by stroke time (`|Δt| ≤ 0.5 s` in host time; the last good clock fit drifts
     ≈ 3 ms/min at 50 ppm) **and** pre-state (every ball within 1 ball radius).
   - Matched pair, same outcome → one event. Matched, different outcome → keep the higher-confidence view's
     outcome and mark it **"needs tap"** on the next post-shot card. Unmatched → keep (only one side saw it).
   - The highest term wins hosting; others become clients; everyone re-folds the merged log.
4. ≥3 phones: the majority side elects and commits normally; minority islands merge on heal the same way.
5. **Alternative (Q12):** freeze on partition (overlay keeps running, no shots recorded, "needs tap" for shots in
   the gap). Simpler, but loses shots in every blip.

**Mid-shot host loss:** the shot in flight is re-run from the last committed `TableState`; if no tracker is
confident, "needs tap". Engine results are recomputed from the log by the new host.

### 2.6 Detection streaming and fusion inputs

- Each phone runs its own detector + tracker and sends `DetectionFrame` on `.realtime` (best effort).
- **Compact realtime envelope** (the JSON-era `Envelope` is for `.control` only; sessionID and UUIDs are
  implied by the authenticated connection after the handshake):

| Field | Bytes |
|---|---|
| magic `0xC0E0` | 2 |
| major, layout | 1 + 1 |
| type | 1 |
| peerIndex (assigned in `Welcome`) | 1 |
| term (low 16 bits) | 2 |
| seq | 4 |
| captureHostTime (ns) | 8 |
| offset estimate + uncertainty (f16 ms each) | 4 |
| ballCount | 1 |
| **header total** | **25** |
| per ball: id u8, x u16, y u16, σ u16 (fixed-point), flags u8 | 8 |

- **Resolution:** x/y as u16 fixed-point over 0–3 m → **0.046 mm** steps. (Rev 1's f16 gave ≈ 1 mm below 2 m
  and ≈ 2 mm between 2 and 2.54 m; fixed-point is same size and better.)
- **On wire, 16 balls:** 25 + 128 = **153 B payload**, plus QUIC short header + datagram frame + UDP/IPv6 overhead
  (*≈ 70 B, estimate*) ≈ 225 B. At 30 fps ≈ **6.8 kB/s per peer, ≈ 47 kB/s into the host at 7 peers**. One datagram,
  no fragmentation.
- The host converts to its timeline, interpolates each peer's Kalman state onto a common 30 Hz grid, and fuses
  with confidence weights. Fusion itself belongs to the tracking design.
- `StrokeObservation` (stroke start/end, cue line, `PersonEvidence`, §7.3) goes on `.control`.

### 2.7 Clip transfer (D3)

D3: "Best-angle clip (~5 s) is sent to the host over MPC after balls settle, never while anyone is aiming."

**Real clip length (flag for the user, Q6).** Spec §9 defines the clip as ~3 s before the stroke → ~2 s after
settle. Ball motion takes roughly 3–8 s (*assumption*, measure in replays), so a clip is **≈ 8–13 s, not ~5 s**.
At 720p30 HEVC, 4–6 Mbit/s (*assumption*) that is **≈ 4–10 MB**.

1. Host commits `ShotRecorded` → `PhaseChange(.settled, shotID)`.
2. Phones reply `ClipOffer(shotID, viewScore, byteSize)`; host picks the best (its own wins ties: no transfer).
3. Winner cuts the clip **by passthrough at keyframes**, not re-encode: the rolling buffer is written by the media
   engine as 720p HEVC with a 1 s GOP (*assumption*), so trimming is an `AVAssetExportSession` passthrough,
   cheap and off the ANE/GPU. The clip may start up to 1 s early; the player trims at playback. Burned-in paths
   (§9) are drawn by the host at review time, not by the sender.
4. Stream on `.bulk` in 256 kB chunks with a flow-controlled loop [TN3213]; per-chunk SHA-256 for resume.
5. **"Never while aiming" gate = detected address only.** `PhaseChange(.aiming)` fires when any phone sees a
   person in address pose near the cue ball (pose + cue near cue ball), or when the gate is unsure (a person bent
   over the table with low pose confidence counts as aiming). **No timer**; rev 1's "2 s after settle" timer
   contradicted the 8 s QA assumption and is removed. On `.aiming`, senders pause at the next chunk boundary and
   resume after the next `.settled`. `ClipScheduler` owns this and is property-tested (§9).
6. Many clips will span 2–3 settle windows. That is fine: SotG needs only the chosen shot, and the source phone
   keeps its buffer until game end (the host can also fetch the SotG clip at game end).
7. QA uses the **measured** settle→address distribution from replays, not a guessed 8 s (§9.3).

---

## 3. Protocol message list

### 3.1 Envelopes

- `.realtime`: compact binary header (§2.6).
- `.control` / `.bulk`: `ControlEnvelope { magic "CUE", major u8, minor u8, type u16, term u32, seq u64, sentHostTime i64, payload }` (≈ 27 B header + JSON payload). `sessionID` and sender are bound to the connection after `Welcome`; they appear only in `Hello`/`Welcome`.

### 3.2 Messages

| # | Type | Dir | Channel | Purpose / key fields |
|---|---|---|---|---|
| 1 | `Hello` | C→H | control | `sessionID`, `supportedMajor`, `minor`, `appBuild`, `deviceClass`, capability bits (`lidar`, `foundationModels`, `faceConsent`, `appearanceConsent`) |
| 2 | `SASCommit` | C→H | control | `SHA256(n_C)` |
| 3 | `SASNonce` | H→C | control | `n_H` |
| 4 | `SASReveal` | C→H | control | `n_C` |
| 5 | `SASConfirm` | **both** | control | `accepted: Bool`; both must be true |
| 6 | `Welcome` | H→C | control | chosen version, `assignedPeerID`, `peerIndex`, `term`, roster, `logSnapshot`, successor endpoint + `successorSPKI` |
| 7 | `Reject` | H→C | control | `.versionTooOld/.versionTooNew/.sessionFull/.sasDeclined/.gameInProgressLocked` → icon |
| 8 | `Leave` | both | control | graceful departure |
| 9 | `PeerStatus` | C→H, H→all | control | battery bucket, onPower, thermal, fps, calibration residual, coverage mask |
| 10 | `Heartbeat` | H→all | control + realtime | `term`, `commitSeq`, `succession`, `phase` |
| 11 | `StandbyHello` / `StandbyKeepalive` | C→successor | control (standby link) | pinned by `successorSPKI` |
| 12 | `HostClaim` | new H→all | control (standby links) | `term+1`, `lastSeq` |
| 13 | `HostHandoff` | H→successor | control | graceful migration |
| 14 | `IslandLog` / `MergeResult` | any↔new H | control | island shots after heal; merged log (§2.5) |
| 15 | `TimePing` / `TimePong` | C↔H | realtime | `t0` / `t0,t1,t2` |
| 16 | `ProfileSummary` | C→H→all | control | `playerID` (random per profile), avatar, colour, initials, skill summary. No history. |
| 17 | `IdentityTemplate` | owner → **host + successor only** | control | only with face consent and only over a SAS-authenticated link; `playerID`, `modelID+version`, face embeddings; `expiresAt = session end`. Re-sent by the owner to a new successor/host after migration. |
| 18 | `IdentityRevoke` | any→all | control | purge now |
| 19 | `AppearanceBind` | any→H | control | `playerID`, `trackID` (tap-to-bind, §7.2) |
| 20 | `RosterUpdate` | H→all | control (log) | teams, order, guests |
| 21 | `RuleVoteOpen` / `RuleBallot` / `RuleVoteResult` | H↔all | control (log) | §3 poll |
| 22 | `CalibrationReport` | C→H | control | homography + residual, plane offset, table size estimate |
| 23 | `DetectionFrame` | C→H | realtime | §2.6 |
| 24 | `StrokeObservation` | C→H | control | stroke times, cue line, `[PersonEvidence]` (§7.3) |
| 25 | `PhaseChange` | H→all | control | `.aiming`, `.inMotion`, `.settled(shotID)`, `.gameOver` |
| 26 | `GameEvent` / `LogAck` | H→all / C→H | control | log entry / ack |
| 27 | `LogTailRequest` / `LogTail` | any | control | catch-up |
| 28 | `ShooterCorrection` | any→H | control | `shotID`, `playerID` |
| 29 | `ClipOffer` / `ClipRequest` / `ClipCancel` / `ClipComplete` | C↔H | control | as §2.7 |
| 30 | `ClipChunk` | C→H | bulk | `shotID`, `offset`, bytes, `sha256` |
| 31 | `PostShotCard` | H→all | control | ratings + eval swing (or recomputed locally) |

### 3.3 Versioning rules

- **`major`**: any change that breaks decoding or meaning. Session runs on the highest common major; none → `Reject` → "update" icon. Matters because Personal Team builds expire every 7 days.
- **`minor`**: additive only (optional JSON fields, new message types; unknown `type` ignored and counted in the debug HUD).
- Realtime binary layouts are versioned by `major` + `layout`.
- `IdentityTemplate.modelID+version` mismatch → ignored; that player falls back to turn order.
- Golden fixtures (`Fixtures/mesh/v1/*.bin|json`) frozen per major; decoding old fixtures stays a test forever.

---

## 4. Clock synchronization algorithm

**Goal:** fuse detections on one timeline. **Target:** |offset error| ≤ 5 ms p95 (*assumption*, 1/6 frame at 30 fps; a
2 m/s ball moves 1 cm in 5 ms).

**Timebase:** `CMSampleBuffer` PTS on the host-time clock (`CMClockGetHostTimeClock`) [SYNCCLK]; pings use the same clock.

**Algorithm (NTP-style, client ↔ host) [RFC5905 §8, §10]:**

1. `TimePing(t0)` → host `t1`, `TimePong(t0,t1,t2)` → client `t3`. `θ = ((t1−t0)+(t2−t3))/2`, `δ = (t3−t0)−(t2−t1)`.
2. Burst at join: 16 pings 20 ms apart; then 1 Hz.
3. Clock filter: last 64 samples, use the lowest-delay quartile [RFC5905; AWDL].
4. Drift: weighted LSQ `θ(t) = a + b·t` over 60 s, weight ∝ 1/δ². Uncertainty `u = min(δ)/2 + residual σ`.
5. Outliers: drop `δ > 3 × median(δ)`; reset the fit on a persistent step > 10 ms.
6. Host migration: compose offsets from each client's fit against every peer, then re-burst.
7. **Visual cross-check:** cue-ball first motion and ball-ball collisions are seen by every view; the fused-time
   residual is a direct sync-error measurement, logged per shot. Per-peer correction only when residuals agree
   (MAD < 4 ms).

**What radio sync cannot see: per-device capture bias.** PTS marks a fixed point of the exposure, but the
PTS-to-photon relation (exposure duration, rolling-shutter readout) differs per sensor and mode, so the 15 PM and
17 PM can carry a **constant ms-scale bias** NTP never observes (**unverified** magnitude). Mitigations: fix exposure
duration during play (e.g. 1/500 s, *assumption*), compute row time `t_row = PTS + (row/height) × readout`, and
let step 7 estimate the residual constant per device pair. The device test (§9.3) measures it explicitly.

Exposure phases are arbitrary, so the host interpolates tracker state to the fusion tick instead of matching frames.

---

## 5. Background, lifecycle, thermal, compute budget

### 5.1 Lifecycle

- **No background operation.** MPC disconnects on background [MPC]. Network framework keeps working in the
  background but **stops once the app is suspended** (DTS, quoted in §1.2) [F836124]. During a session:
  `isIdleTimerDisabled = true`, camera running, "paused" glyph if the app leaves the foreground.
- **Resume:** reconnect with `sessionID + playerID`, `LogTailRequest(from: lastSeq)`, re-burst clock. A host that
  was away is an island on its return and merges per §2.5 (not "just rejoins as client").
- **Local-network permission:** asked in the lobby, one visual step, never mid-game [TN3179].
- **AWDL cost:** hurts venue Wi-Fi and our own [TN3213, AWDL-lat]. Stop browsing after joining. Whether NF prefers
  a shared infrastructure network when both are available is **unverified** (§1.2); we log the path in use.

### 5.2 Compute and thermal budget (15 Pro Max is the perf gate)

Rev 1 asserted "Low/Med" thermal risk with no basis. Thermal risk is **unknown until measured**. All ms numbers
below are **budgets (assumptions)**, not measurements; the benchmark task `MESH-ID-BENCH` fills the "measured"
column on the 15 PM before Phase 5 code is committed.

**Principle:** identity work is **event-driven, never per-frame**: lobby check-in windows and a ±0.5 s window
around each stroke start. 3D body pose is dropped (2D pose + table-plane distance is enough for "shooting pose
nearest the cue ball").

| Work | Unit | Rate | Budget per run (assumption) | 15 PM client | 15 PM host | Measured |
|---|---|---|---|---|---|---|
| YOLO ball detector | ANE | 30 Hz | ≤ 12 ms | yes | yes | TBD |
| Ball-ID classifier on crops | ANE/CPU | 30 Hz | ≤ 3 ms | yes | yes | TBD |
| Tracker (Kalman) | CPU | 30 Hz | ≤ 1 ms | yes | yes | TBD |
| 2D body pose (owned by perception) | ANE | 15 Hz, only with a person near the table | ≤ 6 ms | yes | yes | TBD |
| Cue-line detection | GPU/CPU | 30 Hz while aiming | ≤ 4 ms | yes | yes | TBD |
| Overlay | GPU | 60 Hz | ≤ 4 ms/frame | yes | yes | TBD |
| Rolling buffer HEVC + passthrough trim | media engine | continuous | ~0 ANE/GPU | yes | yes | TBD (power) |
| DetectionFrame encode/send | CPU | 30 Hz | ≤ 0.3 ms | yes | — | TBD |
| **Identity: stroke window** (instance mask ×1, feature print per person ≤ 4, HSV on CPU) | ANE+CPU | ≈ 1 burst per shot | ≤ 60 ms total, spread over 3 frames | only with appearance consent | same | TBD |
| **Identity: face** (detect + quality + SFace on ≤ 3 faces) | ANE | lobby check-in ≤ 10 s at 5 Hz; stroke window only if face-consented players | ≤ 15 ms per run | host + successor only (§7.2) | yes | TBD |
| Fusion | CPU | 30 Hz | ≤ 2 ms | — | yes | TBD |
| Rules + log | CPU | per shot | ≤ 5 ms | — | yes | TBD |
| ShotEngine Monte Carlo | CPU/GPU, low QoS | after settle | < 3 s wall (Phase 2 gate) | — | yes | TBD |
| Clip receive + SHA | CPU | per shot | ≤ 50 ms total | — | yes | TBD |

**Gates tied to this table:** with identity enabled, the 15 PM still holds **≥ 30 fps** detection (Phase 3) and
**≥ 24 fps after 1 h** as host (Phase 9). If it can't, identity bursts drop to "lobby only" and attribution relies
on turn order + tap. Hot peers (`PeerStatus.thermal ≥ .serious`) drop `DetectionFrame` to 15 fps or go
"observer only".

---

## 6. Identity: findings

| Need | Apple on-device option | Gap / note | Source |
|---|---|---|---|
| Faces + quality | `VNDetectFaceRectanglesRequest`, `VNDetectFaceCaptureQualityRequest` | Gate enrolment and matching | VFACEQ |
| **Face identity embedding** | **None.** `VNFaceObservation` has no identity vector; Vision = detection, not recognition | Needs a Core ML model | VFACEOBS, F79961 |
| Generic embedding | `GenerateImageFeaturePrintRequest` (iOS 18+) | Not trained for identity; fine for clothing | VFP |
| Find people | `VNDetectHumanRectanglesRequest` | Box per person | VHUMAN |
| Separate people | `VNGeneratePersonInstanceMaskRequest` (per-person) vs segmentation (one matte) | Instance masks keep clothing crops clean; heavy, so event-time only (§5.2) | VINST, VSEG |
| Shooting pose | `VNDetectHumanBodyPoseRequest` (2D) | Bent torso + forearm along cue + bridge hand near cue ball | VPOSE |

**Model licence table (public repo, D5). Gating task `LIC-ID`: no identity weights are bundled until this table is complete.**

| Model | Weights licence | Training data | Data terms | Status |
|---|---|---|---|---|
| Apple Vision feature print | OS API, nothing bundled | n/a | n/a | **Clear** (clothing cue) |
| SFace (OpenCV Zoo) | Apache-2.0 for the zoo files [SFACE] | **Not stated** in the zoo README [SFACE]. The SFace paper trains on CASIA-WebFace, VGGFace2 and MS-Celeb-1M [SFACE-paper] | MS-Celeb-1M was withdrawn by Microsoft in 2019 [MSCELEB]; CASIA-WebFace / VGGFace2 are research-licensed (**unverified** exact terms) | **Unknown → blocked.** Ask upstream which set the zoo weights used. Risk: redistributing weights derived from withdrawn or non-commercial data in a public repo. |
| InsightFace (ArcFace etc.) | Non-commercial research only [INSIGHT] | — | — | **Rejected** |
| OSNet (Torchreid) | MIT [OSNET-LIC] | Market-1501, DukeMTMC-reID, MSMT17 | DukeMTMC withdrawn in 2019 [DUKE]; others research terms | **Blocked** unless weights trained without Duke and terms allow redistribution |

Default while `LIC-ID` is open: **clothing first** with Apple feature prints + HSV (Q4).

**Practical constraint (reasoned, to verify):** cameras are 2–4 m away and shooters bend over the cue, so faces are
small, steep and often turned away at stroke start. Face is a **check-in** cue at most; clothing is the in-session cue.

---

## 7. Identity: design

### 7.1 Consent and enrolment (opt-in, on the player's own phone)

**Two separate consents (Q9),** both off by default, each with its own deliberate "Agree" tap:

| Consent | What it allows | Stored where |
|---|---|---|
| **Clothes** ("recognize my clothes during a game") | A session-only appearance template of this player (feature print + HSV of their instance mask) | Nowhere on disk; RAM on host + successor for the session |
| **Face** ("recognize my face at check-in") | A face template enrolled once on the player's phone | Player's phone only; RAM on host + successor during a session |

Rev 1 had one combined toggle. Separate toggles let a player accept the low-risk clothing cue without a face
template. If the user prefers one toggle, it must cover both and say so.

**Consent screen (Q15).** Text is allowed here: spec §2 limits text only while aiming and on badges. The screen
uses a short plain-language paragraph (≈ 3 sentences: what is captured, where it lives, how long, how to delete)
plus a link to an in-app **retention and destruction policy** page. Icons support the text, not replace it. Rev 1's
"three icons + ≤2-word labels" was an over-reading of §2 and is unlikely to be *informed* consent under BIPA.
Consent record `{consentType, version, date}` stored locally; re-asked when the model or data use changes.

**Face enrolment (only with face consent).** Front camera, slow head turn, keep 8–12 frames with
`faceCaptureQuality ≥ 0.5` (*assumption*) across yaw buckets, compute embeddings, **discard the frames**.
`IdentityTemplate {playerID, modelID+version, [faceEmbedding], createdAt}` in a separate file, Application Support,
`FileProtectionType.complete`, excluded from backup, not in the JSON export by default (Q5).

**Deviation from SPEC §5.8, flagged (Q14).** §5.8 says "face + upper-body embeddings at registration". This design
enrols **face only** at registration and builds upper-body appearance **per session**, because clothing changes
between sessions. Also: enrolment uses the **front** camera at arm's length; matching happens on **rear** cameras
2–4 m away. That domain gap is unmeasured; τ_face is not trusted until a replay study measures
front-enrolled vs rear-observed similarity (§9.3).

### 7.2 Session check-in and data flow (one flow, stated once)

**Who holds what:**

| Data | Computed on | Crosses the mesh? | Lives |
|---|---|---|---|
| Face template (opted-in player) | Player's own phone (enrolment) | Yes: owner → **host and successor only**, after SAS | Owner's disk; host/successor RAM until session end, `Leave`, revoke or app exit |
| Face embedding of a face seen by a table camera | **Host and successor phones only**, on-device | **Never** | **Same frame**: compared against the opted-in templates in RAM, then discarded. Non-matching embeddings are never stored, sent or logged. |
| Face match result | Host / successor | `{trackID, playerID, score}` only if above a floor; within the host it is local | Session RAM |
| Appearance template (clothes-consented player) | Host (from its own and the successor's views) | Feature-print vectors successor → host only | Host + successor RAM for the session |
| Person tracks of anyone else | Every camera phone | `trackID`, 2D pose summary, distance to cue ball | Ephemeral, while in view |

So **the host phone does hold other people's data in RAM** during a session (rev 1's "we never hold anyone's data"
was wrong and is removed).

**Check-in options:**

- **Tap-to-bind (default, no face processing of anyone):** in the lobby, a phone shows the person tracks it sees
  as silhouettes; a clothes-consented player taps their own silhouette → `AppearanceBind` → host seeds the
  session appearance template from that track.
- **Turn-order bind (clothes consent only):** at the player's first turn, the shooting-pose track seeds their
  appearance template.
- **Face check-in (only if face consent and Q10 = allow):** runs in a short window (≤ 10 s, started by an
  opted-in player), only on host and successor cameras. Every face in view is embedded transiently and compared
  to templates in the same frame (see table). **That transient embedding of bystanders' faces is itself a
  "scan of face geometry" question** (§7.4) and is a user + legal decision (Q10), not a default.
- **No consent (players, guests, bystanders):** no appearance vector, no face embedding. Attribution uses turn
  order, shooting-pose evidence ("someone is shooting") and the one-tap fix. Whether clothing re-ID may be used
  for non-opted-in players, guests or bystanders is **Q8**; default **no**.
- **Guests** get a colour avatar and no profile; they can give clothes consent on the host phone if Q8 allows
  guest consent (stats fate: Q3).

**Template distribution (Q11).** Templates go only to host + successor, so at most two phones besides the owner
hold them. Cost: face matching uses at most two views. In 2–3 phone sessions that is nearly every view. On
migration the **owner re-sends** to the new host/successor; nothing is pre-broadcast.

### 7.3 Shooter attribution at stroke start (§5.8)

`StrokeObservation.persons[]` per view: `{trackID, poseScore, distToCueBall, appearanceMatch?: [playerID: score],
faceMatch?: [playerID: score]}`. Match fields exist only for consented players and only from host/successor views.

```
P(player p shot) ∝ Prior(p) × Π_views L_view(p)
Prior(p)  = 0.80 for the expected shooter by turn order/ball-in-hand rules, rest spread (assumption; tune on replays)
L_view(p) = Σ_tracks w(track) · s_p(track),  w = softmax(poseScore − λ·distToCueBall)
s_p       = calibrated similarity (Platt-scaled) for consented players; a flat 1 for non-consented players
```

- Decide when `max P ≥ 0.85` with a 0.3 margin (*assumptions*); else turn order. Nothing shown while aiming.
  Post-shot card shows the shooter avatar with a "tap to fix" affordance.
- **One-tap correction** → `ShooterCorrection` → log event; updates the session appearance template **only for
  clothes-consented players**.
- Teams: the prior narrows to the team in turn.

**Phase 5 metric (Q16).** "Attribution ≥ 90 % with tap fallback" is ambiguous; if taps count as correct the gate
is trivially met. Proposed definition: **≥ 90 % of shots correctly attributed before any tap** (auto-decision or
turn-order fallback), with the **tap rate reported** alongside, and face-only / clothing-only / turn-order-only
broken out.

### 7.4 Privacy design summary

| Rule (spec §2, CLAUDE.md) | Mechanism |
|---|---|
| Opt-in per player, face **and** appearance | Two consents, both off by default (§7.1). No consent → no vectors at all. |
| Embeddings only on the player's phone | Face template file on the owner's phone only. Host/successor hold it in RAM; peer-side `TemplateStore` has no persistence API, enforced by test. |
| Shared only over the local mesh, active session | Only to host + successor, only after commit-reveal SAS (§2.3). Never with "no auth" (Q2). Never in TXT records, export, logs or crash data. |
| One-tap delete | Settings → delete: wipe template + consent records, `IdentityRevoke` to the current session, clear session appearance template. Visual confirmation, no undo. |
| Bystanders | Track IDs + pose only. **No appearance vectors.** Face embeddings only in a face check-in window if Q10 allows, discarded the same frame. |
| No images leave the phone | Only vectors and scores cross the mesh. Clips (D3) are table views that may show people; they stay in-app and are deleted with the game unless saved (Phase 7). |
| Training ≠ competitive | Identity is not used in Training mode. |
| Legal note (not legal advice) | The user is in Illinois (UIUC, D7). BIPA covers "scan of … face geometry" and requires informed written consent and a public retention/destruction policy from a *private entity in possession* [BIPA, BIPA-txt]. The host and successor phones do hold other players' templates in RAM, and transient face embedding of bystanders (if Q10 allows it) may count as a scan. Mitigations: consent text + policy page (Q15), retention rule (Q5), one-tap delete, template minimisation (Q11), face off by default for bystanders. **Flag for the user before any public distribution.** |

---

## 8. Risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | MPC deprecated (Xcode 27); iOS 26+ connect regressions with no supported recovery | High / High | NF adapter (Q1); MPC adapter only if the user insists |
| R2 | AWDL flakiness with Wi-Fi on but not joined | Med / High | Retry with backoff; partition merge (§2.5); join matrix (§9.3); one-phone mode |
| R3 | Local network permission denied/delayed | Med / Med | Lobby-time request; wait-capable APIs; one-phone glyph |
| R4 | Clips are 4–10 MB and span several settle windows | High / Low | Passthrough trim; pause/resume; SotG fetch at game end |
| R5 | Clock error > 1 frame (AWDL asymmetry, per-device capture bias) | Med / Med | Low-delay filter + drift fit + visual cross-check + bias test |
| R6 | Partition in a 2-phone session duplicates or loses shots | **High** / Med | Island mode + deterministic merge; partition/heal/flap sims (§9) |
| R7 | App versions differ (7-day expiry) | High / Low | Version negotiation, golden fixtures |
| R8 | Face recognition poor at table distance; front/rear domain gap | High / Med | Face only for check-in; replay measurement before trusting τ_face |
| R9 | Clothing collisions (team shirts) | Med / Med | Lower body + position history + turn prior; tap fix |
| R10 | Face/re-ID weights trained on withdrawn or non-commercial data, redistributed in a public repo | **High** / High | `LIC-ID` gating task; clothing-first default |
| R11 | BIPA exposure (templates in host RAM, transient bystander scans) | Med (if distributed) / High | §7.4; user decisions Q8–Q11, Q15 |
| R12 | Thermal/compute: identity + detector + overlay + engine on the 15 PM host | **Unknown** / High | §5.2 budget, `MESH-ID-BENCH`, event-driven identity |
| R13 | Bandwidth/airtime from 7 peers (~47 kB/s) hurting the 60 fps overlay | Low / Med | Datagrams; no video streaming |
| R14 | swift-certificates dependency vs "no SDKs that phone home" | Low / Low | Apple-maintained Apache-2.0, no network code. If rejected, the only honest alternative is no auth (Q2) |
| R15 | Wi-Fi radio off → no mesh at all with NF (MPC could use Bluetooth) | Med / Low | One-phone mode; "turn Wi-Fi on" glyph |

---

## 9. TDD / QA plan

### 9.1 Pure-Swift unit tests (`Packages/CueCore`, `swift test`, write them first)

| Module | Red tests to write first |
|---|---|
| `MeshCodec` | Round-trip every message; golden fixtures per major; unknown `type` ignored; unknown JSON keys tolerated; fuzz 10k random buffers; **`DetectionFrame` with 16 balls = 153 B including the realtime header**; fixed-point x/y round-trip error ≤ 0.05 mm |
| `SAS` | Same inputs → same 4 icons on both sides; reveal not matching commit → abort; property: changing any of hostSPKI, clientSPKI, n_C, n_H changes the SAS with p ≈ 1−2⁻²⁴ over random trials; state machine refuses to compute the SAS before the reveal; both confirms required |
| `VersionNegotiator` | Highest common major; no overlap → correct `Reject` |
| `ClockSync` | Sim network with offset/skew, 2 ms up / 9 ms down asymmetry, jitter, 20 % loss, AWDL-like spikes → p95 ≤ 5 ms after burst, ≤ 2 ms after 60 s; 50 ppm skew; step reset; composition across host change; visual correction only when MAD < 4 ms |
| `HostElection` | Same inputs → same host (random gossip order); hysteresis; term monotonic; stale claims ignored; parameterised over options A/B/C (Q7) |
| `GameLog` / `Replication` | `fold(log)` = live state; majority-of-members commit; tail catch-up; **kill-host sims** (1,000 seeded games) |
| `IslandMerge` | **Partition + heal sims**: random partition start/length (0.5–60 s), both islands observe the same synthetic shot sequence with noisy timing/outcomes, random one-sided misses → every physical shot appears exactly once if any side saw it; disagreeing outcomes flagged "needs tap"; merge is deterministic and order-independent. **Flap test**: link toggles every 0.5–3 s for 5 simulated minutes → no duplicate shots, terms bounded, host changes ≤ k (hysteresis) |
| `FailureDetector` | Driven by recorded AWDL gap traces from §9.3: no false claim on gaps < `T_fail`; detection ≤ `T_fail` + one heartbeat |
| `ClipScheduler` | **Property: zero chunk sends while phase == `.aiming` or gate unsure**; pause/resume keeps offset across several settle windows; best-view pick; own-clip short-circuit; SHA mismatch → retransmit |
| `ShooterAttribution` | Correct pick with strong evidence; turn order under threshold; corrections update only clothes-consented templates; never picks someone not in the roster; **non-consented players never get a similarity input** |
| `IdentityMatcher` | Cosine/margin on synthetic vectors; model mismatch ignored; **non-matching embeddings are dropped in the same call (spy: no retention, no send)** |
| `ConsentStore` / `TemplateStore` | Each consent gates its own paths; no consent → zero identity sends; delete wipes file + emits revoke; peer store has zero writes (spy file manager); templates sent only to host + successor; owner re-sends on migration |
| `NoInternetLint` | No `URLSession`, no non-`.local` hostnames, `NWEndpoint` only from Bonjour results |

### 9.2 App-level (simulator, XCUITest, `CueCoach iPhone 15 Pro`)

- Lobby with `LoopbackTransport` / `SimTransport`: session glyph tiles, join, both-sides SAS confirm, vote, roster.
- Consent flow: both toggles off by default, separate Agree taps, policy page reachable, delete wipes data, ≥ 44 pt
  targets, **no text while aiming** (snapshot: overlay has no `Text` views).
- Radio, local network privacy and AWDL can't be tested in the simulator [TN3179].

### 9.3 Real devices (iPhone 15 Pro Max = perf gate, iPhone 17 Pro Max = second mesh phone; D6)

| Test | Method | Pass |
|---|---|---|
| `MESH-ID-BENCH` (first) | Fill the §5.2 "measured" column on the 15 PM as client and as host, identity on/off | Phase 3 ≥ 30 fps holds with identity bursts; budget table updated before Phase 5 code merges |
| Join matrix (NF) | {shared Wi-Fi, Wi-Fi on/not joined, Mobile Data on/off} × {15 PM host, 17 PM host} × 20 joins | ≥ 19/20 joins in < 5 s per cell; log the interface used |
| Wi-Fi off cell | Wi-Fi radio off on one phone | **Expected fail** with NF: shows the one-phone / Wi-Fi glyph within 3 s. (MPC adapter: record whether Bluetooth joins.) |
| MPC adapter | Same matrix, chunked bulk mode | Reported separately; not assumed equal to NF |
| Permission | Fresh install, deny, then allow in Settings | Denied → glyph; allow → auto-recovers |
| RTT / gaps | 10 min on control + datagram, AWDL-only and shared Wi-Fi | p50/p95/p99 RTT and **p99.9 inter-heartbeat gap** → sets `T_fail` |
| Throughput | 20 × 8 MB transfers per network cell | Report MB/s; fraction finished within the **measured** settle→address window (from replays) |
| Settle→address | Hand-label ≥ 200 shots in replays | Distribution feeds the throughput criterion and Q6 |
| **Clock sync truth** | Fixed exposure (same duration both phones); a third device's screen flash placed so it falls in the **same row band** in both views; rolling-shutter row correction; repeat with phone roles swapped | p95 \|jitter\| ≤ 5 ms; **constant per-device bias reported separately** (and then corrected) |
| Kill host | Force-quit host at random points over 30 racks | No committed shot lost; resume ≤ `T_fail + 0.5 s` with warm standby |
| **Partition / heal** | Airplane-mode one phone for 2, 5, 30 s mid-rack over 20 racks; also a 5 min flap run (toggle every 1–3 s) | After heal: each physical shot once, conflicts flagged, no duplicate shots |
| Background | Host and client backgrounded 10 s, 60 s | Island + merge, no duplicates |
| Version skew | Builds N vs N+1 minor / N+1 major | Minor joins; major → update icon |
| Thermal | 1-hour 2-phone session, **15 PM forced as host**, identity on | fps ≥ 24 on 15 PM (Phase 9), no disconnect; repeat with 15 PM as client |
| Face domain gap | Front-camera enrolment vs rear-camera matches at 2–4 m in replays (local footage, D5) | ROC per distance; set τ_face only from this |
| Attribution | ≥ 3 recorded 2v2 sessions, hand labels | ≥ 90 % correct **before any tap** (if Q16 accepted); tap rate reported; face / clothing / turn-order breakdown |
| Privacy | Inspect both containers after session end | No peer templates on disk; deleted user leaves nothing; no identity data on phones other than owner/host/successor |

Vendor rule: whoever writes `Mesh/` and `Identity/` doesn't review them (CLAUDE.md, D4); record in `docs/AGENTS.md`.

---

## 10. Open questions for the user (product ambiguity: stop and ask)

| # | Question | Options / my recommendation |
|---|---|---|
| **Q1** | MPC is deprecated in Xcode 27 with iOS 26+ connect bugs; Apple's NF sample did not show the bug. May we amend §2/§5.7 and `CLAUDE.md` to "local peer-to-peer only (Network framework + Bonjour; MPC optional)"? Trade-offs: NF loses MPC's **Bluetooth** path (Wi-Fi off = no mesh); TN3213 says enable peer-to-peer Wi-Fi only if it's a significant benefit and suggests Wi-Fi Aware, which a Personal Team can't get. | **Yes, NF.** Peer-to-peer Wi-Fi is a significant benefit here (tables usually have no shared network). |
| **Q2** | Join security: (a) commit-reveal 4-icon SAS, both phones confirm (needs swift-certificates); (b) QR pinning; (c) **no auth**, in which case no face templates are ever shared. | (a). Real level: one 1-in-16.7 M guess per join, casual-bar threat model. |
| Q3 | Guests: discard stats at game end, or share-sheet export? | Discard |
| Q4 | Face model: SFace is blocked until its training data is known (paper uses MS-Celeb-1M, withdrawn); bundling such weights in the public repo is the risk. Ship clothing + turn order first? | Clothing first; face only after `LIC-ID` clears |
| Q5 | Template retention: until deleted, or auto-expire after N days unused? Include in export? | Auto-expire at 180 days; exclude from export |
| Q6 | D3 says "~5 s" but spec §9's window makes clips ≈ 8–13 s (4–10 MB). Accept the §9 window? If aiming starts mid-transfer: pause/resume across shots, or drop? | Keep §9 window; pause/resume |
| Q7 | Election order (A device first / B battery first / C thermal veto then A, §2.4)? | No recommendation; QA forces 15 PM as host either way |
| **Q8** | May clothing re-ID run on players who did not opt in, guests, or bystanders (§2 "appearance … opt-in" vs §5.8 "clothing re-ID for the session")? | **No** (current default): non-consented → turn order + tap; bystanders → track IDs only |
| Q9 | Two separate consents (clothes, face) or one combined toggle? | Two |
| **Q10** | Face check-in transiently embeds every face in view (bystanders too) on host/successor, discarded the same frame. Allow, or face off entirely and use tap-to-bind? User + legal decision. | Tap-to-bind for Phase 5; decide face later with Q4 |
| Q11 | Templates only to host + successor (fewer views), or to every camera phone (more views, more copies)? | Host + successor |
| Q12 | Partition behaviour: island mode + deterministic merge, or freeze and tap? | Island + merge |
| Q13 | Migration gate: accept "≤ `T_fail` + 0.5 s" if measured AWDL gaps force `T_fail` > 1.5 s (and ≤ 10 s if successor also lost)? | Yes |
| Q14 | §5.8 says face + upper-body at registration; design enrols face only and builds clothing per session. OK? | Yes |
| Q15 | Consent screen with short plain text + retention/destruction policy page (text outside aiming), instead of icons only? | Yes |
| Q16 | Phase 5 metric: "≥ 90 % correct before any tap, tap rate reported"? Or what does "with tap fallback" mean? | Before any tap |

---

## Reviewer notes (rev 2)

All 20 review points were accepted and fixed above (numbers below are the review's item order). Three were fixed differently from the reviewer's suggestion:

- **Template distribution (MAJOR #11):** rather than "host only", templates go to host **and** successor, because
  the warm-standby failover (§2.5) needs the successor ready to match without re-collecting templates mid-game.
  The owner still re-sends after any migration. Q11 lets the user widen or narrow it.
- **SAS derivation (MAJOR #3):** commit-reveal over SPKIs + fresh nonces, not the TLS exporter, because exporter
  access from the new `NetworkConnection` API is unverified [SECEXP]. The commitment alone gives the one-guess
  property [RFC6189]; the exporter can be added later as defence in depth.
- **Election (MINOR #19):** the rev 1 recommendation (onPower first) is withdrawn rather than defended; Q7 is now
  neutral.
