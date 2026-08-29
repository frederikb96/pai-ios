#if DEBUG

    import Foundation

    /// Reads the launch arguments that drive the fixture screenshot workflow.
    ///
    /// `xcrun simctl launch <bundle> <args...>` appends its trailing arguments to the process's
    /// own `argv`, so they show up in `ProcessInfo.arguments` exactly as passed — no Xcode
    /// scheme, no `UserDefaults` argument-domain magic, just the array every launch already has.
    /// Parsing that array directly (rather than the `-Key value` → `UserDefaults` convention)
    /// keeps this testable with a plain `[String]` and keeps it working identically on Linux,
    /// where `UserDefaults` does not exist.
    public enum PaiFixtureLaunch {

        static let modeFlag = "-PaiFixtureMode"
        static let routeFlag = "-PaiFixtureRoute"

        /// The session id every session-scoped fixture route answers under, regardless of which
        /// id the request actually named — fixed so a screenshot workflow can always ask for this
        /// one id without first discovering which session fixture mode decided to use.
        public static let sessionID = "305df4d3-1554-4fc3-be04-39a354a9e619"

        /// Whether the process was launched with `-PaiFixtureMode`.
        public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(modeFlag)
        }

        /// The screen name passed via `-PaiFixtureRoute <name>`, if any. Absent means "start on
        /// the root screen" — the session list needs no route to reach.
        public static func requestedRouteName(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            value(for: routeFlag, in: arguments)
        }

        static func value(for flag: String, in arguments: [String]) -> String? {
            guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
            let valueIndex = arguments.index(after: flagIndex)
            guard valueIndex < arguments.count else { return nil }
            return arguments[valueIndex]
        }
    }

#endif
