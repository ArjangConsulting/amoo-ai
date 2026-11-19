import AmooCore
import AmooLogging
import MCP

private let logger = AmooLogger.forType(BlockingSystemDialog.self)

/// A system dialog holding the foreground, such as Android's "<app> isn't responding".
///
/// Android draws its ANR and crash dialogs in the `android` package, so a launch that met one
/// reported only "frontmost app is android", and finding the cause took a screenshot and a query.
struct BlockingSystemDialog: Equatable {
    var title: String
    /// `id: label` of each button, such as `aerr_wait: Wait`.
    var actions: [String]

    /// Android's own package, frontmost while one of its dialogs is up.
    static let androidSystemPackage = "android"
    /// The amoo companion's app, frontmost when its instrumentation has stopped.
    static let companionPackages: Set<String> = ["com.amoo.companion", "com.amoo.companion.test"]

    /// The dialog among `elements`, recognised by the framework's `alertTitle` and `aerr_*` buttons.
    static func find(in elements: [ElementInfo]) -> Self? {
        let buttons = elements.filter { $0.id.hasPrefix("aerr_") }
        guard !buttons.isEmpty, let title = elements.first(where: { $0.id == "alertTitle" })?.label else { return nil }
        return Self(title: title, actions: buttons.map { "\($0.id): \($0.label)" })
    }

    var value: Value {
        .object(["title": .string(title), "actions": .array(actions.map(Value.string))])
    }

    var sentence: String {
        "a system dialog is in front: \"\(title)\" (\(actions.joined(separator: ", "))). Tap one of its buttons"
            + " with tap_element, then retry"
    }
}

extension DriverToolExecutor {
    /// The system dialog in front when `frontmost` is Android's own package, read with one query.
    func blockingSystemDialog(frontmost: String?, driver: any PlatformDriver) async -> BlockingSystemDialog? {
        guard frontmost == BlockingSystemDialog.androidSystemPackage else { return nil }
        logger.debug("Looking for a blocking system dialog", context: "frontmost=android")
        let elements = await (try? driver.findElements(ElementSelector())) ?? []
        let dialog = BlockingSystemDialog.find(in: elements)
        logger.info("Blocking system dialog check finished", context: "found=\(dialog != nil)")
        return dialog
    }

    /// Why a launch did not reach the foreground, naming a system dialog or a stopped companion
    /// when either is what is in front.
    func launchMismatch(appID: String, frontmost: String, driver: any PlatformDriver) async -> ToolResult {
        var fields: [String: Value] = [
            "app_id": .string(appID), "verified": .bool(false), "frontmost": .string(frontmost)
        ]
        var message = "device_launch_app failed: frontmost app is \(frontmost), expected \(appID)"
        if let dialog = await blockingSystemDialog(frontmost: frontmost, driver: driver) {
            fields["blocking_dialog"] = dialog.value
            message += ": \(dialog.sentence)."
        } else if BlockingSystemDialog.companionPackages.contains(frontmost) {
            fields["failure_scope"] = .string("companion_channel")
            message += ": the amoo companion's own app is in front, so its instrumentation has likely stopped."
                + " Recover it with `amoo env up --runtime-id <runtime>`, then retry."
        }
        return ToolResult(content: message, isError: true, structuredContent: .object(fields))
    }
}

extension DriverToolExecutor {
    /// Why `start_session` has nothing to start from the CLI, and what to use instead.
    static let noSessionsMessage = "Sessions need a long-lived process, and `amoo device` runs one call per"
        + " process. Lease a device with `amoo env up --json`, drive it with `amoo device --runtime-id <id> <tool>`,"
        + " and record a reusable sequence as a flow (`amoo flow`, `amoo generate plan --from-flow`)."
}
