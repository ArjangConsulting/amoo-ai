import Foundation

extension ToolRequest {
    static func validateSemantics(name: String, arguments: [String: String]) throws {
        if let environment = arguments["environment"], !environment.isEmpty {
            let separator: Character = environment.contains("\n") ? "\n" : ","
            for pair in environment.split(separator: separator) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw invalidArgument("environment", example: "environment=TEST_MODE=1")
                }
            }
        }
        if arguments["check_id"] != nil, arguments["session_id"] == nil {
            throw invalidArgument("session_id", example: "Pass the session that declared this check_id")
        }
        let selecting = [
            "tap_element", "assert_visible", "assert_absent", "assert_enabled", "assert_value", "assert_selected",
            "assert_checked", "assert_state_description", "set_text", "fill_field"
        ]
        if selecting.contains(name) {
            try validateSelector(arguments)
        }
        if ["assert_checked", "assert_selected"].contains(name), let expected = arguments["expected"],
           !["true", "false"].contains(expected.lowercased()) {
            throw invalidArgument("expected", example: "expected=true")
        }
        if ["assert_value", "assert_state_description"].contains(name), arguments["credential"] == nil,
           (arguments["expected"] != nil) == (arguments["contains"] != nil) {
            throw invalidArgument("expected", example: "Provide expected=Ready or contains=Ready, exactly one")
        }
        if name == "take_screenshot", boolArgument(arguments["return_image"]) == false,
           arguments["output"]?.isEmpty != false {
            throw invalidArgument("output", example: "output=/absolute/path/screen.png when return_image=false")
        }
    }

    private static func validateSelector(_ arguments: [String: String]) throws {
        let exact = ["id", "label", "contains_text"].contains { arguments[$0]?.isEmpty == false }
        let fuzzy = ["description", "field_description"].contains { arguments[$0]?.isEmpty == false }
        if exact, fuzzy {
            throw invalidArgument("description", example: "Use only label=\"Account settings\" or description")
        }
        if !exact, !fuzzy {
            let error = invalidArgument("id", example: "id=control")
            throw ToolExecutionError(
                code: error.code, message: "An element selector is required. " + error.message, extra: error.extra
            )
        }
        if let raw = arguments["first"], boolArgument(raw) == nil {
            throw invalidArgument("first", example: "first=true")
        }
        if let raw = arguments["index"], Int(raw).map({ $0 >= 0 }) != true {
            throw invalidArgument("index", example: "index=0")
        }
        if arguments["index"] != nil, boolArgument(arguments["first"]) == true {
            throw invalidArgument("index", example: "Use index=0 or first=true, not both")
        }
    }
}
