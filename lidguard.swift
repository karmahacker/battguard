// lidguard: when the lid of a Mac that runs in closed-lid mode (`pmset -a
// disablesleep 1`) is closed, put the built-in display to sleep instead of
// leaving it lit until the displaysleep timer (180 min on AC here) expires.
//
//   lidguard              watch the lid forever (what launchd runs)
//   lidguard --dry-run    same, but only log what it would do
//   lidguard --status     print lid / display state and exit
//   lidguard --selftest   run the decision logic through scripted events
//
// How: the kernel posts kIOPMMessageClamshellStateChange on every lid change.
// SETTLE s after a close, `pmset displaysleepnow` turns the display off (what
// the idle timer would eventually do). Opening the lid wakes it again (the
// kernel does that; we also declare user activity to be sure). If the display
// wakes while the lid is still closed (USB device, Bluetooth, ...), it is put
// back to sleep RESLEEP s later, at most MAX_RESLEEPS times per closed period,
// so a wrong lid reading can never fight the user for the screen. With an
// external display attached (clamshell mode) nothing is touched.
//
// Environment: LIDGUARD_SETTLE (1.5 s), LIDGUARD_RESLEEP (5 s),
// LIDGUARD_MAX_RESLEEPS (10), LIDGUARD_LOG (~/Library/Logs/lidguard.log)

import Foundation
import IOKit
import IOKit.pwr_mgt
import CoreGraphics
import AppKit

func envDouble(_ key: String, _ dflt: Double) -> Double {
    Double(ProcessInfo.processInfo.environment[key] ?? "") ?? dflt
}
let SETTLE = envDouble("LIDGUARD_SETTLE", 1.5)
let RESLEEP = envDouble("LIDGUARD_RESLEEP", 5)
let MAX_RESLEEPS = Int(envDouble("LIDGUARD_MAX_RESLEEPS", 10))
let LOG_PATH = ProcessInfo.processInfo.environment["LIDGUARD_LOG"] ?? (NSHomeDirectory() + "/Library/Logs/lidguard.log")
// kIOPMMessageClamshellStateChange from IOKit/pwr_mgt/IOPM.h; bit 0 of the argument = lid closed.
let kClamshellMsg: UInt32 = 0xe0034100

// MARK: - decisions (pure; exercised by --selftest)

enum Event {
    case start(lidClosed: Bool)
    case lid(closed: Bool)
    case screensWoke
    case timerFired(lidClosed: Bool)
}

enum Action: Equatable {
    case scheduleSleep(Double)   // run the display-sleep timer in N s (replaces a pending one)
    case cancelTimer
    case sleepDisplay
    case wakeDisplay
    case note(String)
}

struct Policy {
    var lidClosed = false
    var timerPending = false
    var resleeps = 0

    mutating func handle(_ event: Event, externalDisplay: Bool) -> [Action] {
        switch event {
        case .start(let closed):
            lidClosed = closed
            return closed ? onClosed(externalDisplay, what: "started with the lid closed") : []
        case .lid(closed: true):
            lidClosed = true
            resleeps = 0
            return onClosed(externalDisplay, what: "lid closed")
        case .lid(closed: false):
            lidClosed = false
            resleeps = 0
            var actions: [Action] = []
            if timerPending { actions.append(.cancelTimer); timerPending = false }
            actions += [.wakeDisplay, .note("lid opened: display woken")]
            return actions
        case .screensWoke:
            guard lidClosed, !externalDisplay, !timerPending else { return [] }
            if resleeps >= MAX_RESLEEPS {
                resleeps += 1
                return resleeps == MAX_RESLEEPS + 1
                    ? [.note("display woke again with the lid closed; giving up after \(MAX_RESLEEPS) re-sleeps until the lid is opened")]
                    : []
            }
            resleeps += 1
            timerPending = true
            return [.note("display woke while the lid is closed (\(resleeps)/\(MAX_RESLEEPS)): sleeping it again in \(RESLEEP) s"),
                    .scheduleSleep(RESLEEP)]
        case .timerFired(let closed):
            timerPending = false
            lidClosed = closed
            if !closed { return [.note("lid opened meanwhile: display left on")] }
            if externalDisplay { return [.note("external display attached: display left on")] }
            return [.sleepDisplay]
        }
    }

    private mutating func onClosed(_ externalDisplay: Bool, what: String) -> [Action] {
        if externalDisplay { return [.note("\(what), external display attached: leaving the displays alone")] }
        timerPending = true
        return [.note("\(what): display sleep in \(SETTLE) s"), .scheduleSleep(SETTLE)]
    }
}

// MARK: - system access

func lidClosedNow() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    guard let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    else { return false }
    if let b = v as? Bool { return b }
    if let i = v as? Int { return i != 0 }
    return false
}

func externalDisplayAttached() -> Bool {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
}

func displayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

// Fixed Gregorian calendar and POSIX locale, so the log year does not follow a non-Gregorian user locale.
let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()
func logLine(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(s)\n"
    if isatty(1) != 0 { print(line, terminator: ""); fflush(stdout) }
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: LOG_PATH)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: url)
    }
}

final class Runtime {
    var policy = Policy()
    var timer: DispatchWorkItem?
    let dryRun: Bool
    init(dryRun: Bool) { self.dryRun = dryRun }

    func handle(_ event: Event) {
        for action in policy.handle(event, externalDisplay: externalDisplayAttached()) { perform(action) }
    }

    func perform(_ action: Action) {
        switch action {
        case .note(let s):
            logLine(s)
        case .cancelTimer:
            timer?.cancel(); timer = nil
        case .scheduleSleep(let delay):
            timer?.cancel()
            let item = DispatchWorkItem { [self] in
                timer = nil
                handle(.timerFired(lidClosed: lidClosedNow()))
            }
            timer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        case .sleepDisplay:
            if dryRun { logLine("DRY RUN: would run pmset displaysleepnow"); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            do {
                try p.run(); p.waitUntilExit()
                logLine(p.terminationStatus == 0 ? "display put to sleep (pmset displaysleepnow)"
                                                 : "pmset displaysleepnow failed with exit \(p.terminationStatus)")
            } catch {
                logLine("could not run pmset: \(error)")
            }
        case .wakeDisplay:
            if dryRun { logLine("DRY RUN: would declare user activity"); return }
            var id: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("lidguard: lid opened" as CFString, kIOPMUserActiveLocal, &id)
        }
    }
}

// MARK: - self-test of the decision logic

func selftest() -> Int32 {
    var fails = 0, passes = 0
    func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want { print("PASS  \(name)"); passes += 1 }
        else { print("FAIL  \(name)\n      got:  \(got)\n      want: \(want)"); fails += 1 }
    }
    // Notes are free text; compare the other actions only.
    func acts(_ a: [Action]) -> [Action] { a.filter { if case .note = $0 { return false }; return true } }
    let ext = true, noExt = false

    var p = Policy()
    check("start with lid open: nothing", p.handle(.start(lidClosed: false), externalDisplay: noExt), [])
    check("lid closes: display sleep scheduled", acts(p.handle(.lid(closed: true), externalDisplay: noExt)), [.scheduleSleep(SETTLE)])
    check("timer fires, still closed: display sleeps", acts(p.handle(.timerFired(lidClosed: true), externalDisplay: noExt)), [.sleepDisplay])
    check("display wakes while closed: re-sleep scheduled", acts(p.handle(.screensWoke, externalDisplay: noExt)), [.scheduleSleep(RESLEEP)])
    check("another wake while the timer is pending: ignored", p.handle(.screensWoke, externalDisplay: noExt), [])
    check("re-sleep timer fires: display sleeps", acts(p.handle(.timerFired(lidClosed: true), externalDisplay: noExt)), [.sleepDisplay])
    check("lid opens: display woken", acts(p.handle(.lid(closed: false), externalDisplay: noExt)), [.wakeDisplay])
    check("display wakes with the lid open: ignored", p.handle(.screensWoke, externalDisplay: noExt), [])

    _ = p.handle(.lid(closed: true), externalDisplay: noExt)
    check("reopened before the timer: timer cancelled, display woken", acts(p.handle(.lid(closed: false), externalDisplay: noExt)), [.cancelTimer, .wakeDisplay])
    check("stale timer with the lid open: no sleep", acts(p.handle(.timerFired(lidClosed: false), externalDisplay: noExt)), [])

    var q = Policy()
    check("lid closes with an external display: nothing scheduled", acts(q.handle(.lid(closed: true), externalDisplay: ext)), [])
    check("display wakes, external display: ignored", q.handle(.screensWoke, externalDisplay: ext), [])

    var r = Policy()
    _ = r.handle(.lid(closed: true), externalDisplay: noExt)
    check("external display attached before the timer fires: no sleep", acts(r.handle(.timerFired(lidClosed: true), externalDisplay: ext)), [])

    var s = Policy()
    _ = s.handle(.lid(closed: true), externalDisplay: noExt)
    _ = s.handle(.timerFired(lidClosed: true), externalDisplay: noExt)
    var resleeps = 0, giveUpNotes = 0
    for _ in 0..<(MAX_RESLEEPS + 3) {
        let out = s.handle(.screensWoke, externalDisplay: noExt)
        if acts(out) == [.scheduleSleep(RESLEEP)] { resleeps += 1; _ = s.handle(.timerFired(lidClosed: true), externalDisplay: noExt) }
        else if !out.isEmpty { giveUpNotes += 1 }
    }
    check("re-sleeps capped at MAX_RESLEEPS per closed period", resleeps, MAX_RESLEEPS)
    check("giving-up note logged once", giveUpNotes, 1)
    check("lid opens after the cap: display woken", acts(s.handle(.lid(closed: false), externalDisplay: noExt)), [.wakeDisplay])
    _ = s.handle(.lid(closed: true), externalDisplay: noExt)
    _ = s.handle(.timerFired(lidClosed: true), externalDisplay: noExt)
    check("cap reset by reopening: re-sleep works again", acts(s.handle(.screensWoke, externalDisplay: noExt)), [.scheduleSleep(RESLEEP)])

    var t = Policy()
    check("started with the lid already closed: sleep scheduled", acts(t.handle(.start(lidClosed: true), externalDisplay: noExt)), [.scheduleSleep(SETTLE)])

    print(fails == 0 ? "lidguard selftest: all \(passes) passed" : "lidguard selftest: \(fails) FAILED, \(passes) passed")
    return fails == 0 ? 0 : 1
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--selftest") { exit(selftest()) }
if args.contains("--status") {
    print("lid              : \(lidClosedNow() ? "closed" : "open")")
    print("display          : \(displayAsleep() ? "asleep" : "on")")
    print("external display : \(externalDisplayAttached() ? "yes (lidguard leaves the displays alone)" : "no")")
    print("sleep after      : \(SETTLE) s past lid close; re-sleep after \(RESLEEP) s, max \(MAX_RESLEEPS) per close")
    print("log              : \(LOG_PATH)")
    exit(0)
}
if let bad = args.first(where: { $0 != "--dry-run" }) {
    FileHandle.standardError.write("lidguard: unknown argument \(bad)\nusage: lidguard [--dry-run | --status | --selftest]\n".data(using: .utf8)!)
    exit(2)
}

let runtime = Runtime(dryRun: args.contains("--dry-run"))
let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
    logLine("cannot reach IOPMrootDomain; exiting"); exit(1)
}
var notifier: io_object_t = 0
let kr = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { _, _, msg, arg in
    guard msg == kClamshellMsg else { return }
    runtime.handle(.lid(closed: UInt(bitPattern: arg) & 1 == 1))
}, nil, &notifier)
guard kr == KERN_SUCCESS else { logLine("IOServiceAddInterestNotification failed: \(kr); exiting"); exit(1) }
CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
    runtime.handle(.screensWoke)
}
logLine("lidguard started\(runtime.dryRun ? " (dry run)" : ""): lid \(lidClosedNow() ? "closed" : "open"), settle \(SETTLE) s, re-sleep \(RESLEEP) s up to \(MAX_RESLEEPS)x")
runtime.handle(.start(lidClosed: lidClosedNow()))
CFRunLoopRun()
