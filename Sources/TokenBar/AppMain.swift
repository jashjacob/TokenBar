import AppKit

@main
enum TokenBarMain {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            printOnce()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--write-icon") {
            writeIcon(path: CommandLine.arguments.dropFirst(index + 1).first)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Retain.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func printOnce() {
        let group = DispatchGroup()
        let code = Wrapper(1)
        group.enter()
        Task {
            defer { group.leave() }
            do {
                async let chipsTask = LimitsClient.fetch()
                async let todayTask = LimitsClient.fetchToday()
                let chips = try await chipsTask
                if let today = try? await todayTask {
                    print(today.menuTitle)
                }
                if chips.isEmpty {
                    print("no quota windows")
                    code.value = 0
                    return
                }
                for chip in chips {
                    print(chip.menuTitle)
                }
                code.value = 0
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
            }
        }
        group.wait()
        exit(code.value)
    }

    private static func writeIcon(path: String?) {
        guard let path, !path.isEmpty else {
            fputs("usage: TokenBar --write-icon <iconset-dir>\n", stderr)
            exit(2)
        }
        do {
            try AppIcon.writeIconset(to: URL(fileURLWithPath: path, isDirectory: true))
            print("wrote \(path)")
            exit(0)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private enum Retain {
    static var delegate: AppDelegate?
}

private final class Wrapper {
    var value: Int32
    init(_ value: Int32) { self.value = value }
}
