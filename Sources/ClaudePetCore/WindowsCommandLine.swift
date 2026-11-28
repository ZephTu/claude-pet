import Foundation

/// A Windows command line split into arguments, as the C runtime splits it (CommandLineToArgvW
/// without linking shell32). Used on Windows to read a process's command line the way the Mac
/// reads argv (ProcessProbe.arguments); pure, so it is tested on the Mac too.
public enum WindowsCommandLine {
    /// The program name runs to the next quote if it starts with one, else to the first space or
    /// tab. After it, spaces and tabs outside quotes separate arguments; 2n backslashes before a
    /// quote are n backslashes and the quote opens or closes; 2n+1 are n and a literal quote;
    /// `""` inside quotes is a literal quote (the UCRT's rule); backslashes before anything else
    /// stay as they are.
    public static func split(_ line: String) -> [String] {
        let chars = Array(line.unicodeScalars)
        let quote: Unicode.Scalar = "\"", backslash: Unicode.Scalar = "\\"
        func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
        guard !chars.isEmpty else { return [] }
        var args: [String] = []
        var i = 0
        var program = String.UnicodeScalarView()
        if chars[0] == quote {
            i = 1
            while i < chars.count, chars[i] != quote { program.append(chars[i]); i += 1 }
            i += 1
        } else {
            while i < chars.count, !isBlank(chars[i]) { program.append(chars[i]); i += 1 }
        }
        args.append(String(program))
        var current = String.UnicodeScalarView()
        var started = false
        var quoted = false
        var backslashes = 0
        func flushBackslashes(_ n: Int) {
            for _ in 0..<n { current.append(backslash) }
        }
        while i < chars.count {
            let c = chars[i]
            if c == backslash {
                backslashes += 1
            } else if c == quote {
                flushBackslashes(backslashes / 2)
                if backslashes % 2 == 1 {
                    current.append(quote)
                } else if quoted, i + 1 < chars.count, chars[i + 1] == quote {
                    current.append(quote)
                    i += 1
                } else {
                    quoted.toggle()
                }
                backslashes = 0
                started = true
            } else {
                if backslashes > 0 { started = true }
                flushBackslashes(backslashes)
                backslashes = 0
                if isBlank(c), !quoted {
                    if started { args.append(String(current)) }
                    current = String.UnicodeScalarView()
                    started = false
                } else {
                    current.append(c)
                    started = true
                }
            }
            i += 1
        }
        flushBackslashes(backslashes)
        if started || backslashes > 0 { args.append(String(current)) }
        return args
    }
}
