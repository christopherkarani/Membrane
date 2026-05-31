import Foundation
import MembraneCore

public enum ContextSnapshotCodec {
    public static func encode(_ snapshot: ContextSnapshot?) throws -> Data? {
        guard let snapshot else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot.normalized())
    }

    public static func decode(_ data: Data?) throws -> ContextSnapshot? {
        guard let data else {
            return nil
        }
        let decoded = try JSONDecoder().decode(ContextSnapshot.self, from: data)
        return decoded.normalized()
    }
}

public actor ContextSnapshotCheckpointAdapter {
    private var snapshot: ContextSnapshot?

    public init(initialSnapshot: ContextSnapshot? = nil) {
        snapshot = initialSnapshot?.normalized()
    }

    public func restore(from checkpointData: Data?) throws {
        snapshot = try ContextSnapshotCodec.decode(checkpointData)
    }

    public func replaceSnapshot(_ newSnapshot: ContextSnapshot?) {
        snapshot = newSnapshot?.normalized()
    }

    public func currentSnapshot() -> ContextSnapshot? {
        snapshot
    }

    public func replaceState(_ newState: ContextSnapshot?) {
        replaceSnapshot(newState)
    }

    public func currentState() -> ContextSnapshot? {
        currentSnapshot()
    }

    public func checkpointData() throws -> Data? {
        try ContextSnapshotCodec.encode(snapshot)
    }
}

public typealias MembraneCheckpointState = ContextSnapshot
public typealias MembraneCheckpointCodec = ContextSnapshotCodec
public typealias MembraneCheckpointAdapter = ContextSnapshotCheckpointAdapter
