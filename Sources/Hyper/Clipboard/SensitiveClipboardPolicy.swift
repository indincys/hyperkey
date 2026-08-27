import Foundation

/// Value-semantic Codable compatibility for a Boolean introduced after existing
/// clipboard indexes had already shipped. It encodes as a plain JSON boolean and treats
/// both a missing legacy key and an explicit null as false.
@propertyWrapper
struct DefaultFalse: Codable, Equatable {
    var wrappedValue: Bool

    init(wrappedValue: Bool = false) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = (try? container.decode(Bool.self)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: DefaultFalse.Type, forKey key: Key) throws -> DefaultFalse {
        try decodeIfPresent(type, forKey: key) ?? DefaultFalse()
    }
}

/// A high-confidence explanation for why a clipboard entry deserves shorter retention.
/// Raw values are persisted in the encrypted clipboard index; keep them stable.
enum ClipSensitivity: String, Codable, CaseIterable, Equatable {
    case concealed
    case transient
    case oneTimeCode
    case password
    case privateKey

    var label: String {
        switch self {
        case .concealed: return "系统标记的机密内容"
        case .transient: return "系统标记的临时内容"
        case .oneTimeCode: return "一次性验证码"
        case .password: return "疑似密码（仅标记）"
        case .privateKey: return "私钥"
        }
    }

    var explanation: String {
        switch self {
        case .concealed:
            return "来源应用通过 macOS 剪贴板类型明确要求隐藏。"
        case .transient:
            return "来源应用声明这份内容只应短暂存在。"
        case .oneTimeCode:
            return "内容包含验证码语义和 4–8 位数字。"
        case .password:
            return "内容像无空格的高熵密码；启发式无法证明其一定是秘密，因此绝不自动跳过或删除。"
        case .privateKey:
            return "内容包含标准 PEM/OpenSSH 私钥边界。"
        }
    }
}

/// What Hyper does after a high-confidence sensitive classification.
enum SensitiveClipboardHandling: String, Codable, CaseIterable, Equatable {
    case skip
    case expire
    case oneTime

    var label: String {
        switch self {
        case .skip: return "不保存"
        case .expire: return "限时保存"
        case .oneTime: return "粘贴成功后删除"
        }
    }

    var explanation: String {
        switch self {
        case .skip:
            return "系统机密/临时标记、严格验证码和标准私钥不会进入历史；疑似密码只标记。"
        case .expire:
            return "可证明的敏感内容到期后永久删除，即使已经收藏；疑似密码只标记。"
        case .oneTime:
            return "可证明的敏感内容仅在完整粘贴事务成功后永久删除；失败时保留，并以到期时间兜底。疑似密码只标记。"
        }
    }
}

enum ClipboardPauseReason: Equatable {
    case manualPrivacyPause

    var label: String {
        switch self {
        case .manualPrivacyPause: return "手动隐私暂停"
        }
    }
}

struct ClipboardPauseState: Equatable {
    let reason: ClipboardPauseReason
    let resumesAt: Date
}

enum SensitiveRetentionDecision: Equatable {
    case skip
    case retain(sensitivity: ClipSensitivity, expiry: Date?, oneTime: Bool)
}

/// Pure, deterministic risk classification and retention decisions. It never logs or
/// stores the clipboard body, which keeps explanations testable without widening the
/// plaintext lifetime.
enum SensitiveClipboardPolicy {
    private static let otpKeywordExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:\botp\b|\bone[- ]time(?: password| code)\b|\b(?:verification|security|login|authentication|auth) code\b|验证码|校验码|动态码|安全码|登录码)(?:\s+(?:is|为|是))?\s*[:：=\-]?\s*"#
    )

    private static let otpDigitsExpression = try! NSRegularExpression(
        pattern: #"^([0-9](?:[ -]?[0-9]){3,7})(?![ -]?[0-9])(?:\b|$)"#
    )

    private static let hostOrHostPathExpression = try! NSRegularExpression(
        pattern: #"(?i)^(?:[a-z0-9-]+\.)+[a-z]{2,63}(?::[0-9]+)?(?:[/?:#][^\s]*)?$"#
    )

    private static let assignmentExpression = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_.-]{0,63}\s*[:=]\s*\S+$"#
    )

    private static let privateKeyHeaders = [
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN PGP PRIVATE KEY BLOCK-----",
    ]

    static func classify(offeredTypes: Set<String>, text: String?) -> ClipSensitivity? {
        if !offeredTypes.isDisjoint(with: ClipCapture.concealedTypes) { return .concealed }
        if !offeredTypes.isDisjoint(with: ClipCapture.transientTypes) { return .transient }
        guard let text else { return nil }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        let uppercase = candidate.uppercased()
        if privateKeyHeaders.contains(where: uppercase.contains) { return .privateKey }

        if isStrictOneTimeCode(candidate) {
            return .oneTimeCode
        }

        if looksLikeStructuredNonSecret(candidate) { return nil }

        // Deliberately high precision: ordinary tokens, UUIDs, prose and numeric values
        // must not silently acquire a destructive retention rule.
        if candidate.count >= 8, candidate.count <= 128,
           candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            let hasLower = candidate.rangeOfCharacter(from: .lowercaseLetters) != nil
            let hasUpper = candidate.rangeOfCharacter(from: .uppercaseLetters) != nil
            let hasDigit = candidate.rangeOfCharacter(from: .decimalDigits) != nil
            let symbolSet = CharacterSet.alphanumerics.inverted
                .subtracting(.whitespacesAndNewlines)
            let hasSymbol = candidate.rangeOfCharacter(from: symbolSet) != nil
            if hasLower, hasUpper, hasDigit, hasSymbol { return .password }
        }
        return nil
    }

    private static func isStrictOneTimeCode(_ candidate: String) -> Bool {
        let fullRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        for keyword in otpKeywordExpression.matches(in: candidate, range: fullRange) {
            guard let suffixStart = Range(keyword.range, in: candidate)?.upperBound else {
                continue
            }
            let suffix = String(candidate[suffixStart...])
            let suffixRange = NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
            if otpDigitsExpression.firstMatch(in: suffix, range: suffixRange) != nil {
                return true
            }
        }
        return false
    }

    private static func looksLikeStructuredNonSecret(_ candidate: String) -> Bool {
        let fullRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        if let url = URL(string: candidate),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ftp", "file", "ssh"].contains(scheme) {
            return true
        }
        if hostOrHostPathExpression.firstMatch(in: candidate, range: fullRange) != nil {
            return true
        }
        if assignmentExpression.firstMatch(in: candidate, range: fullRange) != nil {
            return true
        }

        let lower = candidate.lowercased()
        if lower.hasPrefix("/") || lower.hasPrefix("~/") || lower.hasPrefix("./")
            || lower.hasPrefix("../") {
            return true
        }
        if candidate.count >= 3 {
            let characters = Array(candidate.prefix(3))
            if characters[0].isLetter, characters[1] == ":",
               characters[2] == "\\" || characters[2] == "/" {
                return true
            }
        }
        if ["version", "build", "release"].contains(where: lower.contains),
           candidate.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }
        let commandPrefixes = [
            "$ ", "sudo ", "git ", "swift ", "npm ", "pnpm ", "yarn ", "cargo ",
            "python ", "python3 ", "ruby ", "make ", "xcodebuild ",
        ]
        return commandPrefixes.contains(where: lower.hasPrefix)
    }

    static func decision(
        for sensitivity: ClipSensitivity?, handling: SensitiveClipboardHandling,
        ttlMinutes: Int, now: Date
    ) -> SensitiveRetentionDecision? {
        guard let sensitivity else { return nil }
        // Password shape alone is not proof. Preserve the useful warning label while
        // making every destructive policy inapplicable to heuristic-only matches.
        if sensitivity == .password {
            return .retain(sensitivity: sensitivity, expiry: nil, oneTime: false)
        }
        switch handling {
        case .skip:
            return .skip
        case .expire, .oneTime:
            let boundedMinutes = min(max(ttlMinutes, 1), 24 * 60)
            return .retain(
                sensitivity: sensitivity,
                expiry: now.addingTimeInterval(TimeInterval(boundedMinutes * 60)),
                oneTime: handling == .oneTime
            )
        }
    }
}
