import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 3,
      let pid = pid_t(CommandLine.arguments[1]) else { exit(64) }
let appURL = URL(fileURLWithPath: CommandLine.arguments[2])
let deadline = Date().addingTimeInterval(10)
while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
let semaphore = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in semaphore.signal() }
_ = semaphore.wait(timeout: .now() + 10)
