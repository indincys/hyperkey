import Foundation

struct SmartFilter: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var query: String
    var createdAt: Date
    var updatedAt: Date
}

struct SmartFilterStore: Equatable, Sendable {
    static let currentVersion = 2

    private struct Envelope: Codable {
        var version: Int
        var filters: [SmartFilter]
    }

    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidName
        case invalidQuery(String)
        case duplicateName
    }

    private(set) var filters: [SmartFilter]
    static let empty = SmartFilterStore(filters: [])

    @discardableResult
    mutating func save(
        name: String, query: String, id: UUID = UUID(), now: Date = Date()
    ) -> SmartFilter {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = filters.firstIndex { $0.id == id }
        let createdAt = existing.map { filters[$0].createdAt } ?? now
        let filter = SmartFilter(
            id: id, name: cleanName, query: cleanQuery,
            createdAt: createdAt, updatedAt: now
        )
        if let existing { filters[existing] = filter } else { filters.append(filter) }
        return filter
    }

    mutating func remove(_ id: UUID) { filters.removeAll { $0.id == id } }

    func validated() throws -> SmartFilterStore {
        var names = Set<String>()
        for filter in filters {
            let name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else { throw Failure.invalidName }
            let folded = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            guard names.insert(folded).inserted else { throw Failure.duplicateName }
            do { _ = try ClipQueryParser.parse(filter.query) }
            catch { throw Failure.invalidQuery(error.localizedDescription) }
        }
        return self
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(version: Self.currentVersion, filters: filters))
    }

    static func decode(_ data: Data) throws -> SmartFilterStore {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == currentVersion else {
            throw Failure.unsupportedVersion(envelope.version)
        }
        return try SmartFilterStore(filters: envelope.filters).validated()
    }
}
