import AppKit
import ApplicationServices
import Foundation

private let returnKeyCode: CGKeyCode = 36
private let backspaceKeyCode: CGKeyCode = 51

final class SystemEnvironment: TypingEnvironment {
    private let source = CGEventSource(stateID: .privateState)
    private let lock = NSLock()
    private var isCancelled = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    private func post(keyCode: CGKeyCode, text: String? = nil) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            event.flags = []
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            // 发到会话层，避免自身按键刷新 hidSystemState 的计时
            event.post(tap: .cgSessionEventTap)
        }
    }

    func sendText(_ value: String) {
        if value == "\n" {
            post(keyCode: returnKeyCode)
        } else {
            post(keyCode: 0, text: value)
        }
    }

    func sendBackspace() {
        post(keyCode: backspaceKeyCode)
    }

    // 泵主线程 RunLoop，否则 NSWorkspace 的前台应用信息不会更新
    func sleep(ms: Int) {
        RunLoop.main.run(until: Date().addingTimeInterval(Double(ms) / 1000))
    }

    func frontmostPID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
    }

    func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

func send(_ message: [String: Any]) {
    var body = message
    body["v"] = 1
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
    try? FileHandle.standardOutput.write(contentsOf: encodeFrame(payload))
}

signal(SIGPIPE, SIG_IGN)

let input = FileHandle.standardInput
guard let firstFrame = readFrame(input) else { exit(0) }
guard let firstCommand = try? parseCommand(firstFrame) else {
    send(["event": "error", "code": "unsupported_protocol"])
    exit(1)
}
guard case .start(let startCommand) = firstCommand else { exit(0) }

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
    send(["event": "error", "code": "no_accessibility_permission"])
    exit(1)
}

let environment = SystemEnvironment()
let reader = Thread {
    while let frame = readFrame(input) {
        if (try? parseCommand(frame)) == .cancel { break }
    }
    environment.cancel()
}
reader.start()

switch runTyping(startCommand, env: environment) {
case .done:
    send(["event": "done"])
case .stopped(let reason):
    send(["event": "stopped", "reason": reason.rawValue])
}
exit(0)
