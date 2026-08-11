import ApplicationServices
import CoreGraphics
import Foundation
print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
CGWarpMouseCursorPosition(p)
usleep(300_000)
print("cursor now at \(CGEvent(source: nil)?.location ?? .zero)")
