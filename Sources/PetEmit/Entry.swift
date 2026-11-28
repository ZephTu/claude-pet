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

        case "--run-job":
            // One run of a scheduled job — see JobRunner. Started by the job's LaunchAgent,
            // or by the board's "Run now" with --manual.
            guard arguments.count >= 2 else {
                FileHandle.standardError.write(Data("usage: pet-emit --run-job <id> [--manual | --trigger WORD] [--prompt-file PATH]\n".utf8))
                exit(2)
            }
            let rest = Array(arguments.dropFirst(2))
            func value(_ flag: String) -> String? {
                rest.firstIndex(of: flag).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
            }
            let trigger = value("--trigger") ?? (rest.contains("--manual") ? "manual" : "schedule")
            #if os(Windows)
            _ = trigger
            FileHandle.standardError.write(Data("pet-emit: scheduled jobs are not supported on Windows yet\n".utf8))
            exit(2)
            #else
            exit(JobRunner.run(id: arguments[1], trigger: trigger, promptFile: value("--prompt-file")))
            #endif

        case "--watch":
            // The pet's state as JSON lines, for a shell other than the Mac app (PetWatch).
            PetWatch.run()

        case "--decide":
            guard arguments.count == 4 else {
                FileHandle.standardError.write(Data("usage: pet-emit --decide <session> <ask> allow|deny\n".utf8))
                exit(2)
            }
            exit(PetWatch.decide(session: arguments[1], ask: arguments[2], behavior: arguments[3]))

        case "--jump":
            // Bring a session's terminal tab to the front: the Windows shell's row click
            // (WindowsJump). The Mac app jumps on its own (TerminalJump).
            guard arguments.count == 2 else {
                FileHandle.standardError.write(Data("usage: pet-emit --jump <session>\n".utf8))
                exit(2)
            }
            #if os(Windows)
            exit(WindowsJump.run(session: arguments[1]))
            #else
            FileHandle.standardError.write(Data("pet-emit: --jump is for Windows; the Mac app jumps itself\n".utf8))
            exit(2)
            #endif

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
