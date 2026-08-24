import Foundation

public enum RotatingFileLoggerError: Error, Equatable, Sendable {
    case invalidMaximumBytes(Int)
    case invalidBackupCount(Int)
}

public final class RotatingFileLogger: @unchecked Sendable {
    public let fileURL: URL
    public let debugEnabled: Bool
    public let maximumBytes: Int
    public let backupCount: Int

    private let lock = NSLock()

    public init(
        fileURL: URL,
        debugEnabled: Bool,
        maximumBytes: Int = 1_048_576,
        backupCount: Int = 3
    ) throws {
        guard maximumBytes > 0 else {
            throw RotatingFileLoggerError.invalidMaximumBytes(maximumBytes)
        }
        guard backupCount >= 0 else {
            throw RotatingFileLoggerError.invalidBackupCount(backupCount)
        }
        self.fileURL = fileURL
        self.debugEnabled = debugEnabled
        self.maximumBytes = maximumBytes
        self.backupCount = backupCount

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try SecureFile.protect(fileURL)
        } else {
            try SecureFile.write(Data(), to: fileURL)
        }
    }

    public func info(_ message: String) throws {
        try write(level: "INFO", message: message)
    }

    public func error(_ message: String) throws {
        try write(level: "ERROR", message: message)
    }

    public func debug(_ message: String) throws {
        guard debugEnabled else { return }
        try write(level: "DEBUG", message: message)
    }

    private func write(level: String, message: String) throws {
        let line = "\(timestamp()) \(level) \(singleLine(message))\n"
        let unboundedData = Data(line.utf8)
        var data = Data(unboundedData.prefix(maximumBytes))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
            data.removeLast()
        }

        lock.lock()
        defer { lock.unlock() }

        let currentBytes = try fileSize(at: fileURL)
        if currentBytes + unboundedData.count > maximumBytes {
            try rotate()
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try SecureFile.protect(fileURL)
    }

    private func rotate() throws {
        guard backupCount > 0 else {
            try SecureFile.write(Data(), to: fileURL)
            return
        }

        let oldest = backupURL(backupCount)
        if FileManager.default.fileExists(atPath: oldest.path) {
            try FileManager.default.removeItem(at: oldest)
        }

        if backupCount > 1 {
            for index in stride(from: backupCount - 1, through: 1, by: -1) {
                let source = backupURL(index)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = backupURL(index + 1)
                try FileManager.default.moveItem(at: source, to: destination)
                try SecureFile.protect(destination)
            }
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let firstBackup = backupURL(1)
            try FileManager.default.moveItem(at: fileURL, to: firstBackup)
            try SecureFile.protect(firstBackup)
        }
        try SecureFile.write(Data(), to: fileURL)
    }

    private func backupURL(_ index: Int) -> URL {
        URL(fileURLWithPath: fileURL.path + ".\(index)")
    }

    private func fileSize(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try SecureFile.write(Data(), to: url)
            return 0
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func singleLine(_ message: String) -> String {
        message.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
