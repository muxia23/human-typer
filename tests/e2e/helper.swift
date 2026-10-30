import AppKit
import Carbon

// 端到端测试辅助：切换输入法、激活应用、在硬件层模拟用户操作

let arguments = CommandLine.arguments

func currentSourceID() -> String {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func postHardware(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
}

switch arguments[1] {
case "source-get":
    print(currentSourceID())
case "source-set":
    let filter = [kTISPropertyInputSourceID as String: arguments[2]] as CFDictionary
    let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    guard let source = list.first, TISSelectInputSource(source) == noErr else { exit(1) }
    print(currentSourceID())
case "activate":
    guard let app = NSRunningApplication(processIdentifier: Int32(arguments[2])!) else { exit(1) }
    app.activate()
case "post-key":
    let source = CGEventSource(stateID: .privateState)
    // F20，没有默认功能
    postHardware(CGEvent(keyboardEventSource: source, virtualKey: 90, keyDown: true))
    postHardware(CGEvent(keyboardEventSource: source, virtualKey: 90, keyDown: false))
case "post-cmd":
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
    down?.type = .flagsChanged
    down?.flags = .maskCommand
    postHardware(down)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
    up?.type = .flagsChanged
    up?.flags = []
    postHardware(up)
case "post-click":
    let source = CGEventSource(stateID: .hidSystemState)
    let point = CGPoint(x: Double(arguments[2])!, y: Double(arguments[3])!)
    postHardware(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
    postHardware(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
default:
    exit(2)
}
