---
name: ios-accessibility
description: Guide for inspecting and interacting with the iOS accessibility tree — XCUITest element queries, accessibility properties, Accessibility Inspector, VoiceOver, and AI-driven element discovery.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-04 |
| Xcode | 16.x |
| iOS SDK | 18.x+ |
| Frameworks | XCTest/XCUITest, Accessibility, SwiftUI |
| Source | Apple Developer Documentation, XCUITest APIs |

### Update checklist
- [ ] Check [Xcode Release Notes](https://developer.apple.com/documentation/xcode-release-notes) for XCUITest changes
- [ ] Check [iOS & iPadOS Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes) for new accessibility APIs
- [ ] Review SwiftUI accessibility modifiers for new additions
- [ ] Check for new `XCUIElement.ElementType` values
- [ ] Test Accessibility Inspector for new features after Xcode updates

# iOS Accessibility Skill

Guide for inspecting, querying, and interacting with the iOS accessibility tree for automated testing and AI-driven UI interaction.

## When to use

Use this skill when:
- Querying UI elements for automated test interactions
- Inspecting the accessibility hierarchy of an iOS app
- Building AI-driven test automation that discovers and interacts with elements
- Setting up accessibility identifiers and labels in app code
- Debugging accessibility issues with Accessibility Inspector

## Cross-Platform Mapping

| Concept | iOS | Android |
|---------|-----|---------|
| Unique test ID | `accessibilityIdentifier` | `resource-id` / `viewIdResourceName` |
| Human-readable label | `accessibilityLabel` | `content-desc` / `contentDescription` |
| Current value | `accessibilityValue` | `text` (for inputs) |
| Visible text | `label` (on XCUIElement) | `text` |
| Element type | `elementType` / `accessibilityTraits` | `className` |
| Bounding rect | `frame` | `bounds` (`[left,top][right,bottom]`) |
| Is tappable | `.isHittable` | `clickable="true"` |
| Is enabled | `.isEnabled` | `enabled="true"` |
| Screen reader | VoiceOver | TalkBack |
| Tree dump tool | Accessibility Inspector / `snapshot()` | `uiautomator dump` |
| Test framework | XCUITest | UIAutomator2 / Espresso |

## Accessibility Properties (App Side)

These properties are set by app developers and form the data that test automation reads.

### SwiftUI

```swift
Text("Submit Order")
    .accessibilityIdentifier("submit-order-button")  // Stable test ID
    .accessibilityLabel("Submit your order")          // VoiceOver reads this
    .accessibilityValue("3 items, $42.50")            // Current state
    .accessibilityHint("Double tap to place order")   // Usage hint
    .accessibilityAddTraits(.isButton)                // Element role
    .accessibilityRemoveTraits(.isStaticText)

// Combining child elements into one
HStack {
    Image(systemName: "star.fill")
    Text("Favorites")
}
.accessibilityElement(children: .combine)

// Hiding decorative elements
Image("decorative-border")
    .accessibilityHidden(true)

// Custom actions
Button("Item") { }
    .accessibilityAction(named: "Delete") { deleteItem() }
    .accessibilityAction(named: "Share") { shareItem() }
```

### UIKit

```swift
button.accessibilityIdentifier = "submit-order-button"
button.accessibilityLabel = "Submit your order"
button.accessibilityValue = "3 items, $42.50"
button.accessibilityHint = "Double tap to place order"
button.accessibilityTraits = [.button]
button.isAccessibilityElement = true

// Container — expose children
containerView.isAccessibilityElement = false
containerView.accessibilityElements = [child1, child2, child3]
```

### Key properties

| Property | Purpose | Test automation use |
|----------|---------|-------------------|
| `accessibilityIdentifier` | Stable ID for testing (not read by VoiceOver) | Primary element lookup key |
| `accessibilityLabel` | Human-readable name | Fallback lookup, verification |
| `accessibilityValue` | Current state/value | Assert element state |
| `accessibilityHint` | Usage instructions | Not typically used in tests |
| `accessibilityTraits` | Element role/behavior | Filter by type |
| `isAccessibilityElement` | Whether element is exposed | Affects tree visibility |

### Accessibility Traits

```swift
// Common traits
.isButton
.isLink
.isHeader
.isSearchField
.isImage
.isStaticText
.isSelected
.isNotEnabled
.adjustable          // supports increment/decrement (sliders, steppers)
.allowsDirectInteraction
.updatesFrequently   // live-updating content
.startsMediaSession
.causesPageTurn
.tabBar
.summaryElement
```

## XCUITest Element Queries

### Element types

XCUITest provides typed queries for each element type:

```swift
let app = XCUIApplication()
app.launch()

// Common element type queries
app.buttons                    // UIButton, SwiftUI Button
app.staticTexts                // UILabel, SwiftUI Text
app.textFields                 // UITextField, SwiftUI TextField
app.secureTextFields           // UITextField (isSecureTextEntry)
app.textViews                  // UITextView, SwiftUI TextEditor
app.images                     // UIImageView, SwiftUI Image
app.switches                   // UISwitch, SwiftUI Toggle
app.sliders                    // UISlider, SwiftUI Slider
app.steppers                   // UIStepper, SwiftUI Stepper
app.pickers                    // UIPickerView, SwiftUI Picker
app.tables                     // UITableView, SwiftUI List
app.collectionViews            // UICollectionView
app.cells                      // UITableViewCell, List rows
app.scrollViews                // UIScrollView, SwiftUI ScrollView
app.navigationBars             // UINavigationBar
app.tabBars                    // UITabBar, SwiftUI TabView
app.toolbars                   // UIToolbar
app.alerts                     // UIAlertController
app.sheets                     // Action sheets
app.popovers                   // Popovers
app.menus                      // Context menus
app.menuItems                  // Menu items
app.segmentedControls          // UISegmentedControl
app.activityIndicators         // UIActivityIndicatorView
app.progressIndicators         // UIProgressView
app.webViews                   // WKWebView
app.maps                       // MKMapView
app.links                      // Links in text/web views
app.windows                    // UIWindow
app.otherElements              // Catch-all for untyped elements
```

### Finding elements

```swift
// By accessibility identifier (preferred — most stable)
let submitButton = app.buttons["submit-order-button"]

// By label text
let welcomeLabel = app.staticTexts["Welcome back"]

// By index
let firstCell = app.cells.element(boundBy: 0)

// By predicate
let enabledButtons = app.buttons.matching(
    NSPredicate(format: "isEnabled == true")
)

let priceLabels = app.staticTexts.matching(
    NSPredicate(format: "label CONTAINS '$'")
)

let loginField = app.textFields.matching(
    NSPredicate(format: "placeholderValue == 'Email address'")
).firstMatch

// By element type
let anyButton = app.buttons.firstMatch

// Descendant query (search within a container)
let tableCell = app.tables.firstMatch.cells["order-123"]
let cellLabel = tableCell.staticTexts["Order Total"]

// Chained queries
let navBarTitle = app.navigationBars.firstMatch.staticTexts.firstMatch
```

### Element properties for inspection

```swift
let element = app.buttons["submit-order-button"]

// Identity
element.identifier          // accessibilityIdentifier
element.label               // accessibilityLabel
element.title               // title (navigation items, etc.)
element.placeholderValue    // placeholder text (text fields)
element.value               // accessibilityValue (as Any?)
element.elementType         // XCUIElement.ElementType enum

// State
element.exists              // is in the accessibility tree
element.isHittable          // is visible and tappable (not obscured)
element.isEnabled           // is interactive
element.isSelected          // is in selected state
element.hasFocus            // has keyboard focus

// Geometry
element.frame               // CGRect in screen coordinates

// Hierarchy
element.children(matching: .button)  // child elements of type
element.descendants(matching: .any)  // all descendants
```

### Waiting for elements

```swift
// Wait for element to exist (with timeout)
let element = app.buttons["submit-order-button"]
let exists = element.waitForExistence(timeout: 5)

// Wait for element to have a specific property
let predicate = NSPredicate(format: "isEnabled == true")
let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
let result = XCTWaiter.wait(for: [expectation], timeout: 10)
```

### Interacting with elements

```swift
// Tap
element.tap()
element.doubleTap()
element.twoFingerTap()
element.press(forDuration: 1.0)          // long press
element.press(forDuration: 1.0, thenDragTo: otherElement)

// Type
element.tap()                             // focus first
element.typeText("hello@example.com")

// Clear and type
let textField = app.textFields["email-field"]
textField.tap()
textField.press(forDuration: 1.0)         // select all via long press
app.menuItems["Select All"].tap()         // or use menu
textField.typeText("")                    // delete selected
textField.typeText("new@example.com")

// Swipe
element.swipeUp()
element.swipeDown()
element.swipeLeft()
element.swipeRight()

// Pinch and rotate
element.pinch(withScale: 0.5, velocity: -1.0)   // pinch in
element.pinch(withScale: 2.0, velocity: 1.0)    // pinch out
element.rotate(CGFloat.pi / 4, withVelocity: 1.0)

// Adjust (sliders, steppers)
slider.adjust(toNormalizedSliderPosition: 0.75)

// Tap at coordinate offset
let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
coordinate.tap()
```

### Scrolling to find elements

```swift
// Scroll until element is visible
let targetCell = app.cells["item-42"]
let table = app.tables.firstMatch

// Swipe-to-find pattern
while !targetCell.isHittable {
    table.swipeUp()
}
targetCell.tap()

// Or use scroll views
app.scrollViews.firstMatch.swipeUp()
```

## Accessibility Snapshots (Tree Dump)

### XCUITest snapshot

```swift
// Get the full accessibility tree as a snapshot
let app = XCUIApplication()
let snapshot = try app.snapshot()

// snapshot contains:
//   - identifier
//   - label
//   - value
//   - elementType
//   - frame
//   - children (recursive)
//   - isEnabled, isSelected, hasFocus

// Debug print the element hierarchy
print(app.debugDescription)
// Outputs the full tree with all elements, types, identifiers, labels
```

### Using `debugDescription` for AI analysis

The `debugDescription` property outputs the full accessibility tree in a human-readable format:

```
Application, 0x600000210000, pid: 12345, label: 'MyApp'
  Window, 0x600000210100, {{0, 0}, {393, 852}}
    NavigationBar, 0x600000210200, identifier: 'main-nav'
      StaticText, 0x600000210300, label: 'Home'
      Button, 0x600000210400, identifier: 'settings-button', label: 'Settings'
    Table, 0x600000210500
      Cell, 0x600000210600, identifier: 'order-123'
        StaticText, 0x600000210700, label: 'Order #123'
        StaticText, 0x600000210800, label: '$42.50'
        Button, 0x600000210900, identifier: 'view-details', label: 'View Details'
```

This is the key data format for AI-driven testing — an LLM can parse this tree to plan interactions.

## Accessibility Inspector

Xcode includes Accessibility Inspector for live inspection:

```bash
# Open Accessibility Inspector
open "/Applications/Xcode.app/Contents/Applications/Accessibility Inspector.app"
```

### What it shows
- **Element hierarchy** — full tree view
- **Element details** — identifier, label, value, traits, frame
- **Actions** — available accessibility actions
- **Audit** — automated accessibility issue detection
- **Settings** — simulate VoiceOver, Dynamic Type, color filters

### Using with Simulator
1. Launch Accessibility Inspector
2. Select the Simulator from the device dropdown (top-left)
3. Click the crosshair target button
4. Hover over elements in the Simulator to inspect them
5. Use the Audit tab to run automated accessibility checks

## VoiceOver Testing

```bash
# Toggle VoiceOver on simulator (keyboard shortcut)
# Command + F5 (in Simulator)

# Or via simctl (if supported)
# VoiceOver is primarily tested interactively
```

### VoiceOver reading order
VoiceOver reads elements in this order:
1. `accessibilityLabel`
2. `accessibilityValue` (if different from label)
3. `accessibilityTraits` (announces "button", "heading", etc.)
4. `accessibilityHint` (after a pause)

## Programmatic Tree Extraction (for AI drivers)

For building a Swift driver that extracts the accessibility tree:

```swift
import XCTest

/// Represents a node in the accessibility tree
struct AccessibilityNode: Codable, Sendable {
    let elementType: String
    let identifier: String?
    let label: String?
    let value: String?
    let placeholderValue: String?
    let frame: CGRect
    let isEnabled: Bool
    let isHittable: Bool
    let isSelected: Bool
    let children: [AccessibilityNode]
}

/// Extract the full accessibility tree from an XCUIApplication
func extractAccessibilityTree(from element: XCUIElement) -> AccessibilityNode {
    let children = element.children(matching: .any).allElementsBoundByIndex.map {
        extractAccessibilityTree(from: $0)
    }

    return AccessibilityNode(
        elementType: String(describing: element.elementType),
        identifier: element.identifier.isEmpty ? nil : element.identifier,
        label: element.label.isEmpty ? nil : element.label,
        value: element.value as? String,
        placeholderValue: element.placeholderValue,
        frame: element.frame,
        isEnabled: element.isEnabled,
        isHittable: element.isHittable,
        isSelected: element.isSelected,
        children: children
    )
}

// Convert to JSON for AI consumption
let tree = extractAccessibilityTree(from: app)
let jsonData = try JSONEncoder().encode(tree)
let jsonString = String(data: jsonData, encoding: .utf8)
```

## Best Practices for Testable Accessibility

### For app developers (making apps test-friendly)

1. **Always set `accessibilityIdentifier`** on interactive elements — it's the most stable selector
2. **Use descriptive, unique identifiers** — `"login-email-field"` not `"field1"`
3. **Keep identifiers stable across versions** — they're your test contract
4. **Set `accessibilityLabel`** for VoiceOver and as a fallback selector
5. **Mark decorative elements** as `accessibilityHidden(true)`
6. **Combine related elements** with `accessibilityElement(children: .combine)` to reduce tree noise

### For test automation

1. **Prefer `accessibilityIdentifier`** over label for element lookup (stable across localizations)
2. **Use `waitForExistence(timeout:)`** before interacting — never assume elements are immediately present
3. **Check `isHittable`** before tapping — `exists` doesn't mean visible/tappable
4. **Use `debugDescription`** to dump the tree when debugging failures
5. **Query from the most specific container** — `app.tables.firstMatch.cells["id"]` is better than `app.cells["id"]`
6. **Handle system alerts** (permissions, notifications) — they can block element access

### Element lookup priority

1. `accessibilityIdentifier` — most stable, locale-independent
2. `accessibilityLabel` — readable, but changes with localization
3. Predicate matching — flexible but brittle
4. Index-based (`boundBy:`) — least stable, use as last resort
