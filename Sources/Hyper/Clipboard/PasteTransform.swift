import Foundation

/// The rewrites offered by 「粘贴为…」.
///
/// Deliberately nothing but `String -> String`: no pasteboard, no record, no view. That
/// keeps the menu a list rather than a switch, and it means each rule can be exercised on
/// its own without a running panel behind it.
enum PasteTransform: String, CaseIterable, Identifiable {
    case uppercase
    case lowercase
    case titleCase
    case trimmed
    case collapseBlankLines
    case singleLine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uppercase: return "大写"
        case .lowercase: return "小写"
        case .titleCase: return "首字母大写"
        case .trimmed: return "去首尾空白"
        case .collapseBlankLines: return "合并多个空行"
        case .singleLine: return "压成单行"
        }
    }

    func apply(to text: String) -> String {
        switch self {
        case .uppercase:
            return text.localizedUppercase
        case .lowercase:
            return text.localizedLowercase
        case .titleCase:
            // Localized, so that a Turkish "i" and the like survive. It lowercases the
            // rest of each word, which is what Title Case means — an entry full of
            // acronyms is exactly the one nobody reaches for this on.
            return text.localizedCapitalized
        case .trimmed:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseBlankLines:
            // Two or more line breaks — with only blanks between them, which is what a
            // "blank" line really is — become one blank line. A single break is left
            // alone, so paragraphs keep their shape.
            return text.replacingOccurrences(
                of: "(\\r\\n|\\r|\\n)[ \\t]*((\\r\\n|\\r|\\n)[ \\t]*)+",
                with: "\n\n",
                options: .regularExpression
            )
        case .singleLine:
            return text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
