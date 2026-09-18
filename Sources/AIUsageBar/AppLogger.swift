import os

enum AppLog {
    static let subsystem = "com.silfoxs.AIUsageBar"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let usage = Logger(subsystem: subsystem, category: "usage")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
