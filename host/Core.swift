import Foundation

enum Action: Equatable {
    case text(String)
    case wait(Int)
    case backspace
}

struct StartCommand: Equatable {
    let startDelayMs: Int
    let actions: [Action]
}

enum Command: Equatable {
    case start(StartCommand)
    case cancel
}

enum ProtocolError: Error {
    case unsupported
}

enum StopReason: String, Equatable {
    case appSwitched = "app_switched"
    case userInput = "user_input"
    case userCancel = "user_cancel"
}

enum RunResult: Equatable {
    case done
    case stopped(StopReason)
}

protocol TypingEnvironment {
    var cancelled: Bool { get }
    func sendText(_ value: String)
    func sendBackspace()
    func sleep(ms: Int)
    func frontmostPID() -> Int32?
    func secondsSinceUserInput() -> Double
    func now() -> Double
}

// JSONSerialization 把布尔值也解析成 NSNumber，as? Int 会把 true 当作 1
private func jsonInt(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    return raw as? Int
}

private func parseAction(_ raw: Any) throws -> Action {
    guard let object = raw as? [String: Any], let type = object["type"] as? String else {
        throw ProtocolError.unsupported
    }
    let allowedFields: [String: Set<String>] = [
        "text": ["type", "value"],
        "wait": ["type", "ms"],
        "key": ["type", "key", "modifiers"],
    ]
    guard let allowed = allowedFields[type], Set(object.keys) == allowed else {
        throw ProtocolError.unsupported
    }
    switch type {
    case "text":
        guard let value = object["value"] as? String, !value.isEmpty else {
            throw ProtocolError.unsupported
        }
        return .text(value)
    case "wait":
        guard let ms = jsonInt(object["ms"]), ms >= 0 else {
            throw ProtocolError.unsupported
        }
        return .wait(ms)
    case "key":
        guard object["key"] as? String == "backspace",
              let modifiers = object["modifiers"] as? [Any], modifiers.isEmpty else {
            throw ProtocolError.unsupported
        }
        return .backspace
    default:
        throw ProtocolError.unsupported
    }
}

func parseCommand(_ data: Data) throws -> Command {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          jsonInt(object["v"]) == 1,
          let cmd = object["cmd"] as? String else {
        throw ProtocolError.unsupported
    }
    switch cmd {
    case "cancel":
        return .cancel
    case "start":
        guard let startDelayMs = jsonInt(object["startDelayMs"]), startDelayMs >= 0,
              let rawActions = object["actions"] as? [Any] else {
            throw ProtocolError.unsupported
        }
        return .start(StartCommand(
            startDelayMs: startDelayMs,
            actions: try rawActions.map(parseAction)
        ))
    default:
        throw ProtocolError.unsupported
    }
}

func encodeFrame(_ payload: Data) -> Data {
    var length = UInt32(payload.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    return frame
}

func readFrame(_ handle: FileHandle) -> Data? {
    guard let header = readExactly(handle, count: 4) else { return nil }
    let length = header.reduce(UInt32(0)) { partial, byte in partial >> 8 | UInt32(byte) << 24 }
    return readExactly(handle, count: Int(length))
}

private func readExactly(_ handle: FileHandle, count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        guard let chunk = try? handle.read(upToCount: count - result.count), !chunk.isEmpty else {
            return nil
        }
        result.append(chunk)
    }
    return result
}

private let sliceMs = 20

func runTyping(
    _ command: StartCommand,
    env: TypingEnvironment,
    onProgress: (Int) -> Void = { _ in }
) -> RunResult {
    func sleepSlice(until deadline: Double) {
        let remaining = Int(((deadline - env.now()) * 1000).rounded(.up))
        env.sleep(ms: min(sliceMs, remaining))
    }

    let typingStart = env.now() + Double(command.startDelayMs) / 1000
    while env.now() < typingStart {
        if env.cancelled { return .stopped(.userCancel) }
        sleepSlice(until: typingStart)
    }
    if env.cancelled { return .stopped(.userCancel) }

    guard let targetPID = env.frontmostPID() else { return .stopped(.appSwitched) }
    let startedAt = env.now()
    // 按绝对时间排程，单次睡眠超时不会累积
    var deadline = startedAt

    func stopReason() -> StopReason? {
        if env.cancelled { return .userCancel }
        if env.frontmostPID() != targetPID { return .appSwitched }
        if env.secondsSinceUserInput() < env.now() - startedAt { return .userInput }
        return nil
    }

    for (index, action) in command.actions.enumerated() {
        if let reason = stopReason() { return .stopped(reason) }
        switch action {
        case .text(let value):
            env.sendText(value)
        case .backspace:
            env.sendBackspace()
        case .wait(let ms):
            deadline += Double(ms) / 1000
            while env.now() < deadline {
                sleepSlice(until: deadline)
                if let reason = stopReason() { return .stopped(reason) }
            }
        }
        onProgress(index + 1)
    }
    return .done
}
