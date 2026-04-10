# CLAUDE.md

Guidance for AI assistants (Claude Code and similar) working in this repository.

## Project Overview

**Membrane** is a Swift package that implements an actor-isolated 5-stage pipeline
for managing LLM context windows. It decides what stays in context, what gets
compressed, and what gets paged out, while preserving deterministic behavior.

Membrane is one layer of **AIStack**, alongside sibling packages:
- [Conduit](https://github.com/christopherkarani/Conduit) — multi-provider LLM client
- [Wax](https://github.com/christopherkarani/Wax) — on-device memory / RAG
- [Hive](https://github.com/christopherkarani/Hive) — checkpointing / persistence
- [ContextCore](https://github.com/christopherkarani/ContextCore) — context primitives

The sibling packages are consumed through optional adapter modules
(`MembraneConduit`, `MembraneWax`, `MembraneHive`, `MembraneContextCore`).

## Requirements

- **Swift:** 6.2+ (every target sets `swiftLanguageMode(.v6)`)
- **Platforms:** `macOS(.v26)`, `iOS(.v26)`
- **Hardware:** Developed and benchmarked on Apple Silicon

> **Important for AI assistants:** the CI runs on macOS only. If you are
> operating inside a Linux sandbox you **cannot** run `swift build`/`swift test`
> successfully — the targets depend on Foundation features and platform
> versions unavailable on Linux. Do not attempt to "fix" build failures that
> come from running the Linux toolchain; use the CI pipeline instead.

## Repository Layout

```
Membrane/
├── Package.swift             # SPM manifest (6 library products)
├── Package.resolved
├── README.md                 # User-facing docs (kept in sync with locales/)
├── locales/                  # README translations (es, ja, zh-CN)
├── Sources/
│   ├── MembraneCore/         # Protocols, types, budget algebra, errors
│   │   ├── Budget/           # BucketID, BudgetProfile, ContextBudget
│   │   ├── Errors/           # MembraneError + RecoveryStrategy
│   │   ├── Pipeline/         # MembraneStage + stage I/O wrappers
│   │   ├── Types/            # ContextRequest/Window/Slice/Snapshot/etc.
│   │   └── Backends/         # MembraneContextBackend protocol
│   ├── Membrane/             # Pipeline orchestrator + built-in stages
│   │   ├── Pipeline/         # MembranePipeline actor
│   │   ├── MembraneSession.swift
│   │   └── Stages/
│   │       ├── Intake/       # PointerResolver, JITToolLoader, RAPTORRetriever
│   │       ├── Budget/       # UnifiedBudgetAllocator, GQAMemoryEstimator
│   │       ├── Compress/     # CSODistiller, SurrogateTierSelector, ToolPruner
│   │       └── Page/         # MemGPTPager
│   ├── MembraneContextCore/  # ContextCore backend adapter
│   ├── MembraneWax/          # Wax-backed pointer store + RAPTOR index
│   ├── MembraneHive/         # Hive checkpoint adapter
│   └── MembraneConduit/      # Conduit token-counting bridge
├── Tests/
│   ├── MembraneCoreTests/    # Budget, types, stage protocol tests
│   ├── MembraneTests/        # Pipeline, stages, conformance, benchmarks
│   ├── MembraneWaxTests/
│   ├── MembraneHiveTests/
│   └── MembraneConduitTests/
└── .github/workflows/        # CI: membrane-ci, non-local-deps-ci,
                              #     release-gate, security-ci,
                              #     swarm-integration-ci
```

`docs/`, `tasks/`, and `scripts/` are all gitignored and therefore are **not**
committed to the repository. Do not rely on them existing locally and do not
recreate them unless the user explicitly asks.

## Architecture

### The 5-stage pipeline

`MembranePipeline` (`Sources/Membrane/Pipeline/MembranePipeline.swift`) is an
actor that threads a `ContextRequest` through up to five optional stages:

1. **Intake** — `IntakeStage` (`ContextRequest -> ContextWindow`). Resolves
   pointers, plans tool loading, retrieves relevant context.
2. **Budget** — `BudgetStage` (`ContextWindow -> BudgetedContext`). Allocates
   tokens across the 9 bucket IDs.
3. **Compress** — `CompressStage` (`BudgetedContext -> CompressedContext`).
   Distills history into a CSO, picks surrogate tiers, prunes tools.
4. **Page** — `PageStage` (`CompressedContext -> PagedContext`). Evicts
   low-importance slices when token pressure exceeds a threshold.
5. **Emit** — `EmitStage` (`PagedContext -> ContextPlan`). Formats the final
   prompt.

The contract lives in `Sources/MembraneCore/Pipeline/`:

```swift
public protocol MembraneStage: Actor, Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    func process(_ input: Input, budget: ContextBudget) async throws -> Output
}
```

Stages are composed via the specialized protocols `IntakeStage`,
`BudgetStage`, `CompressStage`, `PageStage`, `EmitStage` in
`StageTypes.swift`. All I/O wrapper types (`BudgetedContext`,
`CompressedContext`, `PagedContext`, `ContextPlan`) are `Sendable` structs.

**Budget authority:** the `ContextBudget` parameter passed to `process(_:budget:)`
is authoritative. Wrapper types *carry* a budget for convenience, but stages
must apply decisions using the explicit parameter.

**Pipeline modes:**
- `.full` — runs intake → budget → compress → page → emit (for open models)
- `.budgetOnly` — skips page and emit stages (for Foundation Models). Returned
  by the `MembranePipeline.foundationModel(...)` factory.

### Budget algebra

`ContextBudget` (`Sources/MembraneCore/Budget/ContextBudget.swift`) partitions
total tokens across **9 `BucketID` values**:

`system, history, memory, tools, retrieval, toolIO, outputReserve,
protocolOverhead, safetyMargin`

Each bucket has an immutable `ceiling` and a running `allocated` total.
`allocate(_:to:)` throws `MembraneError.budgetExceeded` when a request would
exceed either the bucket ceiling or the global remaining budget.

Built-in `BudgetProfile` cases: `foundationModels4K`, `openModel8K`,
`cloud200K`, `.custom(buckets:)`. Profiles are pure functions of
`totalTokens` — **do not introduce non-determinism** here.

### Compression tiers

`CompressionTier` has three levels with fixed multipliers:
- `.full` — 1.0x
- `.gist` — 0.25x
- `.micro` — 0.08x

### Session layer

`MembraneSession` (`Sources/Membrane/MembraneSession.swift`) is the
higher-level, stateful actor API. It wraps a backend + pointer store + JIT
tool loader, supports `ContextSnapshot` save/restore, tool-use recording, and
internal tool calls (`membrane_load_tool_schema`, `Add_Tools`, `Remove_Tools`,
`resolve_pointer`).

### Backends

`MembraneContextBackend` (`Sources/MembraneCore/Backends/`) is the protocol
for pluggable prepare/restore/snapshot implementations. The default backend
is `MembraneContextCoreBackend` (in the `MembraneContextCore` module).
`WaxStorageBackend` provides persistent storage with RAPTOR indexing.

## Build & Test

All commands run from the `Membrane/` directory.

```bash
swift build                                # build with remote deps
swift test                                 # run all tests
swift test --filter MembraneConformance    # determinism + checkpoint stability
swift test --filter MembraneBenchmarks     # latency benchmarks
swift test --filter MembraneWaxTests       # single module
```

### Dependency modes

`Package.swift` resolves dependencies in one of two modes based on the
environment:

- **Remote (default):** pins to tagged releases of Hive, ContextCore, Conduit,
  Wax on GitHub.
- **Local:** when `MEMBRANE_USE_LOCAL_DEPS=1` (or `AISTACK_USE_LOCAL_DEPS=1`)
  is set, the manifest uses `path:` references into sibling checkouts
  (`../Hive`, `../ContextCore`, `../Conduit`, `../Wax`). CI uses this mode.

```bash
MEMBRANE_USE_LOCAL_DEPS=1 swift build
MEMBRANE_USE_LOCAL_DEPS=1 swift test
```

When touching the `Package.swift` manifest, **always verify both branches**
of the `if useLocalDeps` block.

### CI workflows (`.github/workflows/`)

- `membrane-ci.yml` — Build and test on `macos-14` and `macos-15` (Swift 6.2)
  with `MEMBRANE_USE_LOCAL_DEPS=1`, plus conformance and benchmark filters.
- `non-local-deps-ci.yml` — Same build/test against the remote-pinned deps.
- `release-gate.yml` — Gating checks for releases.
- `security-ci.yml` — Security scanning.
- `swarm-integration-ci.yml` — Integration with upstream Swarm consumer.

## Conventions

### Swift style

- **Swift 6 strict concurrency is mandatory.** Every target sets
  `swiftSettings: [.swiftLanguageMode(.v6)]`. All public types must be
  `Sendable`, all stages are `actor` types, and shared state must be isolated.
- **Public API stability matters.** Types are explicitly `public` with
  `public init(...)`. Changes to public signatures affect downstream AIStack
  packages.
- **Determinism is a hard requirement.** The `MembraneConformance` test suite
  runs 100 iterations comparing pipeline signatures. Do not introduce random
  ordering, `Date()` calls that leak into hashes, set iteration order, or
  dictionary iteration into stage logic.
  - Sort before emitting. Use `OrderedDictionary`/`OrderedSet` from
    `swift-collections` when order must be preserved.
  - `ContextSnapshot.normalized()` shows the normalization pattern — sort and
    dedupe before exposing collections.
- **Budget invariants.** The budget fuzzing test enforces that:
  - `budget.allocated(for: bucket) <= budget.ceiling(for: bucket)`
  - `budget.totalAllocated <= budget.totalTokens`
  - Over-allocation throws `.budgetExceeded` with precise `requested`/`available`
  - Do not bypass `ContextBudget.allocate(_:to:)` when mutating bucket state.
- **Errors carry recovery strategies.** Extend `MembraneError` rather than
  inventing ad-hoc error types; set an appropriate `RecoveryStrategy` in
  `recoveryStrategy`.
- **Tests use `swift-testing`** (`import Testing`, `@Suite`, `@Test`, `#expect`)
  — not XCTest. Follow the existing patterns in
  `Tests/MembraneTests/Conformance/` and `Tests/MembraneCoreTests/`.

### Module boundaries

- `MembraneCore` must remain dependency-free except for `swift-collections`.
- `Membrane` depends on `MembraneCore` and `MembraneContextCore` only.
- Adapter modules (`MembraneWax`, `MembraneHive`, `MembraneConduit`,
  `MembraneContextCore`) are the only place that should import the
  corresponding sibling package.
- Do **not** introduce a new third-party dependency without discussing with
  the maintainer first — the package intentionally has a minimal footprint.

### README and locales

`README.md` is the canonical English README. `locales/README.es.md`,
`locales/README.ja.md`, and `locales/README.zh-CN.md` are translations. When
you change documented public API or the quick-start example, flag which locale
files need updating — but **only update translations if explicitly asked**,
to avoid drift from stale machine translations.

## Git Workflow

- **Active branch for AI-driven work:** `claude/add-claude-documentation-cKJQR`
  (per session instructions — develop and push only to the branch named in the
  session prompt, never to `main`).
- Commit messages follow the conventional-commit style seen in history:
  `feat(membrane): ...`, `fix: ...`, `chore: ...`, `docs: ...`,
  `refactor(api): ...`, `merge: ...`.
- Do **not** push to `main`, do **not** force-push shared branches, and do
  **not** open a pull request unless the user explicitly requests one.
- Never edit `.git/config`, `Package.resolved` lock state, or CI workflows
  without an explicit instruction.

## Where to Look for What

| Want to…                              | Look at                                                         |
| ------------------------------------- | --------------------------------------------------------------- |
| Understand the stage contract         | `Sources/MembraneCore/Pipeline/MembraneStage.swift`             |
| Understand stage I/O types            | `Sources/MembraneCore/Pipeline/StageTypes.swift`                |
| Understand budget allocation          | `Sources/MembraneCore/Budget/ContextBudget.swift`               |
| See the default pipeline wiring       | `Sources/Membrane/Pipeline/MembranePipeline.swift`              |
| See the stateful session API          | `Sources/Membrane/MembraneSession.swift`                        |
| Review errors + recovery strategies   | `Sources/MembraneCore/Errors/MembraneError.swift`               |
| Verify determinism guarantees         | `Tests/MembraneTests/Conformance/MembraneConformanceTests.swift`|
| Run benchmarks                        | `Tests/MembraneTests/Benchmarks/MembraneBenchmarks.swift`       |
| Plug a new storage backend            | `Sources/MembraneCore/Backends/MembraneContextBackend.swift`    |
| Add a new budget profile              | `Sources/MembraneCore/Budget/BudgetProfile.swift`               |

## Task Checklist for AI Assistants

Before completing a change:

1. Did you preserve `Sendable` and Swift 6 concurrency correctness?
2. Did you update or add tests with `swift-testing`?
3. Is the public API still stable (or is the change intentional)?
4. Is the behavior deterministic (no unsorted sets/dicts, no non-seeded
   randomness, no wall-clock leaks)?
5. If you touched `Package.swift`, did you verify **both** the local-deps and
   remote-deps branches?
6. If you changed public API, is the `README.md` quick-start still accurate?
7. Commit on the designated branch with a conventional-commit message.
