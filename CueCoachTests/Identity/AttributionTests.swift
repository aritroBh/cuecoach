import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

private func roster(_ entries: [(UUID, RecognitionConsent)], guests: [UUID] = []) -> IdentityRoster {
    IdentityRoster(entries: entries.map { RosterEntry(playerID: $0.0, consent: $0.1) }
                   + guests.map { RosterEntry(playerID: $0, consent: .none, isGuest: true) })
}

private func person(_ track: Int, pose: Double, dist: Double,
                    clothes: [UUID: Double] = [:], face: [UUID: Double] = [:]) -> TrackEvidence {
    TrackEvidence(trackID: track, poseScore: pose, distanceToCueBall: dist,
                  appearanceSimilarity: clothes, faceSimilarity: face)
}

@Suite struct ConsentTests {
    @Test func consentIsOffByDefault() {
        let e = RosterEntry(playerID: Synth.a)
        #expect(e.consent == .none)
        #expect(!e.consent.clothes && !e.consent.face)
    }

    @Test func consentFollowsStoredRecognitionFields() {
        #expect(RecognitionConsent(faceData: Data([1]), appearanceData: nil) == RecognitionConsent(clothes: false, face: true))
        #expect(RecognitionConsent(faceData: nil, appearanceData: Data([1])) == RecognitionConsent(clothes: true, face: false))
        #expect(RecognitionConsent(faceData: nil, appearanceData: nil) == .none)
    }

    @Test func rosterExposesConsentedSubsets() {
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: false, face: true)),
                        (Synth.c, .none)], guests: [Synth.d])
        #expect(r.clothesConsented == [Synth.a])
        #expect(r.faceConsented == [Synth.b])
        #expect(r.anyConsent)
        #expect(!roster([(Synth.a, .none)]).anyConsent)
        #expect(r.contains(Synth.d))
    }
}

@Suite struct ShootingPoseTests {
    let cue = CGPoint(x: 0.5, y: 0.3)

    @Test func bentOverWithBridgeHandAtCueBallScoresHigh() {
        // Torso near horizontal, a wrist right next to the cue ball.
        let shooter = BodyJoints(points: [.neck: CGPoint(x: 0.45, y: 0.42), .root: CGPoint(x: 0.25, y: 0.40),
                                          .leftWrist: CGPoint(x: 0.48, y: 0.31), .rightWrist: CGPoint(x: 0.3, y: 0.38)])
        let standing = BodyJoints(points: [.neck: CGPoint(x: 0.8, y: 0.7), .root: CGPoint(x: 0.8, y: 0.45),
                                           .leftWrist: CGPoint(x: 0.78, y: 0.5), .rightWrist: CGPoint(x: 0.82, y: 0.5)])
        let s = ShootingPose.score(shooter, cueBall: cue)
        let t = ShootingPose.score(standing, cueBall: cue)
        #expect(s > 0.7)
        #expect(t < 0.3)
    }

    @Test func missingJointsGiveZeroNotCrash() {
        #expect(ShootingPose.score(BodyJoints(points: [:]), cueBall: cue) == 0)
    }

    @Test func scoreIsBoundedZeroToOne() {
        let j = BodyJoints(points: [.neck: CGPoint(x: 0.5, y: 0.3), .root: CGPoint(x: 0.1, y: 0.3), .leftWrist: cue])
        let s = ShootingPose.score(j, cueBall: cue)
        #expect(s >= 0 && s <= 1)
    }
}

@Suite struct TrackSmoothingTests {
    @Test func associatesBoxesAcrossFramesByOverlap() {
        var assoc = TrackAssociator()
        let f1 = assoc.assign([CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5), CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.5)])
        let f2 = assoc.assign([CGRect(x: 0.62, y: 0.1, width: 0.2, height: 0.5), CGRect(x: 0.12, y: 0.1, width: 0.2, height: 0.5)])
        #expect(f2[0] == f1[1])
        #expect(f2[1] == f1[0])
        let f3 = assoc.assign([CGRect(x: 0.4, y: 0.6, width: 0.1, height: 0.2)])
        #expect(!Set(f1).contains(f3[0]))
    }

    @Test func briefOcclusionKeepsTheTrackID() {
        var assoc = TrackAssociator()
        let a = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5), b = CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.5)
        let f1 = assoc.assign([a, b])
        _ = assoc.assign([b])                      // a occluded by the cue arm for one frame
        let f3 = assoc.assign([b, a.offsetBy(dx: 0.01, dy: 0)])
        #expect(f3[1] == f1[0])
        #expect(f3[0] == f1[1])
    }

    @Test func longGoneTrackIsRetired() {
        var assoc = TrackAssociator()
        let a = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5)
        let f1 = assoc.assign([a])
        for _ in 0...TrackAssociator.defaultMaxMissed { _ = assoc.assign([]) }
        #expect(assoc.assign([a])[0] != f1[0])
    }

    @Test func smootherAveragesSimilarityAndKeepsBestPose() {
        var sm = TrackEvidenceSmoother()
        sm.add(person(1, pose: 0.2, dist: 0.5, clothes: [Synth.a: 0.9]))
        sm.add(person(1, pose: 0.9, dist: 0.1, clothes: [Synth.a: 0.7]))
        sm.add(person(2, pose: 0.1, dist: 0.6, clothes: [Synth.a: 0.2]))
        let out = Dictionary(uniqueKeysWithValues: sm.evidence().map { ($0.trackID, $0) })
        #expect(abs(out[1]!.appearanceSimilarity[Synth.a]! - 0.8) < 1e-9)
        #expect(out[1]!.poseScore == 0.9)
        #expect(out[1]!.distanceToCueBall == 0.1)
        #expect(out.count == 2)
    }

    @Test func oneOutlierFrameDoesNotFlipATrack() {
        var sm = TrackEvidenceSmoother()
        for _ in 0..<5 { sm.add(person(1, pose: 0.9, dist: 0.1, clothes: [Synth.a: 0.9, Synth.b: 0.3])) }
        sm.add(person(1, pose: 0.9, dist: 0.1, clothes: [Synth.a: 0.2, Synth.b: 0.95]))
        let e = sm.evidence()[0]
        #expect(e.appearanceSimilarity[Synth.a]! > e.appearanceSimilarity[Synth.b]!)
    }
}

@Suite struct ShooterAttributionTests {
    let attributor = ShooterAttributor()

    @Test func strongClothingEvidencePicksTheShooterEvenAgainstTurnOrder() {
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let views = [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.a: 0.30, Synth.b: 0.96]),
                      person(2, pose: 0.05, dist: 0.8, clothes: [Synth.a: 0.95, Synth.b: 0.2])]]
        let out = attributor.attribute(views: views, context: ctx)
        #expect(out.playerID == Synth.b)
        #expect(out.source == .auto)
        #expect(out.confidence >= 0.85)
    }

    @Test func confirmingEvidenceForExpectedShooterIsAuto() {
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.9, dist: 0.05, clothes: [Synth.a: 0.95, Synth.b: 0.3])]], context: ctx)
        #expect(out == Attribution(playerID: Synth.a, source: .auto, confidence: out.confidence, shooterTrackID: 1))
    }

    @Test func noEvidenceFallsBackToTurnOrder() {
        let r = roster([(Synth.a, .none), (Synth.b, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.b)
        let out = attributor.attribute(views: [], context: ctx)
        #expect(out.playerID == Synth.b)
        #expect(out.source == .turnOrder)
    }

    @Test func weakOrAmbiguousEvidenceFallsBackToTurnOrder() {
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let views = [[person(1, pose: 0.9, dist: 0.05, clothes: [Synth.a: 0.78, Synth.b: 0.80])]]
        let out = attributor.attribute(views: views, context: ctx)
        // Round 3: a tie between two recognisable players asks instead of crediting A silently.
        #expect(out.playerID == nil)
        #expect(out.source == .unknown && out.suggestedPlayerID == Synth.a)
    }

    @Test func nonConsentedPlayersNeverGetASimilarityInput() {
        // Similarity scores for B leak in (bug upstream) but B never consented → they must be ignored.
        let r = roster([(Synth.a, .none), (Synth.b, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let views = [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.b: 0.99], face: [Synth.b: 0.99])]]
        let out = attributor.attribute(views: views, context: ctx)
        #expect(out.playerID == Synth.a)
        #expect(out.source == .turnOrder)
    }

    /// An identity-trained face model: an unmodelled stranger rarely scores like a template (F4/F6 benchmark value).
    static let identityFace = CueModel(calibration: .init(threshold: 0.75, slope: 25), lookalikeRate: 0.01, lrRange: 0.01...100)

    @Test func faceOnlyCountsWithFaceConsent() {
        let r = roster([(Synth.a, .init(clothes: false, face: false)), (Synth.b, .init(clothes: false, face: true))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        var trained = ShooterAttributor(); trained.parameters.face = Self.identityFace
        let withFace = trained.attribute(views: [[person(1, pose: 0.95, dist: 0.05, face: [Synth.b: 0.99])]], context: ctx)
        #expect(withFace.playerID == Synth.b)
        #expect(withFace.source == .auto)
    }

    @Test func genericFaceEmbeddingNeverOverridesAnUnmodelledExpectedShooter() {
        // CX-7 / F4: the generic feature print is not identity-trained; A (no template) may score like B's face.
        let r = roster([(Synth.a, .none), (Synth.b, .init(clothes: false, face: true))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, face: [Synth.b: 0.99])]], context: ctx)
        #expect(out.playerID != Synth.b && out.source != .auto)   // never B; a tie asks (round 3)
    }

    @Test func genericFaceCanStillConfirmAmongModelledPlayers() {
        let r = roster([(Synth.a, .init(clothes: false, face: true)), (Synth.b, .init(clothes: false, face: true))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, face: [Synth.a: 0.95, Synth.b: 0.3])]], context: ctx)
        #expect(out.playerID == Synth.a && out.source == .auto)
    }

    @Test func neverPicksSomeoneOutsideTheRoster() {
        let r = roster([(Synth.a, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.d: 0.99, Synth.a: 0.1])]], context: ctx)
        #expect(out.playerID == Synth.a)
    }

    @Test func expectedShooterOutsideRosterAsksInsteadOfGuessing() {
        // CX-2: caller error (stale turn state) → never a silent pick; the card asks with one tap.
        let ctx = AttributionContext(roster: roster([]), expectedShooter: Synth.c)
        #expect(attributor.attribute(views: [], context: ctx)
                == .unknown(suggested: Synth.c, confidence: 0, shooterTrackID: nil))
    }

    @Test func teamPriorNarrowsToTeamInTurn() {
        // A and C are team 1 (in turn); B is team 2. Clothes evidence equally between C and B → C wins.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)),
                        (Synth.c, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a, teamInTurn: [Synth.a, Synth.c])
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05,
                                                       clothes: [Synth.a: 0.1, Synth.b: 0.99, Synth.c: 0.99])]], context: ctx)
        // Round 3 (r2 BLOCKER 2): off-team B competes too; C and B tie on evidence, so the card asks.
        #expect(out.playerID != Synth.b && out.source != .auto)
    }

    @Test func consentedLookalikeNeverStealsFromANonConsentedExpectedShooter() {
        // S1: team shirts. A consented, teammate B not. B shoots on B's turn and matches A's shirt at 0.98.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .none), (Synth.c, .none), (Synth.d, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.b, teamInTurn: [Synth.a, Synth.b])
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.a: 0.98])]], context: ctx)
        #expect(out.playerID != Synth.a && out.source != .auto)   // never A; the real tie asks (round 3)
    }

    @Test func guestLookalikeIsNeverMergedOnTheirOwnTurn() {
        // S6: unregistered guest G in clothes like registered A.
        let r = roster([(Synth.a, .init(clothes: true, face: false))], guests: [Synth.d])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.d)
        for cos in [0.80, 0.90, 0.95, 0.99] {
            let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.a: cos])]], context: ctx)
            #expect(out.playerID != Synth.a && out.source != .auto, "cos \(cos)")
        }
    }

    @Test func standingBystanderIsNeverEvidenceWhenTheShooterIsHidden() {
        // S8: shooter occluded; a consented player stands 0.35 from the cue ball and matches strongly.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.05, dist: 0.35, clothes: [Synth.b: 0.97, Synth.a: 0.1])]], context: ctx)
        #expect(out.playerID == Synth.a && out.source == .turnOrder)
        #expect(out.shooterTrackID == nil)
        #expect(!out.needsConfirmation)
    }

    @Test func clearlyNotTheExpectedShooterAsksWithOneTap() {
        // CX-2: A (consented) expected, but the person at the cue ball looks nothing like A and a guest is present.
        let r = roster([(Synth.a, .init(clothes: true, face: false))], guests: [Synth.d])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.a: 0.05])]], context: ctx)
        #expect(out.source == .unknown && out.needsConfirmation && out.playerID == nil)
    }

    @Test func lookalikeGuestShootingOutOfTurnIsNotConfirmedAsTheExpectedPlayer() {
        // S10: A expected; guest G (could wear A's shirt) shoots and matches A. The turn prior alone must not make it
        // `.auto` — attribution stays A by turn order, never a confident merge.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)),
                        (Synth.c, .init(clothes: true, face: false))], guests: [Synth.d])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.a: 0.9, Synth.b: 0.2, Synth.c: 0.2])]], context: ctx)
        // Round 3: not even a silent turn-order credit to A: the guest may be the one shooting.
        #expect(out.playerID == nil && out.source == .unknown)
    }

    @Test func unmodelledExpectedShooterIsNeverAuto() {
        // The open-set lookalike LR keeps D possible; it is not recognition, so D stays turn order.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)),
                        (Synth.c, .none), (Synth.d, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.d)
        let out = attributor.attribute(views: [[person(1, pose: 0.95, dist: 0.05, clothes: [Synth.a: 0.93, Synth.b: 0.48])]], context: ctx)
        #expect(out.playerID != Synth.a && out.source != .auto)
    }

    @Test func staleTeamInTurnIsIgnored() {
        // CX-9: expected shooter not in the team in turn (foul / re-rack / roster change) → the team is not trusted.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)),
                        (Synth.c, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a, teamInTurn: [Synth.b])
        #expect(ctx.plausibleShooters == [Synth.a, Synth.b, Synth.c])
        let p = attributor.prior(ctx)
        #expect(abs(p[Synth.b]! - p[Synth.c]!) < 1e-12)
    }

    @Test func multipleViewsCombine() {
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false))])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let oneView = [[person(1, pose: 0.9, dist: 0.05, clothes: [Synth.a: 0.6, Synth.b: 0.88])]]
        let twoViews = oneView + [[person(7, pose: 0.9, dist: 0.05, clothes: [Synth.a: 0.6, Synth.b: 0.88])]]
        let p1 = attributor.posterior(views: oneView, context: ctx)[Synth.b]!
        let p2 = attributor.posterior(views: twoViews, context: ctx)[Synth.b]!
        #expect(p2 > p1)
    }

    @Test func posteriorSumsToOne() {
        let r = roster([(Synth.a, .init(clothes: true, face: true)), (Synth.b, .none), (Synth.c, .none)], guests: [Synth.d])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.b)
        let p = attributor.posterior(views: [[person(1, pose: 0.5, dist: 0.3, clothes: [Synth.a: 0.7])]], context: ctx)
        #expect(abs(p.values.reduce(0, +) - 1) < 1e-9)
        #expect(Set(p.keys) == [Synth.a, Synth.b, Synth.c, Synth.d])
    }

    struct SynthResult {
        var inTurn: Double, outConsented: Double, overall: Double
        /// Accuracy of "always the expected shooter" on the same shots.
        var turnOrderOnly: Double
        /// `.auto` picks that named the wrong player.
        var wrongAuto: Int
        /// Shots credited to the wrong player (any source). `.unknown` credits nobody.
        var wrongCredited: Double = 0
    }

    /// Synthetic 2v2: A, B consent to clothes, C, D don't. Similarity noise σ = 0.06.
    /// `genuine` is the mean cosine of the real shooter against their own template (0.92 = same camera;
    /// ~0.6 = the unmeasured front-enrol / rear-observe domain gap, research §7.1).
    /// `allConsented`: C, D consent too. Otherwise C, D are unmodelled, and (S1) nobody may be auto-picked over them.
    private func synthSession(outOfTurnRate: Double, genuine: Double = 0.92, n: Int = 800,
                              allConsented: Bool = true) -> SynthResult {
        var rng = SplitMix(seed: 42)
        let players = [Synth.a, Synth.b, Synth.c, Synth.d]
        let cd: RecognitionConsent = allConsented ? .init(clothes: true, face: false) : .none
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)),
                        (Synth.c, cd), (Synth.d, cd)])
        let modelled = allConsented ? players : [Synth.a, Synth.b]
        var inTurn = (0, 0), outConsented = (0, 0), all = 0, baseline = 0, wrongAuto = 0, wrongCredit = 0
        for i in 0..<n {
            let expected = players[i % 4]
            let actual = rng.unit() < outOfTurnRate ? players[(i + 1 + Int(rng.unit() * 3)) % 4] : expected
            var sims: [UUID: Double] = [:]
            for p in modelled {
                sims[p] = min(1, max(-1, (p == actual ? genuine : 0.45) + 0.06 * rng.gaussian()))
            }
            let ctx = AttributionContext(roster: r, expectedShooter: expected)
            let out = attributor.attribute(views: [[person(1, pose: 0.9, dist: 0.05, clothes: sims),
                                                   person(2, pose: 0.1, dist: 0.7)]], context: ctx)
            let ok = out.playerID == actual
            if ok { all += 1 }
            if expected == actual { baseline += 1 }
            if out.source == .auto, !ok { wrongAuto += 1 }
            if out.playerID != nil, !ok { wrongCredit += 1 }
            if actual == expected { inTurn.1 += 1; if ok { inTurn.0 += 1 } }
            else if r.clothesConsented.contains(actual) { outConsented.1 += 1; if ok { outConsented.0 += 1 } }
        }
        return SynthResult(inTurn: Double(inTurn.0) / Double(max(inTurn.1, 1)),
                           outConsented: Double(outConsented.0) / Double(max(outConsented.1, 1)),
                           overall: Double(all) / Double(n), turnOrderOnly: Double(baseline) / Double(n), wrongAuto: wrongAuto,
                           wrongCredited: Double(wrongCredit) / Double(n))
    }

    @Test func evidenceNeverBreaksInTurnShots() {
        #expect(synthSession(outOfTurnRate: 0.15).inTurn >= 0.99)
    }

    @Test func outOfTurnShotByConsentedPlayerIsCaughtMostOfTheTime() {
        // Prior 0.8 + decide-at 0.85 is deliberately conservative: a wrong auto pick is worse than turn order + tap.
        #expect(synthSession(outOfTurnRate: 0.3).outConsented >= 0.5)
    }

    @Test func syntheticSessionHitsNinetyPercentBeforeAnyTap() {
        // Phase 5 metric (research Q16 proposal): ≥90 % correct before any tap, with 10 % of shots out of order.
        // Out-of-turn shots by non-consented players are undetectable by design (Q8: no re-ID without consent).
        let r = synthSession(outOfTurnRate: 0.10)
        #expect(r.overall >= 0.9)
        // Not vacuous: identity evidence must beat "always the expected shooter" on the same shots.
        #expect(r.overall > r.turnOrderOnly + 0.02, "\(r)")
        #expect(r.wrongAuto == 0)
    }

    @Test func identityEvidenceBeatsTurnOrderAloneWhenPlayIsLoose() {
        let r = synthSession(outOfTurnRate: 0.3)
        #expect(r.overall >= r.turnOrderOnly + 0.08, "\(r)")
    }

    @Test func mixedConsentTableNeverAutoPicksWrongAndNeverLosesToTurnOrder() {
        // Non-consented C, D may look like anyone: out-of-turn catches are given up for safety, never a wrong auto.
        for rate in [0.0, 0.1, 0.3] {
            let r = synthSession(outOfTurnRate: rate, allConsented: false)
            #expect(r.wrongAuto == 0, "rate \(rate)")
            #expect(r.overall >= r.turnOrderOnly - 1e-9, "rate \(rate)")
        }
    }

    @Test func domainGapWeakGenuineMatchesAreNeverWorseThanTurnOrder() {
        // Front-enrolled vs rear-observed: genuine cosine ≈ 0.6, below threshold. Must degrade to turn order,
        // never to a confident pick of someone with no positive evidence.
        for rate in [0.0, 0.1, 0.3] {
            let r = synthSession(outOfTurnRate: rate, genuine: 0.6, allConsented: false)
            #expect(r.wrongAuto == 0, "rate \(rate)")
            // Weak evidence may ask (credit nobody) but never credits the wrong player more than turn order would.
            #expect(r.wrongCredited <= 1 - r.turnOrderOnly + 1e-9, "rate \(rate)")
        }
    }

    @Test func weakMatchForConsentedExpectedShooterNeverAutoPicksANonConsentedPlayer() {
        // Supervisor scenario: 1v1, A clothes-consented and expected, B not. cos 0.60 / 0.62 to A's seeds.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        for cos in [0.40, 0.60, 0.62, 0.70] {
            let out = attributor.attribute(views: [[person(1, pose: 0.9, dist: 0.05, clothes: [Synth.a: cos])]], context: ctx)
            #expect(out.playerID != Synth.b && out.source != .auto, "cos \(cos)")
        }
    }

    @Test func expectedShooterWithoutPositiveEvidenceIsTurnOrderNotAuto() {
        // C (no consent) expected; A and B consented and clearly not shooting → still C, but labelled turn order.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)), (Synth.c, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.c)
        let out = attributor.attribute(views: [[person(1, pose: 0.9, dist: 0.05, clothes: [Synth.a: 0.3, Synth.b: 0.3])]], context: ctx)
        #expect(out.playerID == Synth.c && out.source == .turnOrder)
    }

    @Test func autoAwayFromTurnOrderNeedsPositiveEvidenceForThatPlayer() {
        // 2v2-ish: A expected (consented, weak), B consented with no match either, C/D none → turn order.
        let r = roster([(Synth.a, .init(clothes: true, face: false)), (Synth.b, .init(clothes: true, face: false)),
                        (Synth.c, .none), (Synth.d, .none)])
        let ctx = AttributionContext(roster: r, expectedShooter: Synth.a)
        let out = attributor.attribute(views: [[person(1, pose: 0.9, dist: 0.05, clothes: [Synth.a: 0.5, Synth.b: 0.5])]], context: ctx)
        #expect(out.source != .auto && out.playerID != Synth.b)
    }
}

/// Deterministic RNG for synthetic sessions.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
