import Foundation

/// Counters for the dev autorecord path. Cheap enough to leave in.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var notes: [String] = []

    func bump(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func note(_ text: String) { lock.withLock { notes.append(text) } }

    func dump() -> String {
        lock.withLock {
            let c = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "counts[\(c)] notes[\(notes.joined(separator: "; "))]"
        }
    }
}
