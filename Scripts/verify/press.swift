// Finds a control in the running ClaudeIsland HUD by title and presses it.
//
// Coordinate-based clicking is not usable for verification: the answer block
// moves down as sessions come and go, so a point measured from a screenshot is
// stale the moment another session starts. This walks the accessibility tree
// instead, which names what it found.
//
//   swift press.swift dump            — print the HUD's control tree
//   swift press.swift press Allow     — press the control titled "Allow"
//
// Hovering first is required: the card only exists at peek/expanded, and the
// panel ignores mouse events until the cursor is inside its interactive rect.
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dump"
let wanted = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

guard
    let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.claudeisland.hud"
    ).first
else {
    print("HUD is not running")
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func label(_ element: AXUIElement) -> String {
    for key in [
        kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXHelpAttribute,
    ] {
        if let text = attribute(element, key as String) as? String, !text.isEmpty {
            return text
        }
    }
    return ""
}

func role(_ element: AXUIElement) -> String {
    (attribute(element, kAXRoleAttribute as String) as? String) ?? "?"
}

var found: [(element: AXUIElement, role: String, label: String, depth: Int)] = []

func walk(_ element: AXUIElement, depth: Int) {
    guard depth < 40 else { return }
    found.append((element, role(element), label(element), depth))
    for child in children(element) { walk(child, depth: depth + 1) }
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)
for window in (attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
    walk(window, depth: 0)
}

if mode == "dump" {
    for entry in found where !entry.label.isEmpty || entry.role == "AXButton" {
        print(String(repeating: "  ", count: entry.depth) + "\(entry.role) \"\(entry.label)\"")
    }
    print("— \(found.count) elements")
    exit(0)
}

guard let target = found.first(where: { $0.label == wanted && $0.role == "AXButton" })
    ?? found.first(where: { $0.label == wanted })
else {
    print("no control titled \"\(wanted)\" — is the card open?")
    exit(1)
}

// AXPress is preferred over a synthetic click: it exercises the same action the
// button would run, without depending on where the card happens to be laid out.
let result = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
print("press \"\(wanted)\" -> \(result == .success ? "ok" : "failed(\(result.rawValue))")")
exit(result == .success ? 0 : 1)
