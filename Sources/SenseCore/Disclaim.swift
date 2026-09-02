import Darwin
import Foundation

// macOS attributes an unbundled CLI's TCC requests (mic, speech recognition) to
// the "responsible process" (usually the terminal). If that process cannot
// provide the usage-description strings, TCC kills us with SIGABRT. The fix,
// used by many CLI tools: re-exec ourselves with responsibility *disclaimed*
// (responsibility_spawnattrs_setdisclaim), which makes this binary its own TCC
// subject and lets the Info.plist embedded in our __TEXT,__info_plist section
// supply the usage descriptions. Permission prompts are then shown for "sense".

private typealias SetDisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

private let disclaimEnvKey = "SENSE_TCC_DISCLAIMED"

public func reexecDisclaimedIfNeeded() {
    if ProcessInfo.processInfo.environment[disclaimEnvKey] == "1" { return }
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else { return }
    let setDisclaim = unsafeBitCast(sym, to: SetDisclaimFn.self)

    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return }
    defer { posix_spawnattr_destroy(&attr) }
    guard setDisclaim(&attr, 1) == 0 else { return }

    var exePath = [CChar](repeating: 0, count: 4096)
    var size = UInt32(exePath.count)
    guard _NSGetExecutablePath(&exePath, &size) == 0 else { return }

    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    var env = ProcessInfo.processInfo.environment
    env[disclaimEnvKey] = "1"
    var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)

    var pid: pid_t = 0
    guard posix_spawn(&pid, exePath, nil, &attr, argv, envp) == 0 else { return }

    // Child owns the terminal interaction; ignore Ctrl-C here and let it decide.
    signal(SIGINT, SIG_IGN)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    if (status & 0x7f) == 0 {
        exit((status >> 8) & 0xff)   // normal exit
    }
    exit(128 + (status & 0x7f))      // killed by signal
}
