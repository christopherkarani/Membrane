import CryptoKit
import Foundation
import Membrane
import MembraneCore
import Wax

public actor RAPTORWaxIndex: RAPTORIndex {
    private enum MetadataKey {
        static let kind = "membrane.kind"
        static let nodeID = "membrane.raptor.id"
        static let parentID = "membrane.raptor.parent_id"
        static let depth = "membrane.raptor.depth"
        static let tokenCount = "membrane.raptor.token_count"

        static let nodeKind = "raptorNode"
    }

    private enum StorageFormat {
        static let nodeMarker = "\n\n__raptor_node_json__\n"
    }

    public let memory: Wax.Memory

    public init(memory: Wax.Memory) {
        self.memory = memory
    }

    @discardableResult
    public func store(node: RAPTORNode) async throws -> UInt64 {
        let encoded = try JSONEncoder().encode(node)
        let text = Self.storedNodeDocument(node: node, encodedNode: encoded)
        try await memory.save(
            text,
            metadata: [
                MetadataKey.kind: MetadataKey.nodeKind,
                MetadataKey.nodeID: node.id,
                MetadataKey.parentID: node.parentID ?? "",
                MetadataKey.depth: String(node.depth),
                MetadataKey.tokenCount: String(node.tokenCount),
            ]
        )
        return Self.syntheticFrameValue(for: node.id)
    }

    @discardableResult
    public func store(nodes: [RAPTORNode]) async throws -> [UInt64] {
        var frameIDs: [UInt64] = []
        frameIDs.reserveCapacity(nodes.count)
        for node in nodes {
            frameIDs.append(try await store(node: node))
        }
        return frameIDs
    }

    public func search(query: String, topK: Int) async throws -> [RAPTORNode] {
        let results = try await memory.search(
            query,
            options: .init(topK: max(1, topK * 3), includeSurrogates: false, mode: .textOnly)
        )

        let decodedNodes = results.items.compactMap { item -> (RAPTORNode, Float)? in
            guard item.metadata[MetadataKey.kind] == MetadataKey.nodeKind else { return nil }
            guard let node = Self.decodeNode(from: item.text) else {
                return nil
            }
            return (node, item.score)
        }

        return decodedNodes
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                if lhs.0.depth != rhs.0.depth {
                    return lhs.0.depth < rhs.0.depth
                }
                return lhs.0.id < rhs.0.id
            }
            .prefix(max(0, topK))
            .map(\.0)
    }

    public func node(forID nodeID: String) async throws -> RAPTORNode? {
        let results = try await memory.search(
            nodeID,
            options: .init(topK: 20, includeSurrogates: false, mode: .textOnly)
        )
        for item in results.items where item.metadata[MetadataKey.nodeID] == nodeID {
            guard let node = Self.decodeNode(from: item.text) else {
                continue
            }
            return node
        }
        return nil
    }

    private static func syntheticFrameValue(for nodeID: String) -> UInt64 {
        let digest = Data(SHA256.hash(data: Data(nodeID.utf8)))
        let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return UInt64(prefix, radix: 16) ?? 0
    }

    private static func storedNodeDocument(node: RAPTORNode, encodedNode: Data) -> String {
        let encodedPayload = encodedNode.base64EncodedString()
        return """
        \(node.id)
        \(node.text)\(StorageFormat.nodeMarker)\(encodedPayload)
        """
    }

    private static func decodeNode(from storedText: String) -> RAPTORNode? {
        if let range = storedText.range(of: StorageFormat.nodeMarker) {
            let encodedNode = storedText[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: String(encodedNode)),
               let node = try? JSONDecoder().decode(RAPTORNode.self, from: data) {
                return node
            }
        }

        if let data = storedText.data(using: .utf8),
           let node = try? JSONDecoder().decode(RAPTORNode.self, from: data) {
            return node
        }

        return nil
    }
}
