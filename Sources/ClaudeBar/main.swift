import Foundation

// `ClaudeBar --print` (alias `--once`) dumps the current usage snapshot as text
// and exits — handy for scripts, CI, or a quick check without the GUI.
// Anything else launches the menu-bar app.
let args = CommandLine.arguments
if args.contains("--print") || args.contains("--once") {
    CLI.printSnapshot(json: args.contains("--json"))
} else if args.contains("--help") || args.contains("-h") {
    CLI.printHelp()
} else {
    ClaudeBarApp.main()
}
