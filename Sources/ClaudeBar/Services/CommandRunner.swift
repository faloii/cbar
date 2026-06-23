import Foundation

/// Runs a user-defined shell command — used only for "auto-resume on reset".
///
/// Strictly opt-in (off by default) and user-authored: ClaudeBar never invents a
/// command. Runs through a login shell so the user's PATH resolves (`claude` is
/// usually a binary on PATH or under `~/.claude/local`); output is discarded and
/// the call doesn't block the app. The command should `cd` into its own project.
enum CommandRunner {
    static func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", trimmed]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { NSLog("ClaudeBar resume command failed: \(error)") }
    }
}

/// "Continue the previous conversation" auto-resume. Resolves the `claude` binary and
/// the most recent project directory, then continues that conversation headlessly on
/// the cheap model.
enum ResumeCommand {
    static let prompt = "계속 진행해줘"

    /// Run it SAFELY: the binary and args are passed as argv (`exec "$@"`), so a project
    /// path or binary path containing shell metacharacters can't inject; the working dir
    /// is set directly, never interpolated. The login shell (`-l`) is used only so PATH
    /// resolves — it never parses our values.
    static func runContinueLast() {
        let dir = ClaudeDataReader.lastProjectDir()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let bin = resolveClaudeBinaryPath() ?? "claude"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "exec \"$@\"", "claudebar-resume",
                          bin, "--continue", "-p", prompt, "--model", "haiku"]
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { NSLog("ClaudeBar resume failed: \(error)") }
    }

    /// Human-readable, properly-quoted shell command for the Settings preview/edit
    /// field. Only ever shown/edited by the user — the run path above does not use it.
    static func continueLastPreview() -> String {
        buildPreview(dir: ClaudeDataReader.lastProjectDir()
                        ?? FileManager.default.homeDirectoryForCurrentUser.path,
                     bin: resolveClaudeBinaryPath() ?? "claude")
    }

    static func buildPreview(dir: String, bin: String) -> String {
        "cd \(shellQuote(dir)) && \(shellQuote(bin)) --continue -p \(shellQuote(prompt)) --model haiku"
    }

    /// POSIX single-quote escaping: wrap in '…', closing/escaping/reopening any embedded
    /// single quote (`'` → `'\''`). Makes any string a single safe shell word.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Resolve the absolute `claude` path via the login shell (fixed command — no
    /// interpolation), then well-known install locations. nil if unresolved.
    static func resolveClaudeBinaryPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if p.terminationStatus == 0, let first = out.split(separator: "\n").first, first.hasPrefix("/") {
                return String(first)
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for cand in [home.appendingPathComponent(".claude/local/claude").path,
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
        }
        return nil
    }
}
