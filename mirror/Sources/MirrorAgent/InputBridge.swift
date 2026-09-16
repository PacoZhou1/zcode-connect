import Foundation
import CoreGraphics
import AppKit

/// Maps normalized viewer coordinates into the captured Simulator window's
/// content area and synthesizes clicks. The mapped point is clamped strictly
/// inside the simulator content rect — this bridge can never touch anything
/// else on the Mac. The Simulator app is activated first so the window can
/// receive the synthetic click.
final class InputBridge: @unchecked Sendable {
    private func activateAndBounds(windowID: UInt32?, engine: CaptureEngine) throws -> CGRect {
        let bundle = engine.currentContentBundle()
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate()
        }
        usleep(120_000)  // let the activation settle before reading window geometry
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let windowID,
              let entry = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32 ?? 0) == windowID }),
              let frame = entry[kCGWindowBounds as String] as? [String: Double],
              let minX = frame["X"], let minY = frame["Y"], let width = frame["Width"], let height = frame["Height"] else {
            throw MirrorError("模拟器窗口当前不可见，无法映射点击。")
        }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func contentPoint(nx: Double, ny: Double, windowID: UInt32?, engine: CaptureEngine) throws -> CGPoint {
        let bounds = try activateAndBounds(windowID: windowID, engine: engine)
        let content = engine.contentRectInWindowPoints()
        let contentWidth = max(1, content.width), contentHeight = max(1, content.height)
        let x = bounds.minX + content.minX + min(max(nx, 0), 1) * contentWidth
        let y = bounds.minY + content.minY + min(max(ny, 0), 1) * contentHeight
        return CGPoint(x: x, y: y)
    }

    private func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

    func tap(nx: Double, ny: Double, windowID: UInt32?, engine: CaptureEngine) {
        Thread.detachNewThread {
            do {
                let point = try self.contentPoint(nx: nx, ny: ny, windowID: windowID, engine: engine)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
                usleep(30_000)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
                usleep(60_000)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
            } catch { NSLog("mirror tap: \(error.localizedDescription)") }
        }
    }

    func longPress(nx: Double, ny: Double, seconds: Double, windowID: UInt32?, engine: CaptureEngine) {
        Thread.detachNewThread {
            do {
                let point = try self.contentPoint(nx: nx, ny: ny, windowID: windowID, engine: engine)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
                usleep(30_000)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
                usleep(UInt32(min(max(seconds, 0.2), 3) * 1_000_000))
                self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
            } catch { NSLog("mirror longpress: \(error.localizedDescription)") }
        }
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, windowID: UInt32?, engine: CaptureEngine) {
        Thread.detachNewThread {
            do {
                let start = try self.contentPoint(nx: fromX, ny: fromY, windowID: windowID, engine: engine)
                let end = try self.contentPoint(nx: toX, ny: toY, windowID: windowID, engine: engine)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left))
                usleep(30_000)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
                usleep(40_000)
                let steps = 24
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
                    usleep(16_000)
                }
                usleep(60_000)
                self.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
            } catch { NSLog("mirror swipe: \(error.localizedDescription)") }
        }
    }

    func type(text: String, windowID: UInt32?, engine: CaptureEngine) {
        Thread.detachNewThread {
            do {
                _ = try self.activateAndBounds(windowID: windowID, engine: engine)
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
                self.post(down)
                usleep(20_000)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                self.post(up)
            } catch { NSLog("mirror type: \(error.localizedDescription)") }
        }
    }

    func pressReturn(windowID: UInt32?, engine: CaptureEngine) {
        Thread.detachNewThread {
            do {
                _ = try self.activateAndBounds(windowID: windowID, engine: engine)
                for down in [true, false] {
                    self.post(CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: down))
                    usleep(20_000)
                }
            } catch { NSLog("mirror return: \(error.localizedDescription)") }
        }
    }
}
