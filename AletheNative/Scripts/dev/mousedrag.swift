// Dev tool: drags between two accessibility elements of ONE app, with real mouse events.
// It looks up both elements by accessibility identifier in the given process, brings that app to
// the front, and moves the pointer in small steps (AppKit ignores drags that jump). Only use while
// the app's window is frontmost and unobstructed.
//
//   swiftc -O -o build/mousedrag Scripts/dev/mousedrag.swift
//   build/mousedrag <pid> <source identifier> <target identifier> [target dy in points]
import AppKit
import ApplicationServices

func find(_ element: AXUIElement, _ identifier: String) -> AXUIElement? {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success,
       (value as? String) == identifier { return element }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let list = children as? [AXUIElement] else { return nil }
    for child in list { if let hit = find(child, identifier) { return hit } }
    return nil
}

func center(_ element: AXUIElement) -> CGPoint {
    var position: CFTypeRef?, size: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
}

let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
guard let source = find(app, CommandLine.arguments[2]), let target = find(app, CommandLine.arguments[3]) else {
    print("element not found"); exit(1)
}
NSRunningApplication(processIdentifier: pid)?.activate()
usleep(400_000)
let from = center(source)
var to = center(target)
if CommandLine.arguments.count > 4, let dy = Double(CommandLine.arguments[4]) { to.y += dy }
func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, from); usleep(100_000)
post(.leftMouseDown, from); usleep(300_000)
for step in 1...30 {
    let t = CGFloat(step) / 30
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    usleep(20_000)
}
usleep(500_000)
post(.leftMouseUp, to)
print("dragged \(from) -> \(to)")
