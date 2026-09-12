import SwiftUI

extension View {
    @ViewBuilder
    func measureLayout(_ name: String) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--measure-layout") {
            self.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                LayoutMeasurement.shared.record(name, frame: frame)
            }
        } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
final class LayoutMeasurement {
    static let shared = LayoutMeasurement()
    private var frames: [String: [String: Double]] = [:]
    private var pending: Task<Void, Never>?
    func record(_ name: String, frame: CGRect) {
        frames[name] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let output = URL.documentsDirectory.appending(path: "layout-measurements.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(frames) { try? data.write(to: output, options: .atomic) }
        }
    }
}
#endif

#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// DEBUG-only display-cadence recorder for turning animation phases into JSON.
///
/// This probe intentionally has no overlay and does not attribute CPU or GPU
/// cost. Tag semantic stages from the feature under test, then correlate the
/// exported cadence with same-build A/B runs and platform profiling tools.
@MainActor
final class MotionPerformanceProbe: NSObject {
    static let shared = MotionPerformanceProbe()

    struct Configuration: Sendable {
        var maximumFrameSamples = 20_000
        var hitchMultiplier = 1.5
        var outputDirectoryName = "MotionPerformanceProbes"

        init(
            maximumFrameSamples: Int = 20_000,
            hitchMultiplier: Double = 1.5,
            outputDirectoryName: String = "MotionPerformanceProbes"
        ) {
            self.maximumFrameSamples = max(1, maximumFrameSamples)
            self.hitchMultiplier = max(1, hitchMultiplier)
            self.outputDirectoryName = outputDirectoryName
        }
    }

    struct FrameSample: Codable, Sendable {
        let elapsedMilliseconds: Double
        let intervalMilliseconds: Double
        let budgetMilliseconds: Double
        let estimatedMissedFrames: Int
        let isHitch: Bool
        let stage: String
    }

    struct Mark: Codable, Sendable {
        let elapsedMilliseconds: Double
        let name: String
        let stage: String
    }

    struct DeviceContext: Codable, Sendable {
        let model: String
        let systemName: String
        let systemVersion: String
        let maximumFramesPerSecond: Int
        let bundleIdentifier: String
        let appVersion: String
        let buildNumber: String
    }

    struct Session: Codable, Sendable {
        let schemaVersion: Int
        let sessionName: String
        let startedAt: Date
        let stoppedAt: Date
        let metadata: [String: String]
        let device: DeviceContext
        let droppedFrameSamples: Int
        let frames: [FrameSample]
        let marks: [Mark]
    }

    private var configuration = Configuration()
    private var displayLink: CADisplayLink?
    private var observerTokens: [NSObjectProtocol] = []
    private var sessionName = "motion"
    private var metadata: [String: String] = [:]
    private var startedAt = Date()
    private var startUptime: TimeInterval = 0
    private var lastFrameTimestamp: CFTimeInterval?
    private var currentStage = "unlabeled"
    private var frames: [FrameSample] = []
    private var marks: [Mark] = []
    private var droppedFrameSamples = 0
    private weak var windowScene: UIWindowScene?

    private override init() {
        super.init()
    }

    var isRunning: Bool {
        displayLink != nil
    }

    func start(
        sessionName: String,
        metadata: [String: String] = [:],
        windowScene: UIWindowScene? = nil,
        configuration: Configuration = Configuration()
    ) {
        stopWithoutWriting()

        self.configuration = configuration
        self.sessionName = sessionName.isEmpty ? "motion" : sessionName
        self.metadata = metadata
        self.windowScene = windowScene
        startedAt = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        lastFrameTimestamp = nil
        currentStage = "unlabeled"
        frames.removeAll(keepingCapacity: true)
        marks.removeAll(keepingCapacity: true)
        droppedFrameSamples = 0

        installLifecycleObservers()
        let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        mark("probe-started")
    }

    func setStage(_ name: String) {
        guard isRunning else { return }
        let next = name.isEmpty ? "unlabeled" : name
        guard next != currentStage else { return }
        currentStage = next
        mark("stage-changed")
    }

    func mark(_ name: String) {
        guard isRunning else { return }
        marks.append(
            Mark(
                elapsedMilliseconds: elapsedMilliseconds(),
                name: name,
                stage: currentStage
            )
        )
    }

    /// Stops sampling, snapshots the session, and writes JSON off the main actor.
    @discardableResult
    func stopAndWrite(to suppliedURL: URL? = nil) async throws -> URL {
        let stoppedAt = Date()
        let device = currentDeviceContext()
        let snapshot = Session(
            schemaVersion: 1,
            sessionName: sessionName,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            metadata: metadata,
            device: device,
            droppedFrameSamples: droppedFrameSamples,
            frames: frames,
            marks: marks
        )
        let outputURL = try suppliedURL ?? defaultOutputURL()
        stopWithoutWriting()

        return try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            return outputURL
        }.value
    }

    func stopWithoutWriting() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = nil
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
    }

    @objc
    private func displayLinkDidFire(_ link: CADisplayLink) {
        defer { lastFrameTimestamp = link.timestamp }
        guard let previous = lastFrameTimestamp else { return }

        let interval = max(0, link.timestamp - previous)
        guard interval > 0 else { return }
        let reportedBudget = link.targetTimestamp - link.timestamp
        let preferredRate = link.preferredFramesPerSecond
        let fallbackBudget = link.duration > 0
            ? link.duration
            : 1 / Double(
                max(
                    preferredRate,
                    max(currentMaximumFramesPerSecond(), 60)
                )
            )
        let budget = reportedBudget > 0 ? reportedBudget : fallbackBudget
        let ratio = interval / max(budget, 0.000_001)
        let missedFrames = max(0, Int(ratio.rounded(.down)) - 1)
        let isHitch = ratio > configuration.hitchMultiplier

        guard frames.count < configuration.maximumFrameSamples else {
            droppedFrameSamples += 1
            return
        }
        frames.append(
            FrameSample(
                elapsedMilliseconds: elapsedMilliseconds(),
                intervalMilliseconds: interval * 1_000,
                budgetMilliseconds: budget * 1_000,
                estimatedMissedFrames: missedFrames,
                isHitch: isHitch,
                stage: currentStage
            )
        )
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.mark("application-will-resign-active")
                    self?.lastFrameTimestamp = nil
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastFrameTimestamp = nil
                    self?.mark("application-did-become-active")
                }
            },
        ]
    }

    private func elapsedMilliseconds() -> Double {
        (ProcessInfo.processInfo.systemUptime - startUptime) * 1_000
    }

    private func currentDeviceContext() -> DeviceContext {
        let bundle = Bundle.main
        return DeviceContext(
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            maximumFramesPerSecond: currentMaximumFramesPerSecond(),
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "unknown"
        )
    }

    private func currentMaximumFramesPerSecond() -> Int {
        if let screen = windowScene?.screen {
            return screen.maximumFramesPerSecond
        }
        let activeScreen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                lhs.activationState == .foregroundActive
                    && rhs.activationState != .foregroundActive
            }
            .first?
            .screen
        return activeScreen?.maximumFramesPerSecond ?? 60
    }

    private func defaultOutputURL() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let safeName = sessionName.replacingOccurrences(
            of: "[^A-Za-z0-9_-]+",
            with: "-",
            options: .regularExpression
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return documents
            .appendingPathComponent(configuration.outputDirectoryName, isDirectory: true)
            .appendingPathComponent("\(safeName)-\(timestamp).json")
    }
}
#endif
