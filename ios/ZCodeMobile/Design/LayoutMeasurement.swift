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
