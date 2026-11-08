import Foundation
import Testing
@testable import BenchCore

@Suite struct TestSetDecoding {
    @Test func decodesAllQuestionKinds() throws {
        let json = """
        {"version":1,"scenes":[],"questions":[
          {"id":"b","kind":"ballsOnTable","images":["a.png"],"truth":{"balls":[3,1],"cueBallPresent":true}},
          {"id":"k","kind":"cueInKitchen","images":["a.png"],"truth":{"inKitchen":false}},
          {"id":"p","kind":"pocketDrop","images":["p.png"],"ball":7,"truth":{"pocket":"sideLeft"}},
          {"id":"l","kind":"shotLabel","images":["a.png"],"description":"bank","truth":{"keywords":["bank"],"ratingClass":"Great"}}
        ]}
        """
        let set = try TestSet.decode(Data(json.utf8))
        #expect(set.questions.count == 4)
        #expect(set.questions[0].kind == .ballsOnTable)
        #expect(set.questions[0].truth.balls == [3, 1])
        #expect(set.questions[2].ball == 7)
        #expect(set.questions[2].truth.pocket == .sideLeft)
        #expect(set.questions[3].truth.keywords == ["bank"])
    }
}

@Suite struct JSONExtraction {
    @Test func plainObject() throws {
        let obj = try JSONExtractor.object(in: #"{"inKitchen": true}"#)
        #expect(obj["inKitchen"] as? Bool == true)
    }

    @Test func fencedAndChatty() throws {
        let text = "Sure! Here you go:\n```json\n{\"pocket\": \"footLeft\"}\n```\nHope that helps."
        let obj = try JSONExtractor.object(in: text)
        #expect(obj["pocket"] as? String == "footLeft")
    }

    @Test func skipsThinkingBlock() throws {
        let text = "<think>maybe {\"pocket\": \"headLeft\"}</think>\n{\"pocket\": \"sideRight\"}"
        let obj = try JSONExtractor.object(in: text)
        #expect(obj["pocket"] as? String == "sideRight")
    }

    @Test func nestedBracesInsideStrings() throws {
        let obj = try JSONExtractor.object(in: #"x {"label": "a}b", "n": {"k": 1}} y"#)
        #expect(obj["label"] as? String == "a}b")
    }

    @Test func noObjectThrows() {
        #expect(throws: JSONExtractor.Failure.self) { try JSONExtractor.object(in: "no json here") }
    }
}

@Suite struct AnswerParsing {
    @Test func ballsValidated() throws {
        let a = try AnswerParser.parse(.ballsOnTable, text: #"{"balls":[1,15,8],"cueBallPresent":true}"#)
        #expect(a.balls == [1, 15, 8])
        #expect(a.cueBallPresent == true)
    }

    @Test func ballsRejectWrongType() {
        #expect(throws: AnswerParser.Failure.self) {
            try AnswerParser.parse(.ballsOnTable, text: #"{"balls":"1,2","cueBallPresent":true}"#)
        }
    }

    @Test func ballsRejectOutOfRange() {
        #expect(throws: AnswerParser.Failure.self) {
            try AnswerParser.parse(.ballsOnTable, text: #"{"balls":[0,16],"cueBallPresent":true}"#)
        }
    }

    @Test func pocketMustBeEnumCase() throws {
        #expect(try AnswerParser.parse(.pocketDrop, text: #"{"pocket":"footRight"}"#).pocket == .footRight)
        #expect(throws: AnswerParser.Failure.self) {
            try AnswerParser.parse(.pocketDrop, text: #"{"pocket":"top left"}"#)
        }
    }

    @Test func kitchenAndLabel() throws {
        #expect(try AnswerParser.parse(.cueInKitchen, text: #"{"inKitchen":false}"#).inKitchen == false)
        #expect(try AnswerParser.parse(.shotLabel, text: #"{"label":"Bank Wizard"}"#).label == "Bank Wizard")
    }
}

@Suite struct Scoring {
    func q(_ kind: QuestionKind, _ truth: Truth) -> Question {
        Question(id: "q", kind: kind, images: [], ball: nil, description: nil, truth: truth)
    }

    @Test func ballsExactIsCorrectAndPartialIsJaccard() {
        let question = q(.ballsOnTable, Truth(balls: [1, 2, 3, 4], cueBallPresent: true))
        let exact = Scorer.score(question, Answer(balls: [4, 3, 2, 1], cueBallPresent: true))
        #expect(exact.correct)
        #expect(exact.partial == 1)
        let half = Scorer.score(question, Answer(balls: [1, 2, 9], cueBallPresent: true))
        #expect(!half.correct)
        #expect(abs(half.partial - 2.0 / 5.0) < 1e-9)
        let noCue = Scorer.score(question, Answer(balls: [1, 2, 3, 4], cueBallPresent: false))
        #expect(!noCue.correct)
    }

    @Test func boolAndPocket() {
        #expect(Scorer.score(q(.cueInKitchen, Truth(inKitchen: true)), Answer(inKitchen: true)).correct)
        #expect(!Scorer.score(q(.cueInKitchen, Truth(inKitchen: true)), Answer(inKitchen: false)).correct)
        #expect(Scorer.score(q(.pocketDrop, Truth(pocket: .sideLeft)), Answer(pocket: .sideLeft)).correct)
        #expect(!Scorer.score(q(.pocketDrop, Truth(pocket: .sideLeft)), Answer(pocket: .sideRight)).correct)
    }

    @Test func labelRules() {
        let question = q(.shotLabel, Truth(keywords: ["bank", "brilliant"]))
        #expect(Scorer.score(question, Answer(label: "Bank Wizard")).correct)
        #expect(Scorer.score(question, Answer(label: "brilliant!")).correct)
        // > 2 words fails the spec even if on-topic
        #expect(!Scorer.score(question, Answer(label: "Great bank shot")).correct)
        // digits are numeric advice -> fail
        #expect(!Scorer.score(question, Answer(label: "Bank 9")).correct)
        // valid format but off-topic: format ok, not correct
        let off = Scorer.score(question, Answer(label: "Nice"))
        #expect(!off.correct)
        #expect(off.formatValid)
    }

    @Test func missingAnswerScoresZero() {
        let s = Scorer.score(q(.cueInKitchen, Truth(inKitchen: true)), nil)
        #expect(!s.correct)
        #expect(s.partial == 0)
    }
}

@Suite struct Prompting {
    @Test func everyKindHasPromptAndSchemaHint() {
        let truth = Truth()
        for kind in QuestionKind.allCases {
            let question = Question(id: "x", kind: kind, images: [], ball: 5, description: "A bank shot.", truth: truth)
            let p = Prompts.question(question)
            #expect(!p.isEmpty)
            #expect(Prompts.jsonSchemaHint(kind).contains("{"))
        }
        let pd = Prompts.question(Question(id: "x", kind: .pocketDrop, images: [], ball: 5, description: nil, truth: truth))
        #expect(pd.contains("5-ball"))
        let lb = Prompts.question(Question(id: "x", kind: .shotLabel, images: [], ball: nil, description: "A bank shot.", truth: truth))
        #expect(lb.contains("A bank shot."))
    }
}

@Suite struct Summaries {
    @Test func percentiles() {
        #expect(Stats.median([3, 1, 2]) == 2)
        #expect(Stats.median([1, 2, 3, 4]) == 2.5)
        #expect(Stats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9) == 9.1)
        #expect(Stats.median([]) == nil)
    }
}

@Suite struct RealTestSet {
    @Test func generatedTestSetDecodesAndIsBalanced() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CueVLMBench/TestSet/testset.json")
        let set = try TestSet.decode(Data(contentsOf: url))
        let kinds = Dictionary(grouping: set.questions, by: \.kind).mapValues(\.count)
        #expect(kinds[.ballsOnTable] == 20)
        #expect(kinds[.cueInKitchen] == 20)
        #expect(kinds[.pocketDrop] == 8)
        #expect(kinds[.shotLabel] == 6)
        // every label keyword must itself be a valid label fragment (no digits)
        for q in set.questions where q.kind == .shotLabel {
            #expect(q.truth.keywords?.allSatisfy { !$0.contains(where: \.isNumber) } == true)
        }
    }
}
