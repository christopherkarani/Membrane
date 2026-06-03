import Testing
@testable import Membrane

@Suite struct MembraneBootstrapTests {
    @Test func moduleImports() {
        _ = MembranePipeline.self
    }
}
