import Foundation

public enum MeasurementStore: Sendable {
    case markdown(MarkdownStore)
    case json(JSONStore)

    public init(configuration: ReaderConfiguration) {
        switch configuration.outputFormat {
        case .markdown:
            self = .markdown(MarkdownStore(
                fileURL: configuration.outputFileURL,
                canonicalFileURL: configuration.measurementMirrorURL,
                storeID: configuration.storeID,
                deduplicationWindow: configuration.deduplicationWindow
            ))
        case .json:
            self = .json(JSONStore(
                fileURL: configuration.outputFileURL,
                canonicalFileURL: configuration.measurementMirrorURL,
                storeID: configuration.storeID,
                deduplicationWindow: configuration.deduplicationWindow
            ))
        }
    }

    @discardableResult
    public func append(_ record: MeasurementRecord) throws -> Bool {
        switch self {
        case let .markdown(store):
            return try store.append(record)
        case let .json(store):
            return try store.append(record)
        }
    }

    @discardableResult
    public func restoreOutputFromCanonicalIfNeeded() throws -> Bool {
        switch self {
        case let .markdown(store):
            return try store.restoreOutputFromCanonicalIfNeeded()
        case let .json(store):
            return try store.restoreOutputFromCanonicalIfNeeded()
        }
    }

    public func latestWeightKilograms() throws -> Double? {
        switch self {
        case let .markdown(store):
            return try store.latestWeightKilograms()
        case let .json(store):
            return try store.latestWeightKilograms()
        }
    }
}
