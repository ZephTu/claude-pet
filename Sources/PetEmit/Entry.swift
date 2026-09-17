import Foundation

/// pet-emit: the only part of Claude Pet that runs inside the user's Claude Code
/// sessions, plus the settings.json patcher used at install time.
///
/// Written in Swift rather than shell+python on purpose: a shared binary has no
/// external dependencies, so the pet works on a machine with no Xcode Command
/// Line Tools installed.
@main
struct Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--patch-settings", "--unpatch-settings":
            guard arguments.count == 2 else {
                FileHandle.standardError.write(Data("usage: pet-emit \(arguments[0]) <path to settings.json>\n".utf8))
                exit(2)
            }
            let adding = arguments[0] == "--patch-settings"
            exit(SettingsPatch.run(path: arguments[1], adding: adding))

        case "--statusline":
            // Sit in front of the user's own statusline command, capture the
            // quota numbers, and get out of the way.
            //
            // The contract is that this is INVISIBLE when it goes wrong: the
            // input is passed through byte for byte, the wrapped command's
            // output and exit code are forwarded unchanged, and a parse failure
            // costs a quota reading and nothing else. A statusline that breaks
            // because of a desktop toy is not a trade anyone agreed to.
            let input = FileHandle.standardInput.readDataToEndOfFile()
            StatuslineCapture.record(input)
            exit(StatuslineCapture.forward(input, to: Array(arguments.dropFirst())))

        case "--version":
            print(petVersion)
            exit(0)

        default:
            // No arguments: act as the hook. Read the payload and never fail —
            // any error here must not break the user's Claude Code session.
            let payload = FileHandle.standardInput.readDataToEndOfFile()
            HookEmit.run(payload: payload)
            exit(0)
        }
    }
}

let petVersion = "0.1.0"
