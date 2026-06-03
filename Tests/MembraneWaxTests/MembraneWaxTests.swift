import Foundation
import Testing
@testable import MembraneWax
@testable import MembraneCore

@Suite struct MembraneWaxBootstrapTests {
    @Test func moduleImports() {
        _ = WaxStorageBackend.self
    }

    @Test func pointerPayloadStoredAsBlobWithMembraneMetadata() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        let payloadText = String(repeating: "payload-", count: 900)
        let payload = Data(payloadText.utf8)
        let pointer = try await backend.store(
            payload: payload,
            dataType: .binary,
            summary: "oversized payload"
        )

        let resolved = try await backend.resolve(pointerID: pointer.id)
        let provenance = try #require(await backend.provenance(forPointerID: pointer.id))

        #expect(resolved == payload)
        #expect(provenance.kind == "pointerPayload")
        #expect(provenance.metadata["membrane.pointer.id"] == pointer.id)
        #expect(provenance.metadata["membrane.pointer.sha256"]?.isEmpty == false)
    }

    @Test func ragSearchExcludesPointerPayloadFramesByDefault() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        _ = try await backend.storeContextFrame("shared query normal document")
        _ = try await backend.store(
            payload: Data(String(repeating: "shared query pointer payload ", count: 128).utf8),
            dataType: .document,
            summary: "shared query pointer payload"
        )

        let normalOnly = try await backend.searchRAG(
            query: "shared query",
            topK: 20,
            includePointerPayloads: false
        )
        let withPointers = try await backend.searchRAG(
            query: "shared query",
            topK: 20,
            includePointerPayloads: true
        )

        #expect(normalOnly.items.allSatisfy { $0.metadata["membrane.kind"] != "pointerPayload" })
        #expect(withPointers.items.contains { $0.metadata["membrane.kind"] == "pointerPayload" })
    }

    @Test func raptorNodesPersistAndRoundTripByNodeID() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        let index = await backend.makeRAPTORIndex()
        let node = RAPTORNode(
            id: "node-A",
            parentID: nil,
            depth: 0,
            text: "Alpha node content",
            tokenCount: 32
        )

        let firstFrame = try await index.store(node: node)
        let secondFrame = try await index.store(node: node)
        let restored = try #require(try await index.node(forID: "node-A"))

        #expect(firstFrame == secondFrame)
        #expect(restored == node)
    }

    @Test func raptorSearchUsesFusionAndReturnsDeterministicOrder() async throws {
        let url = makeTempWaxURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = try await WaxStorageBackend.create(at: url)
        defer { Task { try? await backend.close() } }

        let index = await backend.makeRAPTORIndex()
        _ = try await index.store(nodes: [
            RAPTORNode(id: "node-2", parentID: nil, depth: 1, text: "query shared beta", tokenCount: 20),
            RAPTORNode(id: "node-1", parentID: nil, depth: 0, text: "query shared alpha", tokenCount: 20),
            RAPTORNode(id: "node-3", parentID: "node-1", depth: 2, text: "query shared gamma", tokenCount: 20),
        ])

        let first = try await index.search(query: "query shared", topK: 3)
        let second = try await index.search(query: "query shared", topK: 3)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)) == Set(["node-1", "node-2", "node-3"]))
    }
}

private func makeTempWaxURL() -> URL {
    let filename = "membrane-wax-\(UUID().uuidString).wax"
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
}
