import os

/// Both targets log to the same subsystem so a single predicate shows the whole
/// conversation between the app and its helper:
///
///     /usr/bin/log show --last 10m \
///       --predicate 'subsystem == "ai.pakslab.keep-mac-awake"'
///
/// Use the absolute path: `log` is a shell builtin/function in some setups and
/// the query silently returns nothing, which reads as "there are no logs".
///
/// Levels matter too — `.info` is not persisted, so anything worth reading back
/// during diagnosis is logged at `.notice`, with `privacy: .public` on values
/// (os_log redacts interpolated variables by default).
enum Log {
    private static let subsystem = "ai.pakslab.keep-mac-awake"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let helper = Logger(subsystem: subsystem, category: "helper")
}
