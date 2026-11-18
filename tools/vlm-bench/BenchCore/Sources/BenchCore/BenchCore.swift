import Foundation

// MARK: - Test set

public enum QuestionKind: String, Codable, Sendable, CaseIterable {
    case ballsOnTable, cueInKitchen, pocketDrop, shotLabel
}

public enum Pocket: String, Codable, Sendable, CaseIterable {
    case headLeft, headRight, sideLeft, sideRight, footLeft, footRight
}

public struct Truth: Codable, Sendable, Equatable {
    public var balls: [Int]?
    public var cueBallPresent: Bool?
    public var inKitchen: Bool?
    public var pocket: Pocket?
    public var keywords: [String]?
    public var ratingClass: String?

    public init(balls: [Int]? = nil, cueBallPresent: Bool? = nil, inKitchen: Bool? = nil, pocket: Pocket? = nil,
                keywords: [String]? = nil, ratingClass: String? = nil) {
        self.balls = balls; self.cueBallPresent = cueBallPresent; self.inKitchen = inKitchen
        self.pocket = pocket; self.keywords = keywords; self.ratingClass = ratingClass
    }
}

public struct Question: Codable, Sendable {
    public var id: String
    public var kind: QuestionKind
    public var images: [String]
    public var ball: Int?
    public var description: String?
    public var truth: Truth

    public init(id: String, kind: QuestionKind, images: [String], ball: Int?, description: String?, truth: Truth) {
        self.id = id; self.kind = kind; self.images = images; self.ball = ball
        self.description = description; self.truth = truth
    }
}

public struct TestSet: Decodable, Sendable {
    public var version: Int
    public var questions: [Question]

    public static func decode(_ data: Data) throws -> TestSet {
        try JSONDecoder().decode(TestSet.self, from: data)
    }
}

// MARK: - Answers

/// One model answer, already validated against the question's schema.
public struct Answer: Codable, Sendable, Equatable {
    public var balls: [Int]?
    public var cueBallPresent: Bool?
    public var inKitchen: Bool?
    public var pocket: Pocket?
    public var label: String?

    public init(balls: [Int]? = nil, cueBallPresent: Bool? = nil, inKitchen: Bool? = nil, pocket: Pocket? = nil,
                label: String? = nil) {
        self.balls = balls; self.cueBallPresent = cueBallPresent; self.inKitchen = inKitchen
        self.pocket = pocket; self.label = label
    }
}

// MARK: - JSON extraction (for free-text VLMs)

public enum JSONExtractor {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The last balanced top-level `{...}` object outside any `<think>` block that parses as JSON.
    public static func object(in text: String) throws -> [String: Any] {
        var t = text
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
            }
        }
        let chars = Array(t)
        var candidates: [String] = []
        var depth = 0, start = -1, inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": if depth > 0 { inString = true }
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, start >= 0 { candidates.append(String(chars[start...i])) }
                }
            default: break
            }
        }
        for c in candidates {
            if let obj = try? JSONSerialization.jsonObject(with: Data(c.utf8)) as? [String: Any] { return obj }
        }
        throw Failure(description: "no JSON object in output")
    }
}

public enum AnswerParser {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ kind: QuestionKind, text: String) throws -> Answer {
        let obj: [String: Any]
        do { obj = try JSONExtractor.object(in: text) } catch { throw Failure(description: "\(error)") }
        return try validate(kind, obj)
    }

    public static func validate(_ kind: QuestionKind, _ obj: [String: Any]) throws -> Answer {
        func bool(_ key: String) throws -> Bool {
            guard let n = obj[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw Failure(description: "\(key) must be a boolean")
            }
            return n.boolValue
        }
        switch kind {
        case .ballsOnTable:
            guard let raw = obj["balls"] as? [Any] else { throw Failure(description: "balls must be an array") }
            let balls = try raw.map { v -> Int in
                guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue == n.doubleValue.rounded(), (1...15).contains(n.intValue)
                else { throw Failure(description: "balls must be integers 1-15") }
                return n.intValue
            }
            return Answer(balls: balls, cueBallPresent: try bool("cueBallPresent"))
        case .cueInKitchen:
            return Answer(inKitchen: try bool("inKitchen"))
        case .pocketDrop:
            guard let s = obj["pocket"] as? String, let p = Pocket(rawValue: s) else {
                throw Failure(description: "pocket must be one of \(Pocket.allCases.map(\.rawValue))")
            }
            return Answer(pocket: p)
        case .shotLabel:
            guard let s = obj["label"] as? String else { throw Failure(description: "label must be a string") }
            return Answer(label: s)
        }
    }
}

// MARK: - Scoring

public struct Score: Codable, Sendable {
    public var correct: Bool
    /// 0...1 partial credit (Jaccard for ball sets, else 0/1).
    public var partial: Double
    /// For labels: ≤2 words and no digits (spec §5.9 / UI rule). True for other kinds when an answer exists.
    public var formatValid: Bool
}

public enum Scorer {
    public static func labelFormatValid(_ label: String) -> Bool {
        let words = label.split(whereSeparator: { $0.isWhitespace }).filter { !$0.isEmpty }
        return (1...2).contains(words.count) && !label.contains(where: \.isNumber)
    }

    public static func score(_ q: Question, _ a: Answer?) -> Score {
        guard let a else { return Score(correct: false, partial: 0, formatValid: false) }
        switch q.kind {
        case .ballsOnTable:
            let truth = Set(q.truth.balls ?? []), got = Set(a.balls ?? [])
            let union = truth.union(got).count
            let j = union == 0 ? 1 : Double(truth.intersection(got).count) / Double(union)
            let ok = truth == got && (a.balls?.count ?? 0) == got.count && a.cueBallPresent == q.truth.cueBallPresent
            return Score(correct: ok, partial: j, formatValid: true)
        case .cueInKitchen:
            let ok = a.inKitchen == q.truth.inKitchen
            return Score(correct: ok, partial: ok ? 1 : 0, formatValid: true)
        case .pocketDrop:
            let ok = a.pocket == q.truth.pocket
            return Score(correct: ok, partial: ok ? 1 : 0, formatValid: true)
        case .shotLabel:
            let label = a.label ?? ""
            let valid = labelFormatValid(label)
            let lower = label.lowercased()
            let onTopic = (q.truth.keywords ?? []).contains { lower.contains($0.lowercased()) }
            let ok = valid && onTopic
            return Score(correct: ok, partial: ok ? 1 : 0, formatValid: valid)
        }
    }
}

// MARK: - Prompts (shared by every model so the comparison is fair)

public enum Prompts {
    public static let system = """
    You analyse still images of a pool (pocket billiards) table for a coaching app. \
    The camera is at the HEAD end of the table: the head rail is at the bottom of the image, the foot rail at the top. \
    The KITCHEN is the area between the head rail and the head string (the thin line across the table a quarter of the way up from the head rail). \
    Object balls are numbered 1-15: 1-8 solid colours (8 is black), 9-15 white with a coloured stripe. The cue ball is plain white. \
    Pockets: headLeft, headRight (bottom corners), sideLeft, sideRight (middle of the long rails), footLeft, footRight (top corners); left/right as seen in the image. \
    Answer only what is asked.
    """

    public static func question(_ q: Question) -> String {
        switch q.kind {
        case .ballsOnTable:
            return "List the numbers of every object ball on the table, and say whether the white cue ball is on the table."
        case .cueInKitchen:
            return "Is the cue ball in the kitchen (between the head rail at the bottom and the head string line)?"
        case .pocketDrop:
            let n = q.ball.map(String.init) ?? "?"
            return "The image shows BEFORE (left) and AFTER (right) frames of one shot. In the AFTER frame the \(n)-ball is dropping into a pocket. Which pocket?"
        case .shotLabel:
            return "Shot: \(q.description ?? ""). Give this shot a punchy label of at most two words, no numbers, for a highlight card."
        }
    }

    public static func jsonSchemaHint(_ kind: QuestionKind) -> String {
        switch kind {
        case .ballsOnTable: return #"Reply with JSON only: {"balls": [int 1-15, ...], "cueBallPresent": true|false}"#
        case .cueInKitchen: return #"Reply with JSON only: {"inKitchen": true|false}"#
        case .pocketDrop:
            return #"Reply with JSON only: {"pocket": one of "headLeft","headRight","sideLeft","sideRight","footLeft","footRight"}"#
        case .shotLabel: return #"Reply with JSON only: {"label": "one or two words"}"#
        }
    }
}

// MARK: - Stats

public enum Stats {
    public static func median(_ xs: [Double]) -> Double? { percentile(xs, 0.5) }

    /// Linear-interpolated percentile (numpy default).
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let pos = p * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        let v = s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
        return (v * 1e9).rounded() / 1e9
    }
}
