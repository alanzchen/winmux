import AppKit
import QuartzCore

// Compile separately from CPU measurements; see docs/dock-interaction-cpu-validation.md.
// Coordinates use CoreGraphics screen space (origin at the primary display's top-left).
let args = CommandLine.arguments
func usage() -> Never {
    print("Usage: dock-pointer-sweep horizontal|vertical LOW HIGH FIXED SECONDS HZ OUTPUT.json")
    exit(args.count == 2 && args[1] == "--help" ? 0 : 2)
}
guard args.count == 8, ["horizontal", "vertical"].contains(args[1]),
      let low = Double(args[2]), let high = Double(args[3]), let fixed = Double(args[4]),
      let duration = Double(args[5]), let rate = Double(args[6]),
      [low, high, fixed, duration, rate].allSatisfy(\.isFinite),
      high >= low, duration > 0, duration <= 3600, rate > 0, rate <= 1000 else { usage() }
let horizontal = args[1] == "horizontal"
let output = URL(fileURLWithPath: args[7])
do {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
    fputs("Cannot create output directory: \(error)\n", stderr)
    exit(2)
}
guard CGPreflightPostEventAccess() else { fatalError("Input permission missing") }
let source = CGEventSource(stateID: .hidSystemState)!
let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
    mouseCursorPosition: horizontal ? CGPoint(x: low, y: fixed) : CGPoint(x: fixed, y: low), mouseButton: .left)!
let started = CACurrentMediaTime()
var events = 0
var previous = event.location
var last = started
var maximumGap = 0.0
let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
timer.schedule(deadline: .now(), repeating: 1 / rate, leeway: .nanoseconds(0))
timer.setEventHandler {
    let now = CACurrentMediaTime()
    let elapsed = now - started
    if elapsed >= duration {
        timer.cancel()
        let report: [String: Any] = ["events": events, "duration": elapsed,
            "actual_hz": Double(events) / elapsed, "requested_hz": rate,
            "maximum_gap": maximumGap, "axis": args[1], "low": low, "high": high, "fixed": fixed]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        exit(0)
    }
    let value = low + (high - low) * (1 - cos(elapsed * 2 * .pi / 3)) / 2
    let point = horizontal ? CGPoint(x: value, y: fixed) : CGPoint(x: fixed, y: value)
    event.location = point
    event.timestamp = DispatchTime.now().uptimeNanoseconds
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
    event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
    event.post(tap: .cghidEventTap)
    maximumGap = max(maximumGap, now - last)
    last = now
    previous = point
    events += 1
}
timer.resume()
dispatchMain()
