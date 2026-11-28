import ClaudePetCore
import Foundation

/// On Windows a process's command line is one string; ProcessProbe.arguments splits it as the C
/// runtime does, so Claude Code's tool shell reads as it does on the Mac (BackgroundShells,
/// startedToolShell).
enum WindowsCommandLineTests {
    static func run(_ t: Harness) {
        print("\n-- Windows command lines (read as argv)")

        let line = #""C:\Program Files\Git\bin\bash.exe" -c "source /c/Users/x/.claude/shell-snapshots/snapshot-bash-1.sh 2>/dev/null || true && eval 'pwsh -File a.ps1 -Runs \"A:1\",\"B:2\"' < /dev/null && pwd -P >| /tmp/claude-1-cwd""#
        let argv = WindowsCommandLine.split(line)
        t.check("Claude Code's tool shell splits into program, -c and the script",
                argv.count == 3 && argv[0] == #"C:\Program Files\Git\bin\bash.exe"# && argv[1] == "-c")
        let joined = argv.joined(separator: " ")
        t.check("...which reads as a tool shell", ProcessProbe.isToolShell(arguments: joined))
        t.check("...whose command comes out with its quotes",
                BackgroundShells.command(fromShellArguments: joined) == #"pwsh -File a.ps1 -Runs "A:1","B:2""#)
        t.check("...and counts as the asked command's shell",
                ProcessProbe.isToolShell(arguments: joined, running: #"pwsh -File a.ps1 -Runs "A:1","B:2""#))
        t.check("an unquoted program runs to the first space",
                WindowsCommandLine.split(#"node.exe  a "b c" d"#) == ["node.exe", "a", "b c", "d"])
        t.check("backslashes are kept unless a quote follows",
                WindowsCommandLine.split(#"x C:\dir\ "a\\" "b\"c""#) == ["x", #"C:\dir\"#, #"a\"#, #"b"c"#])
        t.check("an empty quoted argument is an argument",
                WindowsCommandLine.split(#"x "" y"#) == ["x", "", "y"])
        t.check("\"\" inside quotes is a quote", WindowsCommandLine.split(#"x "a""b""#) == ["x", #"a"b"#])
        t.check("an empty line is no arguments", WindowsCommandLine.split("").isEmpty)
    }
}
