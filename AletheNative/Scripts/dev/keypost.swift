// Dev tool: posts real keyboard events (CGEvent.postToPid) to ONE process — never to whatever
// window has focus. Used to drive the app where synthetic NSEvents are not faithful (dead keys,
// key equivalents).
//
//   swiftc -O -o build/keypost Scripts/dev/keypost.swift
//   build/keypost <pid> <keycode[:shift|:opt|:cmd|:ctrl]>... "t=<ascii text>"
import CoreGraphics
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let source = CGEventSource(stateID: .hidSystemState)
// US-layout key codes for typing plain ASCII with "t=<text>" (avoid dead-key characters ' " ` ~ ^).
let us: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let base: [(Character, CGKeyCode)] = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),("b",11),("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),("=",24),("9",25),("7",26),("-",27),("8",28),("0",29),("o",31),("u",32),("i",34),("p",35),("l",37),("j",38),("k",40),(";",41),(",",43),("/",44),("n",45),("m",46),(".",47),(" ",49)]
    for (c, k) in base { m[c] = (k, false); if c.isLetter { m[Character(c.uppercased())] = (k, true) } }
    for (c, k) in [(":",41),("_",27),(">",47),("<",43),("?",44),("|",42),("!",18),("$",21),("*",28)] as [(Character, CGKeyCode)] { m[c] = (k, true) }
    return m
}()
var specs: [String] = []
for arg in CommandLine.arguments.dropFirst(2) {
    if arg.hasPrefix("t=") {
        for c in arg.dropFirst(2) { if let (k, shift) = us[c] { specs.append(shift ? "\(k):shift" : "\(k)") } }
    } else { specs.append(arg) }
}
for spec in specs {
    let parts = spec.split(separator: ":")
    let code = CGKeyCode(parts[0])!
    var flags: CGEventFlags = []
    for m in parts.dropFirst() {
        switch m { case "shift": flags.insert(.maskShift); case "opt": flags.insert(.maskAlternate)
        case "cmd": flags.insert(.maskCommand); case "ctrl": flags.insert(.maskControl); default: break }
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.postToPid(pid)
        usleep(30_000)
    }
}
