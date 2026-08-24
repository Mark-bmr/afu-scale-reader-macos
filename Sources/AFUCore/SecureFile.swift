import Foundation

public enum SecureFile {
    public static func write(_ data: Data, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        let directoryExisted = FileManager.default.fileExists(atPath: directoryURL.path)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryExisted ? nil : [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try protect(fileURL)
    }

    public static func write(_ text: String, to fileURL: URL) throws {
        try write(Data(text.utf8), to: fileURL)
    }

    public static func protect(_ fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
