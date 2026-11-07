import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

@Suite struct LobbyWireTests {
    let sam = ShellPlayer(id: UUID(), name: "Sam", symbol: "bolt.fill", colorName: "orange")

    @Test func advertRoundTripsThroughDiscoveryInfo() {
        let g = NearbyGame(id: "ab12", host: sam, ruleSet: .wpaNine, seatsFilled: 3, seatsTotal: 4)
        let info = LobbyWire.discoveryInfo(g)
        #expect(LobbyWire.game(from: info, peerKey: "x") == g)
        // MPC limits discovery info to ~400 bytes.
        #expect(info.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } < 300)
    }

    @Test func advertWithoutHostDecodes() {
        let g = NearbyGame(id: "ab12", host: nil, ruleSet: .barEight, seatsFilled: 0, seatsTotal: 2)
        #expect(LobbyWire.game(from: LobbyWire.discoveryInfo(g), peerKey: "x")?.host == nil)
    }

    @Test func foreignOrOldAdvertIsIgnored() {
        #expect(LobbyWire.game(from: ["v": "0"], peerKey: "x") == nil)
        #expect(LobbyWire.game(from: nil, peerKey: "x") == nil)
    }

    @Test func hostileAdvertCountsAreClamped() {
        let info = ["v": "1", "g": "x", "r": "barEight", "f": "999999", "t": "1000000"]
        let g = LobbyWire.game(from: info, peerKey: "p")
        #expect(g?.seatsTotal == 8)
        #expect(g?.seatsFilled == 8)
        #expect(LobbyWire.game(from: ["v": "1", "g": "x", "r": "barEight", "f": "-3", "t": "-1"], peerKey: "p")?.seatsTotal == 2)
    }

    @Test func oversizedOrMalformedLineupsAreRejected() {
        let five = Array(repeating: Optional(sam), count: 5)
        #expect(!LobbyWire.isAcceptable(.lineup(LobbyLineup(ruleSet: .barEight, tableSize: .sevenFoot, seats: [five, five]))))
        #expect(!LobbyWire.isAcceptable(.lineup(LobbyLineup(ruleSet: .barEight, tableSize: .sevenFoot, seats: [[sam], [sam], [sam]]))))
        let long = ShellPlayer(id: UUID(), name: String(repeating: "x", count: 200), symbol: "s", colorName: "c")
        #expect(!LobbyWire.isAcceptable(.start(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[long], [sam]]), sessionTag: 1)))
        let kim2 = ShellPlayer(id: UUID(), name: "Kim", symbol: "s", colorName: "c")
        #expect(LobbyWire.isAcceptable(.start(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[sam], [kim2]]), sessionTag: 1)))
        #expect(!LobbyWire.isAcceptable(.start(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[sam], [kim2]]), sessionTag: 0)))
        #expect(LobbyWire.isAcceptable(.hello(name: "Kim")))
        #expect(!LobbyWire.isAcceptable(.phones(Array(repeating: NearbyPhone(id: "p", name: nil), count: 20))))
    }

    @Test func startsMustHaveEqualTeamsAndUniquePlayers() {
        let kim = ShellPlayer(id: UUID(), name: "Kim", symbol: "s", colorName: "c")
        let bo = ShellPlayer(id: UUID(), name: "Bo", symbol: "s", colorName: "c")
        #expect(!LobbyWire.isAcceptable(.start(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[sam, kim], [bo]]), sessionTag: 1)))
        #expect(!LobbyWire.isAcceptable(.start(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[sam], [sam]]), sessionTag: 1)))
        #expect(LobbyWire.isAcceptable(.start(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[sam], [kim]]), sessionTag: 1)))
        #expect(!LobbyWire.isAcceptable(.lineup(LobbyLineup(ruleSet: .barEight, tableSize: .sevenFoot, seats: [[sam, nil], [nil]]))))
        #expect(!LobbyWire.isAcceptable(.lineup(LobbyLineup(ruleSet: .barEight, tableSize: .sevenFoot, seats: [[sam], [sam]]))))
        #expect(LobbyWire.isAcceptable(.lineup(LobbyLineup(ruleSet: .barEight, tableSize: .sevenFoot, seats: [[sam, nil], [nil, kim]]))))
    }

    @Test func bigPayloadsAreDroppedBeforeDecoding() {
        #expect((try? LobbyWire.decode(Data(repeating: 0x20, count: LobbyWire.maxMessageBytes + 1))) == nil)
    }

    @Test func messagesRoundTrip() throws {
        let cfg = GameConfig(ruleSet: .wpaEight, tableSize: .eightFoot, teams: [[sam], [sam]])
        let lineup = LobbyLineup(ruleSet: .wpaNine, tableSize: .nineFoot, seats: [[sam, nil], [nil, sam]])
        for msg: LobbyWire.Message in [.hello(name: "Kim"), .welcome, .full, .lineup(lineup),
                                        .start(cfg, sessionTag: 77), .phones([NearbyPhone(id: "p", name: "Kim")])] {
            #expect(try LobbyWire.decode(LobbyWire.encode(msg)) == msg)
        }
    }

    @Test func garbageDoesNotDecode() {
        #expect((try? LobbyWire.decode(Data("nope".utf8))) == nil)
    }

    @Test func sessionTagIsNeverTheDefaultZero() {
        for _ in 0..<50 { #expect(LobbyWire.randomSessionTag() != 0) }
    }
}
