import CryptoKit
import Foundation
import MembraneCore
import Wax

public actor WaxStorageBackend: PointerStore, ContextRecallStore {
    private enum MetadataKey {
        static let kind = "membrane.kind"
        static let pointerID = "membrane.pointer.id"
        static let pointerSHA256 = "membrane.pointer.sha256"
        static let pointerDataType = "membrane.pointer.dataType"
        static let payloadEncoding = "membrane.pointer.payloadEncoding"
        static let summary = "membrane.pointer.summary"

        static let contextFrame = "contextFrame"
        static let pointerPayloadKind = "pointerPayload"
    }

    private enum StorageFormat {
        static let payloadMarker = "\n\n__payload_base64__\n"
    }

    public let memory: Wax.Memory
    private var cachedPayloads: [String: Data] = [:]

    public init(memory: Wax.Memory) {
        self.memory = memory
    }

    public static func create(at url: URL) async throws -> WaxStorageBackend {
        let memory = try await Wax.Memory(at: url)
        return WaxStorageBackend(memory: memory)
    }

    public func close() async throws {
        try await memory.close()
    }

    public func store(payload: Data, dataType: MemoryPointer.DataType, summary: String) async throws -> MemoryPointer {
        let pointerID = Self.pointerID(for: payload)
        let encodedPayload = payload.base64EncodedString()
        let sha256 = Self.sha256Hex(payload)
        let searchableText = Self.searchablePayloadText(payload: payload, summary: summary)
        let storedDocument = Self.storedPointerDocument(
            pointerID: pointerID,
            summary: summary,
            searchableText: searchableText,
            encodedPayload: encodedPayload
        )

        try await memory.save(
            storedDocument,
            metadata: [
                MetadataKey.kind: MetadataKey.pointerPayloadKind,
                MetadataKey.pointerID: pointerID,
                MetadataKey.pointerSHA256: sha256,
                MetadataKey.pointerDataType: dataType.rawValue,
                MetadataKey.payloadEncoding: "base64",
                MetadataKey.summary: summary,
            ]
        )

        cachedPayloads[pointerID] = payload
        return MemoryPointer(
            id: pointerID,
            dataType: dataType,
            byteSize: payload.count,
            summary: summary
        )
    }

    public func resolve(pointerID: String) async throws -> Data {
        if let cached = cachedPayloads[pointerID] {
            return cached
        }

        let results = try await memory.search(
            pointerID,
            options: .init(topK: 20, includeSurrogates: false, mode: .textOnly)
        )
        guard let item = results.items.first(where: {
            $0.metadata[MetadataKey.pointerID] == pointerID
                && $0.metadata[MetadataKey.kind] == MetadataKey.pointerPayloadKind
        }) else {
            throw MembraneError.pointerResolutionFailed(pointerID: pointerID)
        }

        let payload = Self.decodedPayload(from: item.text) ?? Data(item.text.utf8)
        cachedPayloads[pointerID] = payload
        return payload
    }

    public func delete(pointerID: String) async {
        cachedPayloads[pointerID] = nil
    }

    @discardableResult
    public func storeContextFrame(_ text: String) async throws -> UInt64 {
        try await memory.save(
            text,
            metadata: [
                MetadataKey.kind: MetadataKey.contextFrame,
                "membrane.frame.id": Self.syntheticFrameID(for: text),
            ]
        )
        return Self.syntheticFrameValue(for: text)
    }

    public func searchRAG(
        query: String,
        topK: Int,
        includePointerPayloads: Bool = false
    ) async throws -> Wax.Memory.Results {
        let results = try await memory.search(
            query,
            options: .init(topK: max(1, topK), includeSurrogates: false, mode: .textOnly)
        )
        guard includePointerPayloads else {
            return Wax.Memory.Results(
                query: results.query,
                items: results.items.filter { $0.metadata[MetadataKey.kind] != MetadataKey.pointerPayloadKind },
                totalTokens: results.totalTokens
            )
        }
        return results
    }

    public func recall(query: String, limit: Int) async throws -> [ContextRecallCandidate] {
        let results = try await searchRAG(query: query, topK: limit, includePointerPayloads: true)
        return results.items.map { item in
            ContextRecallCandidate(
                content: item.text,
                score: Double(item.score),
                provenance: ContextProvenance(
                    backendID: "wax",
                    recordID: String(item.frameId),
                    kind: item.metadata[MetadataKey.kind] ?? "unknown",
                    metadata: item.metadata
                )
            )
        }
    }

    public func makeRAPTORIndex() -> RAPTORWaxIndex {
        RAPTORWaxIndex(memory: memory)
    }

    public func provenance(forPointerID pointerID: String) async throws -> ContextProvenance? {
        let results = try await memory.search(
            pointerID,
            options: .init(topK: 20, includeSurrogates: false, mode: .textOnly)
        )
        guard let item = results.items.first(where: { $0.metadata[MetadataKey.pointerID] == pointerID }) else {
            return nil
        }
        return ContextProvenance(
            backendID: "wax",
            recordID: String(item.frameId),
            kind: item.metadata[MetadataKey.kind] ?? "unknown",
            metadata: item.metadata
        )
    }

    private static func pointerID(for payload: Data) -> String {
        let hash = sha256Hex(payload)
        return "ptr_\(hash.prefix(16))"
    }

    private static func sha256Hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func syntheticFrameID(for text: String) -> String {
        "frame_" + sha256Hex(Data(text.utf8)).prefix(16)
    }

    private static func syntheticFrameValue(for text: String) -> UInt64 {
        let digest = sha256Hex(Data(text.utf8))
        return UInt64(String(digest.prefix(16)), radix: 16) ?? 0
    }

    private static func searchablePayloadText(payload: Data, summary: String) -> String {
        guard let decoded = String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            decoded.isEmpty == false else {
            return summary
        }
        return decoded
    }

    private static func storedPointerDocument(
        pointerID: String,
        summary: String,
        searchableText: String,
        encodedPayload: String
    ) -> String {
        """
        pointer_id: \(pointerID)
        summary: \(summary)
        \(searchableText)\(StorageFormat.payloadMarker)\(encodedPayload)
        """
    }

    private static func decodedPayload(from storedText: String) -> Data? {
        if let range = storedText.range(of: StorageFormat.payloadMarker) {
            let encodedPayload = storedText[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Data(base64Encoded: String(encodedPayload))
        }
        return Data(base64Encoded: storedText)
    }
}
