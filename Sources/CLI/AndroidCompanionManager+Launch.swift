import Foundation

extension AndroidCompanionManager {
    /// `am instrument` arguments for the companion runner. The port is passed through as an
    /// instrumentation argument because `forwardPort` maps host `port` → device `port`: a runner
    /// that ignored it and bound its own default could never be reached on any other `--port`.
    static func instrumentArguments(port: Int) -> [String] {
        [
            "shell", "am", "instrument",
            "-w",
            "-e", "class", "com.amoo.companion.CompanionRunner",
            "-e", "port", String(port),
            "com.amoo.companion.test/androidx.test.runner.AndroidJUnitRunner"
        ]
    }

    /// One launch log per port, so concurrent companions (one per emulator) don't interleave.
    static func launchLogPath(port: Int) -> String {
        NSTemporaryDirectory() + "companion-android-launch-\(port).log"
    }
}
