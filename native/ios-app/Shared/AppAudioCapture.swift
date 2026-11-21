import Foundation

enum AppAudioCapture {
    static let sampleRate = 16_000
    static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size
    static let seconds = 60

    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PokiAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("AppAudioCapture", isDirectory: true)
    }

    struct Clip {
        let id: UUID
        let pcm: Data
    }

    private struct Chunk: Codable {
        let id: UUID
        let sequence: Int
        let end: Date
        let pcm: Data
    }

    private static func marker(in directory: URL) -> URL { directory.appendingPathComponent("broadcast") }

    private static func writeMarker(_ id: UUID, in directory: URL) throws {
        try Data(id.uuidString.utf8).write(to: marker(in: directory), options: [.atomic, .completeFileProtection])
    }

    private static func slot(_ sequence: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("audio-\(sequence % seconds)")
    }

    static func currentBroadcast(in directory: URL) -> UUID? {
        let file = marker(in: directory)
        guard let updated = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              abs(updated.timeIntervalSinceNow) < 5,
              let value = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    static func recentClip(in directory: URL, now: Date = Date()) -> Clip? {
        guard let id = currentBroadcast(in: directory) else { return nil }
        let decoder = PropertyListDecoder()
        let chunks = (0..<seconds).compactMap { index -> Chunk? in
            guard let data = try? Data(contentsOf: slot(index, in: directory)), data.count <= bytesPerSecond + 512,
                  let chunk = try? decoder.decode(Chunk.self, from: data),
                  chunk.id == id, chunk.pcm.count == bytesPerSecond, chunk.sequence >= 0,
                  now.timeIntervalSince(chunk.end) >= 0, now.timeIntervalSince(chunk.end) < Double(seconds)
            else { return nil }
            return chunk
        }.sorted { $0.sequence < $1.sequence }
        guard let newest = chunks.last, now.timeIntervalSince(newest.end) < 5,
              currentBroadcast(in: directory) == id else { return nil }
        return Clip(id: id, pcm: chunks.reduce(into: Data()) { $0.append($1.pcm) })
    }

    struct Writer {
        private let directory: URL
        private let id = UUID()
        private var sequence = 0
        private var pending = Data()

        init(directory: URL) throws {
            self.directory = directory
            try Self.clear(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            try AppAudioCapture.writeMarker(id, in: directory)
        }

        mutating func append(_ pcm: Data, now: Date = Date()) throws {
            pending.append(pcm)
            while pending.count >= bytesPerSecond {
                let chunk = Chunk(id: id, sequence: sequence, end: now, pcm: Data(pending.prefix(bytesPerSecond)))
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(chunk).write(to: AppAudioCapture.slot(sequence, in: directory), options: [.atomic, .completeFileProtection])
                try AppAudioCapture.writeMarker(id, in: directory)
                sequence += 1
                pending.removeFirst(bytesPerSecond)
            }
        }

        func stop() throws {
            // Invalidate readers before removing the slots.
            try FileManager.default.removeItem(at: AppAudioCapture.marker(in: directory))
            try Self.clear(directory)
        }

        private static func clear(_ directory: URL) throws {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }
}
