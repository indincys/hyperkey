import Foundation

struct ClipQueryTerm: Codable, Equatable, Sendable {
    var value: String
    var negated: Bool
    var phrase: Bool
}

struct ClipQuery: Equatable, Sendable {
    var textTerms: [ClipQueryTerm] = []
    var appTerms: [ClipQueryTerm] = []
    var kinds: Set<ClipKind> = []
    var excludedKinds: Set<ClipKind> = []
    var before: Date?
    var after: Date?
    var pinned: Bool?
    var queued: Bool?

    var highlightTerms: [String] {
        textTerms.filter { !$0.negated }.map(\.value)
    }

    var hasPositiveTextTerm: Bool { textTerms.contains { !$0.negated } }
}

struct ClipQueryParseError: Error, Equatable, LocalizedError, Sendable {
    var position: Int
    var message: String

    var errorDescription: String? { "位置 \(position + 1)：\(message)" }
}

enum ClipQueryParser {
    private struct Token {
        var value: String
        var negated: Bool
        var phrase: Bool
        var position: Int
    }

    static func parse(_ source: String) throws -> ClipQuery {
        var query = ClipQuery()
        for token in try tokenize(source) {
            // A complete URL contains a colon but is search text, not an unknown field.
            // Quoting and escaping are already resolved by the tokenizer at this point.
            if token.value.range(of: "://") != nil {
                let value = normalized(token.value)
                query.textTerms.append(ClipQueryTerm(
                    value: value, negated: token.negated, phrase: token.phrase
                ))
                continue
            }
            let split = token.value.firstIndex(of: ":")
            guard let split else {
                let value = normalized(token.value)
                guard !value.isEmpty else { continue }
                query.textTerms.append(ClipQueryTerm(
                    value: value, negated: token.negated, phrase: token.phrase
                ))
                continue
            }

            let field = token.value[..<split].lowercased()
            let rawValue = String(token.value[token.value.index(after: split)...])
            guard !rawValue.isEmpty else {
                throw issue(token, "筛选字段缺少值")
            }
            switch field {
            case "app":
                query.appTerms.append(ClipQueryTerm(
                    value: normalized(rawValue), negated: token.negated, phrase: token.phrase
                ))
            case "type":
                guard let kind = kind(from: rawValue) else {
                    throw issue(token, "未知类型“\(rawValue)”")
                }
                if token.negated { query.excludedKinds.insert(kind) }
                else {
                    if let existing = query.kinds.first, existing != kind {
                        throw issue(token, "type 只能指定一个互不冲突的类型")
                    }
                    query.kinds.insert(kind)
                }
            case "before":
                guard !token.negated else { throw issue(token, "日期筛选不支持否定") }
                let value = try date(from: rawValue, token: token, endOfDay: false)
                query.before = query.before.map { min($0, value) } ?? value
            case "after":
                guard !token.negated else { throw issue(token, "日期筛选不支持否定") }
                let value = try date(from: rawValue, token: token, endOfDay: false)
                query.after = query.after.map { max($0, value) } ?? value
            case "is":
                switch rawValue.lowercased() {
                case "pinned", "pin", "收藏":
                    let value = !token.negated
                    if let existing = query.pinned, existing != value {
                        throw issue(token, "is:pinned 条件相互矛盾")
                    }
                    query.pinned = value
                case "queued", "queue", "队列":
                    let value = !token.negated
                    if let existing = query.queued, existing != value {
                        throw issue(token, "is:queued 条件相互矛盾")
                    }
                    query.queued = value
                default: throw issue(token, "未知状态“\(rawValue)”")
                }
            default:
                throw issue(token, "未知筛选字段“\(field)”")
            }
        }
        if let after = query.after, let before = query.before, after >= before {
            throw ClipQueryParseError(position: 0, message: "after 必须早于 before")
        }
        if !query.kinds.isDisjoint(with: query.excludedKinds) {
            throw ClipQueryParseError(position: 0, message: "同一类型不能同时包含和排除")
        }
        return query
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        let characters = Array(source)
        var result: [Token] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            let start = index
            var negated = false
            if characters[index] == "-" {
                negated = true
                index += 1
                guard index < characters.count, !characters[index].isWhitespace else {
                    throw ClipQueryParseError(position: start, message: "否定符后缺少条件")
                }
            }

            var buffer = ""
            var phrase = false
            var quoted = false
            var escaped = false
            while index < characters.count {
                let character = characters[index]
                if escaped {
                    buffer.append(character)
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    escaped = true
                    index += 1
                    continue
                }
                if character == "\"" {
                    quoted.toggle()
                    phrase = true
                    index += 1
                    continue
                }
                if character.isWhitespace, !quoted { break }
                buffer.append(character)
                index += 1
            }
            if escaped {
                throw ClipQueryParseError(position: index - 1, message: "转义符后缺少字符")
            }
            if quoted {
                let quote = characters[start...].firstIndex(of: "\"") ?? start
                throw ClipQueryParseError(position: quote, message: "引号未闭合")
            }
            guard !buffer.isEmpty else {
                throw ClipQueryParseError(position: start, message: "空条件无效")
            }
            result.append(Token(
                value: buffer, negated: negated, phrase: phrase, position: start
            ))
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func kind(from raw: String) -> ClipKind? {
        let value = normalized(raw)
        return ClipKind.allCases.first { kind in
            value == kind.rawValue.lowercased() || value == kind.label.lowercased()
                || aliases[kind, default: []].contains(value)
        }
    }

    private static let aliases: [ClipKind: Set<String>] = [
        .text: ["plain", "plaintext", "文本"],
        .richText: ["rich", "rtf", "html", "富文本"],
        .url: ["link", "链接", "网址"],
        .image: ["photo", "picture", "图片", "图像"],
        .files: ["file", "folder", "文件", "文件夹"],
        .color: ["colour", "颜色"],
    ]

    private static func date(from raw: String, token: Token, endOfDay: Bool) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            throw issue(token, "日期必须是 YYYY-MM-DD 或 ISO-8601")
        }
        return endOfDay ? date.addingTimeInterval(86_400) : date
    }

    private static func issue(_ token: Token, _ message: String) -> ClipQueryParseError {
        ClipQueryParseError(position: token.position, message: message)
    }
}
