import AmooCore
import AmooLogging
import StudioProtocol

private let logger = AmooLogger.forType(BlockingSystemDialog.self)

/// A system dialog holding the foreground, such as Android's "<app> isn't responding".
///
/// Android draws its ANR and crash dialogs in the `android` package, so a launch that met one
/// reported only "frontmost app is android", and finding the cause took a screenshot and a query.
struct BlockingSystemDialog: Equatable {
    var title: String
    /// `id: label` of each button, such as `aerr_wait: Wait`.
    var actions: [String]
    /// The button `dismiss_system_dialogs` presses: one that only closes the dialog (Android's Wait,
    /// iOS's Not Now or Cancel). nil when the dialog offers none, so it is never answered.
    var harmlessButton: ElementInfo?
    /// Whether the system drew it. Android's dialogs always are; on iOS an app's own alert has the same
    /// element types as Apple's sheets, so only a title in `appleSystemPromptTitles` counts, and only
    /// those are ever answered: cancelling the app's "Discard changes?" would hide a behaviour change.
    var isSystemPrompt = true

    /// Buttons that close a dialog without changing anything: never Save, Allow, Close app or OK.
    static let harmlessLabels: Set = ["wait", "not now", "cancel", "dismiss", "no thanks", "don't save"]

    /// Lowercased title prefixes of the Apple prompts that interrupt a run over the app.
    static let appleSystemPromptTitles = [
        "save password", "save this password", "would you like to save this password", "update password",
        "update saved password", "sign in to apple account"
    ]

    /// Android's own package, frontmost while one of its dialogs is up.
    static let androidSystemPackage = "android"
    /// The amoo companion's app, frontmost when its instrumentation has stopped.
    static let companionPackages: Set<String> = ["com.amoo.companion", "com.amoo.companion.test"]

    /// The dialog among `elements`, recognised by the framework's `alertTitle` and `aerr_*` buttons.
    static func find(in elements: [ElementInfo]) -> Self? {
        let buttons = elements.filter { $0.id.hasPrefix("aerr_") }
        guard !buttons.isEmpty, let title = elements.first(where: { $0.id == "alertTitle" })?.label else { return nil }
        return Self(
            title: title,
            actions: buttons.map { "\($0.id): \($0.label)" },
            harmlessButton: buttons.first { $0.id == "aerr_wait" }
        )
    }

    /// An iOS alert or sheet in front ("Save Password?" with Not Now and Save), with the buttons inside
    /// its frame. It may be the app's own; `isSystemPrompt` says whether Apple's.
    static func findIOS(in elements: [ElementInfo]) -> Self? {
        guard let sheet = elements.first(where: {
            ($0.type == .sheet || $0.type == .alert) && $0.isVisible
                && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        let buttons = elements.filter { element in
            guard element.type == .button, !element.label.isEmpty,
                  let point = element.hitPoint ?? element.frame?.centre else { return false }
            guard let frame = sheet.frame else { return true }
            return (frame.x ... frame.x + frame.width).contains(point.x)
                && (frame.y ... frame.y + frame.height).contains(point.y)
        }
        return Self(
            title: sheet.label,
            actions: buttons.map(\.label),
            harmlessButton: buttons.first { harmlessLabels.contains($0.label.lowercased()) },
            isSystemPrompt: isAppleSystemPrompt(sheet.label)
        )
    }

    static func isAppleSystemPrompt(_ title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces).lowercased()
        return appleSystemPromptTitles.contains { title.hasPrefix($0) }
    }

    /// Whether this is the target app's own "isn't responding" dialog, judged by a distinctive part of
    /// its package id appearing in the title ("Novalingo isn't responding" for com.novalingo.android.qa).
    /// Its own hang is a finding, so it is never answered.
    func belongs(to appID: String?) -> Bool {
        guard let appID else { return false }
        let generic: Set = ["com", "org", "net", "android", "app", "apps", "ios", "qa", "debug", "dev", "staging"]
        let title = title.lowercased()
        return appID.lowercased().split(separator: ".")
            .contains { $0.count > 3 && !generic.contains(String($0)) && title.contains($0) }
    }

    var value: Value {
        .object([
            "title": .string(title),
            "actions": .array(actions.map(Value.string)),
            "system": .bool(isSystemPrompt)
        ])
    }

    var shortDescription: String {
        "\"\(title)\" (\(actions.joined(separator: ", ")))"
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

    /// The system dialog in front on either platform: Android's `android` package dialogs, or an iOS
    /// system alert or sheet. One query; nil when none is up.
    func frontSystemDialog(driver: any PlatformDriver, arguments: [String: String]) async -> BlockingSystemDialog? {
        guard let platform = await knownPlatform(driver: driver, arguments: arguments) else { return nil }
        if platform == .android {
            let frontmost = try? await driver.currentApp().bundleID
            return await blockingSystemDialog(frontmost: frontmost, driver: driver)
        }
        let elements = await (try? driver.findElements(ElementSelector())) ?? []
        return BlockingSystemDialog.findIOS(in: elements)
    }

    /// Sets `dismiss_system_dialogs` for calls that do not pass it; `amoo flow` applies the flow's switch.
    public func setDismissSystemDialogsByDefault(_ value: Bool) {
        dismissSystemDialogsByDefault = value
    }

    /// A failed step behind a system dialog (another app's ANR, iOS "Save Password?") answered on
    /// request, then run once more; `result` unchanged otherwise.
    func retryingPastSystemDialog(
        _ result: ToolResult,
        tool: String,
        arguments: [String: String],
        credentialClass: CredentialField.Class?
    ) async throws -> ToolResult {
        guard result.isError, Self.dialogSensitiveTools.union(["device_launch_app"]).contains(tool),
              let answered = await dismissSystemDialog(arguments: arguments) else { return result }
        var retried = try await CredentialDispatch.$fieldClass.withValue(credentialClass) {
            try await self.dispatch(toolName: tool, arguments: arguments)
        }
        var fields = retried.structuredContent?.objectValue ?? [:]
        fields["dismissed_dialog"] = answered.value
        retried.structuredContent = .object(fields)
        retried.content += "\n(Answered the system dialog \(answered.shortDescription) and retried.)"
        return retried
    }

    /// The platform from the session or the executor's configuration, asking the device only when
    /// neither knows: an unresponsive device should not be asked twice.
    private func knownPlatform(driver: any PlatformDriver, arguments: [String: String]) async -> Platform? {
        if let id = arguments["session_id"], let session = await sessionManager?.session(id) {
            return session.platform
        }
        if let defaultPlatform {
            return defaultPlatform
        }
        return try? await driver.deviceInfo().platform
    }

    /// Tools whose failure can be a system dialog in front rather than the app.
    static let dialogSensitiveTools: Set = [
        "tap_element", "set_text", "fill_field", "type_text", "scroll_to_element", "scroll", "swipe_in_direction",
        "assert_visible", "assert_enabled", "assert_value", "assert_selected", "assert_checked",
        "assert_state_description", "assert_screen_changed", "find_elements", "navigate_to"
    ]

    /// A failed element step names the system dialog in front of the app, so the cause is in the
    /// failure instead of in a screenshot taken afterwards.
    func diagnoseBlockingDialog(_ original: ToolResult, tool: String, arguments: [String: String]) async -> ToolResult {
        var fields = original.structuredContent?.objectValue ?? [:]
        // A device or channel failure is not a dialog in front, and asking the device again only waits.
        guard original.isError, Self.dialogSensitiveTools.contains(tool), fields["blocking_dialog"] == nil,
              fields["failure_scope"] == nil, fields["code"] != .string("deadline_exceeded"),
              let driver = try? await resolveDriver(arguments: arguments),
              let dialog = await Self.withinBudget(milliseconds: 2000, {
                  await self.frontSystemDialog(driver: driver, arguments: arguments)
              })
        else { return original }
        logger.info("Failed step met a system dialog", context: "tool=\(tool)")
        fields["blocking_dialog"] = dialog.value
        var result = original
        result.content += dialog.isSystemPrompt
            ? "\nA system dialog is in front: \(dialog.shortDescription). Answer it with tap_element,"
            + " or pass dismiss_system_dialogs=true to let amoo press its harmless button and retry."
            : "\nA dialog is in front: \(dialog.shortDescription). It is not a known system prompt, so"
            + " dismiss_system_dialogs leaves it: answer it with tap_element if the flow expects it."
        result.structuredContent = .object(fields)
        return result
    }

    /// With `dismiss_system_dialogs=true`, presses the harmless button of a system dialog in front of the
    /// app (never the target app's own "isn't responding"), and returns what it answered.
    func dismissSystemDialog(arguments: [String: String]) async -> BlockingSystemDialog? {
        guard boolArgument(arguments["dismiss_system_dialogs"]) ?? dismissSystemDialogsByDefault,
              let driver = try? await resolveDriver(arguments: arguments),
              let dialog = await Self.withinBudget(milliseconds: 2000, {
                  await self.frontSystemDialog(driver: driver, arguments: arguments)
              }),
              dialog.isSystemPrompt,
              let button = dialog.harmlessButton, let point = button.hitPoint ?? button.frame?.centre
        else { return nil }
        var target = arguments["app_id"]
        if target == nil {
            target = try? await driver.currentApp().targetBundleID
        }
        guard !dialog.belongs(to: target) else {
            logger.info("Left the target app's own dialog unanswered", context: "title_length=\(dialog.title.count)")
            return nil
        }
        do {
            try await driver.tap(at: point)
        } catch {
            logger.error("Could not answer a system dialog", error: error, context: "button=\(button.label)")
            return nil
        }
        logger.info("Answered a system dialog", context: "button=\(button.label)")
        try? await Task.sleep(for: .milliseconds(500))
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
    /// The `compile=<mode>` request of `device_install_app`, checked before anything is installed:
    /// `nil` when the call did not ask for it.
    func compileRequest(
        arguments: [String: String],
        driver: any PlatformDriver
    ) throws -> CompileRequest? {
        guard let mode = arguments["compile"], !mode.isEmpty else { return nil }
        guard ["verify", "speed-profile", "speed", "everything"].contains(mode) else {
            throw ToolExecutionError(
                code: "invalid_argument", message: "compile must be verify, speed-profile, speed or everything."
            )
        }
        guard let appID = arguments["app_id"], !appID.isEmpty else {
            throw ToolExecutionError(code: "invalid_argument", message: "compile needs app_id: the installed package.")
        }
        guard let compiler = driver as? any AppCompiling else {
            throw ToolExecutionError(
                code: "unsupported", message: "compile is Android-only: this platform has no ahead-of-time step."
            )
        }
        return CompileRequest(mode: mode, appID: appID, compiler: compiler)
    }

    /// Runs a checked compile request and reports `{mode, ms}`.
    func compileInstalledApp(_ request: CompileRequest) async throws -> Value {
        let logger = AmooLogger.forType(Self.self)
        let started = ContinuousClock.now
        logger.info("Compiling installed app", context: "mode=\(request.mode) app=\(request.appID)")
        do {
            _ = try await request.compiler.compileApp(appID: request.appID, mode: request.mode)
        } catch {
            logger.error("Compiling installed app failed", error: error, context: "mode=\(request.mode)")
            throw error
        }
        let elapsed = started.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        logger.info("Compiled installed app", context: "mode=\(request.mode) ms=\(milliseconds)")
        return .object(["mode": .string(request.mode), "ms": .int(milliseconds)])
    }
}

/// A checked `compile=<mode>` request of `device_install_app`.
struct CompileRequest {
    var mode: String
    var appID: String
    var compiler: any AppCompiling
}
