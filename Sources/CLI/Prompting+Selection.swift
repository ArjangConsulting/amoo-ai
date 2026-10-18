import CLIReadline
import Foundation

extension StdioPrompter {
    // Linear key dispatch keeps terminal interaction in one place.
    // A bounded viewport keeps long device lists navigable without scrolling the terminal.
    // swiftlint:disable:next cyclomatic_complexity
    func selectInteractively(
        _ prompt: String,
        options: [String],
        defaults: [Int],
        multiple: Bool
    ) -> [Int]? {
        var selected = Set(defaults.filter { options.indices.contains($0) })
        var focused = selected.min() ?? 0
        let visibleCount = min(max(1, Int(cli_terminal_rows()) - 4), min(8, options.count))
        var renderedLines = 0
        // Leave room for wide Unicode labels, which may occupy two terminal columns.
        while true {
            if renderedLines > 0 {
                print("\u{1B}[\(renderedLines)A", terminator: "")
            }
            var lines = [prompt]
            let start = min(max(0, focused - visibleCount / 2), options.count - visibleCount)
            for index in start ..< start + visibleCount {
                let marker = multiple ? (selected.contains(index) ? "[x]" : "[ ]") : (focused == index ? "(*)" : "( )")
                lines.append("\(focused == index ? ">" : " ") \(marker) \(options[index])")
            }
            lines.append(multiple
                ? "Up/Down move | Space toggle | a all | Enter done | Esc cancel"
                : "Up/Down move | Enter select | Esc cancel")
            for line in lines {
                // Keep each rendered row bounded, including labels containing control characters.
                let clean = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                let text = String(String.UnicodeScalarView(clean))
                let width = max(1, Int(cli_terminal_columns()) - 1)
                let limit = text.unicodeScalars.allSatisfy(\.isASCII) ? width : width / 2
                print("\u{1B}[2K\r" + String(text.prefix(max(1, limit))))
            }
            fflush(nil)
            renderedLines = lines.count
            switch readSelectionKey() {
            case -1:
                print("Cancelled.")
                return nil
            case 1001, 107:
                focused = (focused + options.count - 1) % options.count
            case 1002, 106:
                focused = (focused + 1) % options.count
            case 32 where multiple:
                if !selected.insert(focused).inserted {
                    selected.remove(focused)
                }
            case 97 where multiple:
                selected = selected.count == options.count ? [] : Set(options.indices)
            case 10, 13:
                if !multiple {
                    return [focused]
                }
                if !selected.isEmpty {
                    return selected.sorted()
                }
            default:
                break
            }
        }
    }
}
