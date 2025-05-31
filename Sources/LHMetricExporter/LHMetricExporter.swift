import Foundation
import UIKit

var exportURL: URL {
    #if Debug
    return URL(string: "http://test.metrics.com")!
    #endif
    return URL(string: "http://test.metrics.com")!
}

public enum Unit: String, Codable {
    case seconds
    case miliseconds
    case nanoseconds
}

enum MetricType: String, Codable {
    case ScreenLoading
    case Counter
}

struct Metric: Codable {
    let id: String
    let name: String
    let type: MetricType
    let value: Double
    let unit: Unit
    let date: Date

    init(name: String, type: MetricType, value: Double, unit: Unit, date: Date) {
        self.id = UUID().uuidString
        self.name = name
        self.type = type
        self.value = value
        self.unit = unit
        self.date = date
    }
}

public protocol ScreenLoaderProtocol {
    func start(name: String)
    func stop(name: String)
    func record(name: String, value: Double, unit: Unit)
}

public final class ScreenLoader: ScreenLoaderProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ScreenLoader")
    private let storage: MetricPersistenceStorage
    private let threshold: TimeInterval
    private let exporter: MetricExporter
    private let notificationCenter: NotificationCenter
    private var runningTimer: Timer?
    private var inProgress: [String: Date] = [:]
    private var timer: Timer.Type

    init(
        storage: MetricPersistenceStorage = FilePersistenceStorage(),
        threshold: TimeInterval,
        exporter: MetricExporter = RemoteMetricExporter(),
        notificationCenter: NotificationCenter = .default,
        timer: Timer.Type = Timer.self
    ) {
        self.storage = storage
        self.exporter = exporter
        self.threshold = threshold
        self.notificationCenter = notificationCenter
        self.timer = timer
        checkLastSyncedDate()
        setupTimer()
        setupNotification()
    }

    public convenience init(timerThreshold: TimeInterval = 3600) {
        self.init(threshold: timerThreshold)
    }

    public func record(name: String, value: Double, unit: Unit) {
        let metrict = Metric(name: name, type: .ScreenLoading, value: abs(value), unit: .seconds, date: Date())
        try? storage.save(value: metrict)
    }

    public func start(name: String) {
        setInProgressOperation(for: name, date: Date())
    }

    public func stop(name: String) {
        guard let startTime = inProgressOperation(for: name) else { return }
        let timeDiff = startTime.timeIntervalSinceNow
        let metrict = Metric(name: name, type: .ScreenLoading, value: abs(timeDiff), unit: .seconds, date: Date())
        try? storage.save(value: metrict)
        removeInProgressOperation(for: name)
    }

    private func setInProgressOperation(for name: String, date: Date) {
        queue.sync { inProgress[name] = date }
    }

    private func inProgressOperation(for name: String) -> Date? {
        queue.sync { inProgress[name] }
    }

    private func removeInProgressOperation(for name: String) {
        queue.sync { inProgress[name] = nil }
    }

    private func setupTimer() {
        runningTimer?.invalidate()
        runningTimer = timer.scheduledTimer(withTimeInterval: threshold, repeats: true) { [weak self] _ in
            self?.exporter.export()
        }
    }

    private func checkLastSyncedDate() {
        if let date = storage.lastSyncedTimestamp() {
            if date.timeIntervalSinceNow >= threshold {
                exporter.export()
                setupTimer()
            }
        }
        storage.setLastSyncedTimestamp(date: Date())
    }

    private func setupNotification() {
        notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.checkLastSyncedDate()
        }
    }

    deinit {
        notificationCenter.removeObserver(self)
    }
}

protocol MetricPersistenceStorage {
    func save(value: Metric) throws
    func load() -> [Metric]
    func clearAll()
    func replace(values: [Metric]) throws
    func setLastSyncedTimestamp(date: Date)
    func lastSyncedTimestamp() -> Date?
}

final class FilePersistenceStorage: MetricPersistenceStorage {
    private var fileManager: FileManager
    private let fileName = "custom_metrics.json"
    private let userDefaults: UserDefaults
    private let syncTimeStampKey = "lastSyncedTimestamp"

    private var fileURL: URL? {
        let baseURL = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard let metricDir = baseURL?.appendingPathComponent("MetricsSDK", isDirectory: true) else { return nil }

        if !fileManager.fileExists(atPath: metricDir.path) {
            try? fileManager.createDirectory(at: metricDir, withIntermediateDirectories: true)
        }

        return metricDir.appendingPathComponent(fileName)
    }

    init(
        fileManager: FileManager = FileManager.default,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    func load() -> [Metric] {
        guard let fileURL = fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }

        return (try? JSONDecoder().decode([Metric].self, from: data)) ?? []
    }

    func save(value: Metric) throws {
        var currentValues = load()
        currentValues.append(value)

        guard let data = try? JSONEncoder().encode(currentValues), let url = fileURL else { return }

        try data.write(to: url)
    }

    func clearAll() {
        guard let url = fileURL else { return }
        try? fileManager.removeItem(at: url)
    }

    func replace(values: [Metric]) throws {
        guard let data = try? JSONEncoder().encode(values), let url = fileURL else { return }
        try data.write(to: url)
    }

    func setLastSyncedTimestamp(date: Date) {
        userDefaults.set(date, forKey: syncTimeStampKey)
    }

    func lastSyncedTimestamp() -> Date? {
        userDefaults.object(forKey: syncTimeStampKey) as? Date
    }
}

protocol MetricExporter: AnyObject {
    func export()
}

final class RemoteMetricExporter: MetricExporter {
    private let httpClient: HttpClient
    private let storage: MetricPersistenceStorage

    init(httpClient: HttpClient = DefaultHttpClient(), storage: MetricPersistenceStorage = FilePersistenceStorage()) {
        self.httpClient = httpClient
        self.storage = storage
    }

    func export() {
        var allMetrics = storage.load()
        var metricsToExport = [Metric]()

        for _ in 0...100 {
            guard !allMetrics.isEmpty else { break }
            metricsToExport.append(allMetrics.removeFirst())
        }

        guard let encodedData = try? JSONEncoder().encode(metricsToExport) else { return }
        httpClient.perform(data: encodedData, to: exportURL)

        guard allMetrics.isEmpty else {
            try? storage.replace(values: allMetrics)
            return
        }
        storage.clearAll()
    }
}

protocol HttpClient: AnyObject {
    func perform(data: Data, to url: URL)
}

final class DefaultHttpClient: HttpClient {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func perform(data: Data, to url: URL) {
        print("Network Request for URL: \(url) with data: \(data)")
    }
}
