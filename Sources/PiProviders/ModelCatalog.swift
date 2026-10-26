import Foundation
import PiTypes

public protocol ModelCatalogSource: Sendable {
    var catalogProviderID: String { get }
    func fetchModels() async throws -> [ModelDescriptor]
}

public struct ModelCatalogResult: Sendable, Equatable {
    public var models: [ModelDescriptor]
    public var fetchedAt: Date
    public var isStale: Bool
    public init(models: [ModelDescriptor], fetchedAt: Date, isStale: Bool) {
        self.models = models
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }
}

/// Small persistent catalog cache. A failed refresh falls back to a dated stale catalog when available.
public actor ModelCatalog {
    private struct CacheRecord: Codable {
        var providerID: String
        var fetchedAt: Date
        var models: [ModelDescriptor]
    }

    private let directory: URL
    private let timeToLive: TimeInterval
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".apple-agent/model-catalog", isDirectory: true),
                timeToLive: TimeInterval = 86_400) {
        self.directory = directory
        self.timeToLive = timeToLive
    }

    public func models(from source: any ModelCatalogSource, forceRefresh: Bool = false,
                       now: Date = .now) async throws -> ModelCatalogResult {
        let cacheURL = directory.appendingPathComponent(source.catalogProviderID + ".json")
        let cached = try? JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: cacheURL))
        if !forceRefresh, let cached, now.timeIntervalSince(cached.fetchedAt) < timeToLive {
            return ModelCatalogResult(models: cached.models, fetchedAt: cached.fetchedAt, isStale: false)
        }
        do {
            let models = try await source.fetchModels().sorted { $0.id < $1.id }
            let record = CacheRecord(providerID: source.catalogProviderID, fetchedAt: now, models: models)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: cacheURL, options: .atomic)
            return ModelCatalogResult(models: models, fetchedAt: now, isStale: false)
        } catch {
            if let cached {
                return ModelCatalogResult(models: cached.models, fetchedAt: cached.fetchedAt, isStale: true)
            }
            throw error
        }
    }
}
