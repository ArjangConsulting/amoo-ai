import StudioProtocol

// Each emitter maps its own operations: it renders the same deterministic statements `generate`
// splices into the test body, then locates them in the finished source. `generate` itself is
// untouched, so mapped and unmapped output are always identical.

public extension XCUITestEmitter {
    func generateMapped(_ test: StudioAuthoredTest) throws -> StudioGeneratedSource {
        let result = try generate(test)
        let operations = test.compiledPlan?.toolOperations ?? []
        var localNames = LocalNameAllocator()
        var lookups = [String: String]()
        let statements = try operations.map {
            try Self.statement(for: $0, context: test.testContext, localNames: &localNames, lookups: &lookups)
        }
        return mapped(result, statements: statements, operations: operations)
    }
}

public extension EspressoEmitter {
    func generateMapped(_ test: StudioAuthoredTest) throws -> StudioGeneratedSource {
        let result = try generate(test)
        let operations = test.compiledPlan?.toolOperations ?? []
        let statements = try operations.map { try Self.statement(for: $0, context: test.testContext) }
        return mapped(result, statements: statements, operations: operations)
    }
}

public extension ComposeEspressoEmitter {
    func generateMapped(_ test: StudioAuthoredTest) throws -> StudioGeneratedSource {
        let result = try generate(test)
        let operations = test.compiledPlan?.toolOperations ?? []
        let statements = try operations.indices.map { index in
            let next = index + 1 < operations.count ? operations[index + 1] : nil
            return try Self.statement(for: operations[index], next: next, context: test.testContext)
        }
        return mapped(result, statements: statements, operations: operations)
    }
}

private func mapped(
    _ result: StudioTestExportResult,
    statements: [String],
    operations: [StudioToolOperation]
) -> StudioGeneratedSource {
    .init(
        fileName: result.fileName,
        source: result.source,
        language: StudioGeneratedSource.language(forFileName: result.fileName),
        sourceMap: StudioSourceMapper.map(statements: statements, operationIds: operations.map(\.id), in: result.source)
    )
}
