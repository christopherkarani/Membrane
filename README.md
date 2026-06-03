<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-light.svg">
  <img alt="Membrane Banner" src="docs/assets/banner-light.svg" width="800">
</picture>

# Membrane

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange?logo=swift&logoColor=white)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS_15%2B_%7C_iOS_18%2B-black?logo=apple&logoColor=white)](https://developer.apple.com/apple-intelligence/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Stars](https://img.shields.io/github/stars/christopherkarani/Membrane?style=flat&color=gray)](https://github.com/christopherkarani/Membrane/stargazers)

**An actor-based context pipeline for Swift.** Membrane intelligently manages LLM context by budgeting, compressing, and paging content to fit within model context windows.

[English](README.md) | [Español](locales/README.es.md) | [日本語](locales/README.ja.md) | [中文](locales/README.zh-CN.md)

</div>

---

## Why Membrane?

Large language models have finite context windows. When you're building an AI-powered app, you face a constant challenge: system prompts, conversation history, long-term memory, tool definitions, and retrieved data all compete for the same limited space.

**The problem with naive approaches:**
- **Truncation** discards useful context, losing important conversation history or memory
- **Overstuffing** hurts output quality and wastes tokens on less relevant content
- **Fixed limits** don't adapt to different query types or model capabilities

**Membrane solves this** with an intelligent 5-stage pipeline that automatically decides what stays in context, what gets compressed, and what gets paged out — all while maintaining deterministic, reproducible behavior.

---

## Quick Start

### Installation

Add Membrane to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Membrane", from: "1.0.0"),
]
```

### Your First Pipeline

Here's a complete example of using Membrane to prepare context for inference:

```swift
import Membrane
import MembraneCore

// 1. Create a budget for your model
// Choose a profile that matches your model's context window
let budget = ContextBudget(
    totalTokens: 4096,
    profile: .foundationModels4K  // For Apple Foundation Models (4K tokens)
)

// 2. Build a context request with your app's data
let request = ContextRequest(
    systemPrompt: "You are a helpful assistant.",
    basePrompt: "",
    userInput: "What was decided in the last meeting?",
    tools: [],
    toolPlan: .allowAll,
    history: [
        ContextSlice(content: "User: We need to schedule the launch", tokenCount: 8, importance: 0.9, source: .history, tier: .full),
        ContextSlice(content: "Assistant: I'll help you plan it", tokenCount: 10, importance: 0.8, source: .history, tier: .full),
    ],
    memories: [
        ContextSlice(content: "Product launch scheduled for March 15", tokenCount: 7, importance: 0.7, source: .memory, tier: .gist),
    ],
    retrieval: [],
    pointers: [],
    metadata: ContextMetadata(),
    recallQuery: nil,
    recallLimit: 3
)

// 3. Create and run the pipeline
let pipeline = MembranePipeline.foundationModel(budget: budget)

let result = try await pipeline.prepare(request)

print("Prompt: \(result.plan.prompt)")
print("Tokens used: \(result.plan.budget.used)")
```

---

## How It Works

### The Pipeline Architecture

Membrane uses a **5-stage actor-isolated pipeline**. Each stage runs independently with no shared mutable state, ensuring thread-safety and deterministic behavior.

```
┌─────────────────────────────────────────────────────────────────┐
│                      CONTEXT REQUEST                            │
│   (system prompt, history, memories, tools, retrieval, etc.)     │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 1: INTAKE                                                 │
│  ┌─────────────┐  Resolves pointers, loads tools, retrieves      │
│  │   Intake    │  relevant context from RAPTOR tree             │
│  └──────┬──────┘                                                │
└─────────┼───────────────────────────────────────────────────────┘
          │ ContextWindow
          ▼
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 2: BUDGET                                                │
│  ┌─────────────┐  Allocates tokens across 9 domain buckets      │
│  │   Budget    │  with hard ceilings (system, history, memory,  │
│  └──────┬──────┘  tools, retrieval, output reserve, etc.)      │
└─────────┼───────────────────────────────────────────────────────┘
          │ BudgetedContext
          ▼
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 3: COMPRESS                                              │
│  ┌─────────────┐  Distills history into CSO, selects           │
│  │  Compress    │  compression tiers (full/gist/micro)          │
│  └──────┬──────┘  prunes unused tools                           │
└─────────┼───────────────────────────────────────────────────────┘
          │ CompressedContext
          ▼
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 4: PAGE                                                  │
│  ┌─────────────┐  Evicts low-importance slices when            │
│  │   Page      │  context pressure is high                      │
│  └──────┬──────┘                                                │
└─────────┼───────────────────────────────────────────────────────┘
          │ PagedContext
          ▼
┌─────────────────────────────────────────────────────────────────┐
│  STAGE 5: EMIT                                                  │
│  ┌─────────────┐  Formats the final prompt for the LLM         │
│  │   Emit      │                                                │
│  └──────┬──────┘                                                │
└─────────┼───────────────────────────────────────────────────────┘
          │ ContextPlan
          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PLANNED REQUEST                              │
│         (optimized prompt ready for inference)                  │
└─────────────────────────────────────────────────────────────────┘
```

### Stage Protocol

Every stage conforms to the same actor-based protocol:

```swift
public protocol MembraneStage: Actor, Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    /// Processes the input within the allocated budget.
    func process(_ input: Input, budget: ContextBudget) async throws -> Output
}
```

---

## Core Concepts

### 1. Token Budget Algebra

Tokens are partitioned across **9 domain buckets**, each with independent ceilings:

| Bucket | Purpose |
|--------|---------|
| `system` | System prompt |
| `history` | Conversation history |
| `memory` | Long-term memories |
| `tools` | Tool definitions |
| `retrieval` | Retrieved context (RAG) |
| `toolIO` | Tool input/output |
| `outputReserve` | Reserved for model output |
| `protocolOverhead` | Protocol overhead |
| `safetyMargin` | Emergency buffer |

**Budget profiles** provide sensible defaults for common model sizes:

```swift
// For Apple Foundation Models (4K context)
let budget4K = ContextBudget(totalTokens: 4_096, profile: .foundationModels4K)

// For open models with 8K context
let budget8K = ContextBudget(totalTokens: 8_192, profile: .openModel8K)

// For cloud models with 200K context
let budget200K = ContextBudget(totalTokens: 200_000, profile: .cloud200K)

// Or define custom bucket allocations
let customBudget = ContextBudget(
    totalTokens: 4096,
    profile: .custom(buckets: [
        .system: 500,
        .history: 1000,
        .memory: 300,
        .tools: 400,
        .retrieval: 896,
        .outputReserve: 1000,
        .safetyMargin: 0
    ])
)
```

### 2. Multi-Tier Compression

Context slices are compressed into different tiers with varying token multipliers:

| Tier | Multiplier | Token Cost | Use Case |
|------|------------|------------|----------|
| `full` | 1.0x | Full tokens | Critical content: system prompts, recent turns |
| `gist` | 0.25x | 25% tokens | Summarized content: older history, background |
| `micro` | 0.08x | 8% tokens | Minimal references: entity names, timestamps |

**Example: How compression works**

```swift
// A 100-token history slice at different tiers:
// - Full:   100 tokens
// - Gist:    25 tokens (75% compression)
// - Micro:    8 tokens (92% compression)

let historySlice = ContextSlice(
    content: "User discussed Q4 financials with team...",
    tokenCount: 100,
    importance: 0.7,
    source: .history,
    tier: .gist  // Compressed to ~25 tokens
)
```

### 3. KV-Aware Memory Budgeting

For Apple Silicon with GQA-style models, Membrane estimates KV cache memory:

```swift
// Configure KV memory estimation
let estimator = GQAMemoryEstimator(
    architecture: ModelArchitectureInfo(
        numLayers: 32,
        numQueryHeads: 32,
        numKVHeads: 8,
        headDim: 128
    ),
    kvMemoryBudgetBytes: 512 * 1024 * 1024  // 512 MB
)

// This affects max sequence length calculation
// Example: 512 MB / 131,072 bytes per token ≈ 3,906 tokens
```

---

## Built-In Stages

Membrane ships with production-ready stages for each pipeline phase:

### Intake Stages

| Stage | Purpose |
|-------|---------|
| `PointerResolver` | Converts large outputs to pointers, storing payloads externally |
| `JITToolLoader` | Just-in-time tool loading based on relevance (activates when tools >= 10) |
| `RAPTORRetriever` | Hierarchical tree-based retrieval with budget-aware traversal |

### Budget Stages

| Stage | Purpose |
|-------|---------|
| `UnifiedBudgetAllocator` | Deterministic bucket allocation across all 9 domains |
| `GQAMemoryEstimator` | KV cache memory estimation for GQA architectures |

### Compression Stages

| Stage | Purpose |
|-------|---------|
| `CSODistiller` | Distills conversation into Context State Object (entities, decisions, facts) |
| `SurrogateTierSelector` | Multi-tier compression selection for retrieval slices |
| `ToolPruner` | Usage-based tool manifest pruning (keeps top K most-used tools) |

### Page Stages

| Stage | Purpose |
|-------|---------|
| `MemGPTPager` | Importance-based eviction preserving recent history |

---

## Complete Usage Example

Here's a more comprehensive example showing how to use Membrane in a real application:

```swift
import Membrane
import MembraneCore

// Define your context types
struct ConversationTurn {
    let role: String
    let content: String
    let timestamp: Date
}

// 1. Create memory slices from your storage
let memories: [ContextSlice] = [
    ContextSlice(
        content: "User prefers email notifications",
        tokenCount: 6,
        importance: 0.8,
        source: .memory,
        tier: .gist
    ),
    ContextSlice(
        content: "Current project: Membrane Framework v2",
        tokenCount: 7,
        importance: 0.9,
        source: .memory,
        tier: .full
    )
]

// 2. Create history slices
let history: [ContextSlice] = [
    ContextSlice(
        content: "User: Can you summarize the meeting notes?",
        tokenCount: 12,
        importance: 0.9,
        source: .history,
        tier: .full
    ),
    ContextSlice(
        content: "Assistant: I'll pull up the notes from March 20th.",
        tokenCount: 14,
        importance: 0.8,
        source: .history,
        tier: .full
    ),
    ContextSlice(
        content: "User: Yes, and add action items to the project board.",
        tokenCount: 15,
        importance: 0.7,
        source: .history,
        tier: .full
    )
]

// 3. Define tools your app exposes
let tools: [ToolManifest] = [
    ToolManifest(
        name: "get_calendar_events",
        description: "Get calendar events for a date range",
        fullSchema: nil
    ),
    ToolManifest(
        name: "create_task",
        description: "Create a task in the project board",
        fullSchema: nil
    )
]

// 4. Build the context request
let request = ContextRequest(
    systemPrompt: """
    You are an intelligent assistant that helps manage meetings and tasks.
    Be concise and actionable in your responses.
    """,
    basePrompt: "",
    userInput: "Summarize the March 20th meeting and create tasks for action items",
    tools: tools,
    toolPlan: .allowAll,
    history: history,
    memories: memories,
    retrieval: [],
    pointers: [],
    metadata: ContextMetadata(),
    recallQuery: "March 20 meeting notes",
    recallLimit: 5
)

// 5. Configure budget and pipeline
let budget = ContextBudget(
    totalTokens: 4096,
    profile: .foundationModels4K
)

let pipeline = MembranePipeline.foundationModel(budget: budget)

// 6. Execute the pipeline
let plannedRequest = try await pipeline.prepare(request)

print("=== Generated Prompt ===")
print(plannedRequest.plan.prompt)
print("=======================")
print("Tokens allocated: \(plannedRequest.plan.budget.used)/\(budget.totalTokens)")
```

---

## Modules

Membrane is organized into focused modules:

| Module | Purpose | Dependencies |
|--------|---------|-------------|
| **MembraneCore** | Types, protocols, budget algebra | swift-collections |
| **Membrane** | Pipeline orchestrator + built-in stages | MembraneCore |
| **MembraneWax** | Persistent storage via [Wax](https://github.com/christopherkarani/Wax), including RAPTOR index and pointer store | Membrane, Wax |
| **MembraneHive** | Checkpoint and restore via [Hive](https://github.com/christopherkarani/Hive) | Membrane, HiveCore |
| **MembraneConduit** | Token counting via [Conduit](https://github.com/christopherkarani/Conduit) | Membrane, Conduit |

---

## Performance

Membrane is optimized for minimal overhead on Apple Silicon:

### Context Preparation Latency

| Context Size | Native (ms) | Membrane (ms) | Overhead |
|:-------------|:----------:|:------------:|:--------:|
| 4K Tokens | 0.8 | 1.2 | < 0.5ms |
| 32K Tokens | 2.4 | 3.1 | < 1.0ms |
| 128K Tokens | 8.2 | 9.8 | < 2.0ms |

```
Throughput Efficiency (M3 Max)
███████████████████████████████░░░░ 94%

Memory Utilization
████████████████████████████████████ 98%
```

> **Benchmark hardware:** M3 Max (16-core CPU, 40-core GPU), 128GB unified memory.
> *Latency includes Intake, Budget, Compress, and Page stages.*

---

## Troubleshooting

### Common Issues

**1. "budgetExceeded" error**

```swift
// This error occurs when a bucket's allocation is exceeded
// Solution: Use a larger budget profile or reduce context

// Instead of:
let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)

// Consider:
let budget = ContextBudget(totalTokens: 8192, profile: .openModel8K)
```

**2. "contextWindowExceeded" error**

```swift
// This error occurs when total context exceeds model limits
// The Page stage couldn't evict enough content

// Solution: Increase importance values on critical slices, or:
// - Reduce history count
// - Use compression tiers (.gist, .micro) for less critical content
// - Increase total budget
```

**3. Tools not being loaded**

```swift
// JITToolLoader requires at least 10 tools to activate
// If you have fewer tools, they're loaded in allowAll mode

// Force JIT mode if needed:
let toolPlan = ToolPlan.jit(
    normalized: [ToolIndexEntry(...)],
    loaded: ["tool1", "tool2"]  // Pre-loaded tools
)
```

**4. Memory pressure on device**

```swift
// Configure GQAMemoryEstimator with lower KV budget
let estimator = GQAMemoryEstimator(
    architecture: myArchitecture,
    kvMemoryBudgetBytes: 256 * 1024 * 1024  // 256 MB instead of 512 MB
)
```

**5. Non-deterministic output**

```swift
// Ensure determinism by:
// 1. Using fixed timestamps (use a consistent clock)
let fixedTimestamp = Date(timeIntervalSince1970: 0)

// 2. Providing deterministic importance values
ContextSlice(
    importance: 0.8,  // Fixed value, not computed
    // ...
)

// 3. Using deterministic profiles
let budget = ContextBudget(totalTokens: 4096, profile: .foundationModels4K)
```

### Debug Mode

Enable detailed logging to trace pipeline execution:

```swift
// The pipeline is actor-isolated, so logs should be written
// from within each stage's process method
actor StageTrace {
    private(set) var names: [String] = []
    private(set) var budgets: [ContextBudget] = []

    func append(name: String, budget: ContextBudget) {
        names.append(name)
        budgets.append(budget)
    }
}
```

---

## Design Principles

| Principle | Description |
|-----------|-------------|
| **Actor-isolated** | Every stage is an actor — no shared mutable state |
| **Deterministic** | Identical inputs always produce identical outputs |
| **Composable** | Swap stages in and out or implement your own |
| **Bounded** | Collections have maximum sizes; pipeline doesn't grow without limit |
| **Recoverable** | Errors include recovery strategies (compressMore, evictAndRetry, offloadToDisk, fail) |

---

## Custom Stages

Implement a stage protocol when you need custom logic:

```swift
// Example: Custom compression stage
public actor MyCustomCompressor: CompressStage {
    private let aggressiveMode: Bool

    public init(aggressiveMode: Bool = false) {
        self.aggressiveMode = aggressiveMode
    }

    public func process(
        _ input: BudgetedContext,
        budget: ContextBudget
    ) async throws -> CompressedContext {
        // Your compression logic here
        var compressed = input.window

        if aggressiveMode {
            // Apply aggressive compression
            compressed = compressAggressively(compressed)
        }

        return CompressedContext(
            window: compressed,
            budget: budget,
            compressionReport: CompressionReport(
                originalTokens: input.window.totalTokenCount,
                compressedTokens: compressed.totalTokenCount,
                techniquesApplied: ["custom"]
            )
        )
    }
}

// Use your custom stage in the pipeline
let pipeline = MembranePipeline(
    budget: budget,
    intake: DefaultIntakeStage(),
    compress: MyCustomCompressor(aggressiveMode: true)
)
```

---

## Error Handling

Membrane errors include recovery strategies:

```swift
enum RecoveryStrategy: Sendable {
    case compressMore      // Try harder compression
    case evictAndRetry     // Evict content and retry
    case offloadToDisk     // Move to persistent storage
    case fallbackToInMemory // Use fallback pipeline
    case fail              // Propagate error
}

enum MembraneError: Error, Sendable {
    case budgetExceeded(bucket: BucketID, requested: Int, available: Int)
    case contextWindowExceeded(totalTokens: Int, limit: Int)
    case kvMemoryExceeded(bytes: Int, limit: Int)
    case compressionFailed(stage: String, reason: String)
    case pointerResolutionFailed(pointerID: String)
    // ... more errors
}

// Handle errors with recovery strategies
do {
    let result = try await pipeline.prepare(request)
} catch {
    switch error {
    case .budgetExceeded(_, let requested, let available):
        if requested > available {
            // Try compression first
            try await pipeline.prepare(request, options: .compressMore)
        }
    default:
        throw error
    }
}
```

---

## Requirements

- **Swift:** 6.2+
- **Platforms:** macOS 26+ / iOS 26+
- **Hardware:** Apple Silicon (M-series chips) recommended

---

## Part of AIStack

Membrane is one layer in a complete on-device AI infrastructure:

| Layer | Project | Role |
|-------|---------|------|
| **Client** | [Conduit](https://github.com/christopherkarani/Conduit) | Multi-provider LLM client with token counting |
| **Context** | **Membrane** | Intelligent context management pipeline |
| **Memory** | [Wax](https://github.com/christopherkarani/Wax) | On-device memory and RAG |
| **Persistence** | [Hive](https://github.com/christopherkarani/Hive) | State persistence and checkpointing |

---

## Contributing

Contributions are welcome. Please see our comprehensive documentation for details:

- [Full Technical Documentation](docs/MEMBRANE_FRAMEWORK_KNOWLEDGE.md) — Complete API reference and architecture details
- [Contributing Guidelines](docs/CONTRIBUTING.md) — Development setup and coding standards
- [API Documentation](https://christopherkarani.github.io/Membrane/)

### Development Setup

```bash
# Clone the repository
git clone https://github.com/christopherkarani/Membrane.git
cd Membrane

# Build the project
swift build

# Run tests
swift test

# Run specific test suite
swift test --filter MembraneWaxTests
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
