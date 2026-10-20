import AppKit
import Foundation

@main
@MainActor
enum PortsApplication {
    static func main() {
        if ProcessInfo.processInfo.environment["PORTS_ASKPASS_ID"] != nil {
            exit(Askpass.run(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments))
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
