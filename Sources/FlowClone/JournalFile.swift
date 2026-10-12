import FlowCore
import Foundation

/// The opt-in dictation journal on disk: one `JournalRecord` per line in
/// Application Support. Local only: nothing here talks to the network.
/// Callers check the "Keep dictation journal" setting before appending.
enum JournalFile {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FlowClone/journal.jsonl")
    }

    /// Appends off the main thread, in order.
    private static let queue = DispatchQueue(label: "FlowClone.journal")

    static func append(_ record: JournalRecord) {
        queue.async {
            do {
                let line = Data((try record.jsonLine() + "\n").utf8)
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Only the user can read what they dictated.
                    fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                log.error("journal append failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the file, after any pending appends.
    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }
}
