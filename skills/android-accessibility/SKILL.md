---
name: android-accessibility
description: Guide for inspecting and interacting with the Android accessibility tree — UIAutomator, AccessibilityNodeInfo, resource IDs, content descriptions, TalkBack, and AI-driven element discovery.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-04 |
| Android SDK | API 35 (Android 15) |
| Tools | UIAutomator2, adb, Accessibility Scanner |
| Source | Android Developer Documentation, UIAutomator APIs |

### Update checklist
- [ ] Check [Android API diff reports](https://developer.android.com/sdk/api_diff/) for AccessibilityNodeInfo changes
- [ ] Check [UIAutomator release notes](https://developer.android.com/training/testing/other-components/ui-automator) for new APIs
- [ ] Verify `uiautomator dump` XML schema against latest SDK
- [ ] Check [Android Studio release notes](https://developer.android.com/studio/releases) for Layout Inspector updates
- [ ] Review Compose accessibility APIs for new modifiers

# Android Accessibility Skill

Guide for inspecting, querying, and interacting with the Android accessibility tree for automated testing and AI-driven UI interaction.

## When to use

Use this skill when:
- Querying UI elements via UIAutomator or accessibility services
- Inspecting the accessibility hierarchy of an Android app
- Building AI-driven test automation that discovers and interacts with elements
- Setting up content descriptions and resource IDs in app code
- Debugging accessibility issues with Accessibility Scanner

## Cross-Platform Mapping

| Concept | Android | iOS |
|---------|---------|-----|
| Unique test ID | `resource-id` / `viewIdResourceName` | `accessibilityIdentifier` |
| Human-readable label | `content-desc` / `contentDescription` | `accessibilityLabel` |
| Visible text | `text` | `label` (on XCUIElement) |
| Current value | `text` (for inputs) | `accessibilityValue` |
| Element type | `className` | `elementType` / `accessibilityTraits` |
| Bounding rect | `bounds` (`[left,top][right,bottom]`) | `frame` (CGRect) |
| Is tappable | `clickable="true"` | `.isHittable` |
| Is enabled | `enabled="true"` | `.isEnabled` |
| Screen reader | TalkBack | VoiceOver |
| Tree dump tool | `uiautomator dump` | Accessibility Inspector / `snapshot()` |
| Test framework | UIAutomator2 / Espresso | XCUITest |

## Accessibility Properties (App Side)

These properties are set by app developers and form the data that test automation reads.

### Jetpack Compose

```kotlin
Button(
    onClick = { /* ... */ },
    modifier = Modifier
        .testTag("submit-order-button")           // Stable test ID (resource-id)
        .semantics {
            contentDescription = "Submit your order"  // TalkBack reads this
            stateDescription = "3 items, $42.50"      // Current state
            role = Role.Button                         // Element role
        }
) {
    Text("Submit Order")
}

// Hiding decorative elements
Image(
    painter = painterResource(R.drawable.decorative),
    contentDescription = null,  // null = hidden from accessibility
    modifier = Modifier.clearAndSetSemantics { }  // completely hidden
)

// Merging descendants
Row(
    modifier = Modifier.semantics(mergeDescendants = true) {
        contentDescription = "Favorites, 12 items"
    }
) {
    Icon(Icons.Default.Star, contentDescription = null)
    Text("Favorites")
    Text("12")
}

// Custom actions
Box(
    modifier = Modifier.semantics {
        customActions = listOf(
            CustomAccessibilityAction("Delete") { deleteItem(); true },
            CustomAccessibilityAction("Share") { shareItem(); true }
        )
    }
)
```

### XML Views (Traditional Android)

```xml
<Button
    android:id="@+id/submit_order_button"
    android:contentDescription="Submit your order"
    android:importantForAccessibility="yes"
    android:text="Submit Order" />

<!-- Hide decorative elements -->
<ImageView
    android:importantForAccessibility="no"
    android:src="@drawable/decorative_border" />

<!-- Label an input with another view -->
<TextView
    android:id="@+id/email_label"
    android:text="Email"
    android:labelFor="@+id/email_input" />
<EditText
    android:id="@+id/email_input"
    android:hint="Enter your email" />
```

```kotlin
// Programmatic (Kotlin)
button.contentDescription = "Submit your order"
button.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES

// ViewCompat for backward compatibility
ViewCompat.setAccessibilityDelegate(view, object : AccessibilityDelegateCompat() {
    override fun onInitializeAccessibilityNodeInfo(
        host: View, info: AccessibilityNodeInfoCompat
    ) {
        super.onInitializeAccessibilityNodeInfo(host, info)
        info.roleDescription = "Custom widget"
        info.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(
            AccessibilityNodeInfoCompat.ACTION_CLICK, "Activate"
        ))
    }
})
```

### Key properties

| Property | XML Attribute | Purpose | Test automation use |
|----------|--------------|---------|-------------------|
| Resource ID | `android:id` | View identifier | Primary element lookup (`resource-id`) |
| Content Description | `android:contentDescription` | Accessibility label | Secondary lookup, verification |
| Text | `android:text` | Visible text content | Text-based lookup |
| Hint | `android:hint` | Placeholder text | Input field identification |
| Test Tag | `Modifier.testTag()` (Compose) | Stable test ID | Preferred lookup in Compose |
| Important for A11y | `android:importantForAccessibility` | Tree visibility | Affects what's queryable |

## UIAutomator Dump (Tree Extraction via ADB)

The primary tool for extracting the accessibility tree without app-side code.

### Basic dump

```bash
# Dump UI hierarchy to file on device
adb shell uiautomator dump /sdcard/ui_dump.xml
adb pull /sdcard/ui_dump.xml ./ui_dump.xml

# Direct dump to stdout (faster)
adb exec-out uiautomator dump /dev/tty

# Dump with compressed hierarchy (merges some nodes)
adb shell uiautomator dump --compressed /sdcard/ui_dump.xml
```

### XML structure

```xml
<?xml version="1.0" encoding="UTF-8"?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout"
        package="com.example.myapp" content-desc="" checkable="false"
        checked="false" clickable="false" enabled="true" focusable="false"
        focused="false" scrollable="false" long-clickable="false"
        password="false" selected="false" bounds="[0,0][1080,2400]">

    <node index="0" text="Submit Order" resource-id="com.example.myapp:id/submit_order_button"
          class="android.widget.Button" package="com.example.myapp"
          content-desc="Submit your order" checkable="false" checked="false"
          clickable="true" enabled="true" focusable="true" focused="false"
          scrollable="false" long-clickable="false" password="false"
          selected="false" bounds="[200,800][880,920]">
    </node>

  </node>
</hierarchy>
```

### Node attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `text` | String | Visible text content |
| `resource-id` | String | Full resource ID (`package:id/name`) |
| `class` | String | Android widget class name |
| `package` | String | App package name |
| `content-desc` | String | Accessibility content description |
| `bounds` | String | Screen bounds `[left,top][right,bottom]` |
| `checkable` | Boolean | Can be checked (checkbox, radio) |
| `checked` | Boolean | Is currently checked |
| `clickable` | Boolean | Responds to click |
| `enabled` | Boolean | Is interactive |
| `focusable` | Boolean | Can receive focus |
| `focused` | Boolean | Currently has focus |
| `scrollable` | Boolean | Is a scrollable container |
| `long-clickable` | Boolean | Responds to long click |
| `password` | Boolean | Contains password (text masked) |
| `selected` | Boolean | Is in selected state |
| `index` | Int | Position among siblings |

### Computing tap coordinates from bounds

```
bounds="[200,800][880,920]"
       [left,top][right,bottom]

Center X = (left + right) / 2  = (200 + 880) / 2 = 540
Center Y = (top + bottom) / 2  = (800 + 920) / 2 = 860

adb shell input tap 540 860
```

### Parsing bounds programmatically (Swift)

```swift
struct Bounds {
    let left: Int, top: Int, right: Int, bottom: Int

    var centerX: Int { (left + right) / 2 }
    var centerY: Int { (top + bottom) / 2 }
    var width: Int { right - left }
    var height: Int { top - bottom }

    /// Parse "[left,top][right,bottom]" format
    static func parse(_ boundsString: String) -> Bounds? {
        // Format: [200,800][880,920]
        let numbers = boundsString
            .replacingOccurrences(of: "][", with: ",")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .compactMap { Int($0) }

        guard numbers.count == 4 else { return nil }
        return Bounds(left: numbers[0], top: numbers[1],
                      right: numbers[2], bottom: numbers[3])
    }
}
```

## Finding Elements via ADB

### Using `uiautomator dump` + grep

```bash
# Find elements by resource-id
adb exec-out uiautomator dump /dev/tty | grep -o 'resource-id="[^"]*submit[^"]*"'

# Find elements by text
adb exec-out uiautomator dump /dev/tty | grep -o 'text="[^"]*Submit[^"]*"'

# Find clickable elements
adb exec-out uiautomator dump /dev/tty | grep 'clickable="true"'

# Find all buttons
adb exec-out uiautomator dump /dev/tty | grep 'class="android.widget.Button"'
```

### Common Android widget classes

| Class | Description |
|-------|-------------|
| `android.widget.Button` | Standard button |
| `android.widget.TextView` | Text label |
| `android.widget.EditText` | Text input field |
| `android.widget.ImageView` | Image |
| `android.widget.ImageButton` | Image button |
| `android.widget.CheckBox` | Checkbox |
| `android.widget.RadioButton` | Radio button |
| `android.widget.Switch` | Toggle switch |
| `android.widget.ToggleButton` | Toggle button |
| `android.widget.Spinner` | Dropdown selector |
| `android.widget.SeekBar` | Slider |
| `android.widget.ProgressBar` | Progress indicator |
| `android.widget.ListView` | List view |
| `android.widget.ScrollView` | Scroll container |
| `android.widget.HorizontalScrollView` | Horizontal scroll |
| `android.widget.RecyclerView` | Recycler view |
| `android.widget.ViewPager` | Paged container |
| `android.widget.TabWidget` | Tab bar |
| `android.widget.Toolbar` | Toolbar |
| `android.widget.FrameLayout` | Frame layout (container) |
| `android.widget.LinearLayout` | Linear layout (container) |
| `android.widget.RelativeLayout` | Relative layout (container) |
| `android.view.View` | Generic view |
| `android.view.ViewGroup` | Generic container |
| `android.webkit.WebView` | Web view |
| `androidx.compose.ui.platform.ComposeView` | Compose container |
| `androidx.recyclerview.widget.RecyclerView` | AndroidX RecyclerView |

## AccessibilityNodeInfo (Programmatic API)

For building accessibility services or test instrumentation that runs on-device.

### Key methods

```kotlin
// Getting node info
val nodeInfo: AccessibilityNodeInfo = // from event or service

// Identity
nodeInfo.text                    // CharSequence: visible text
nodeInfo.contentDescription      // CharSequence: accessibility label
nodeInfo.viewIdResourceName      // String: "com.example:id/button_submit"
nodeInfo.className               // CharSequence: "android.widget.Button"
nodeInfo.hintText                // CharSequence: placeholder hint

// State
nodeInfo.isClickable
nodeInfo.isEnabled
nodeInfo.isFocusable
nodeInfo.isFocused
nodeInfo.isScrollable
nodeInfo.isSelected
nodeInfo.isCheckable
nodeInfo.isChecked
nodeInfo.isEditable
nodeInfo.isPassword
nodeInfo.isVisibleToUser

// Geometry
val rect = Rect()
nodeInfo.getBoundsInScreen(rect)  // rect.left, rect.top, rect.right, rect.bottom
nodeInfo.getBoundsInParent(rect)

// Hierarchy
nodeInfo.childCount
nodeInfo.getChild(index)          // AccessibilityNodeInfo
nodeInfo.parent                   // AccessibilityNodeInfo

// Actions
nodeInfo.performAction(AccessibilityNodeInfo.ACTION_CLICK)
nodeInfo.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)
nodeInfo.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
nodeInfo.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
nodeInfo.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,
    Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "hello") })

// Search
nodeInfo.findAccessibilityNodeInfosByText("Submit")
nodeInfo.findAccessibilityNodeInfosByViewId("com.example:id/submit_button")
```

### Common actions

| Action Constant | Description |
|----------------|-------------|
| `ACTION_CLICK` | Tap/click the element |
| `ACTION_LONG_CLICK` | Long press |
| `ACTION_SCROLL_FORWARD` | Scroll down/right |
| `ACTION_SCROLL_BACKWARD` | Scroll up/left |
| `ACTION_SET_TEXT` | Set text content |
| `ACTION_CLEAR_TEXT` | Clear text field |
| `ACTION_FOCUS` | Request focus |
| `ACTION_CLEAR_FOCUS` | Clear focus |
| `ACTION_SELECT` | Select element |
| `ACTION_CLEAR_SELECTION` | Clear selection |
| `ACTION_COPY` | Copy text |
| `ACTION_PASTE` | Paste text |
| `ACTION_CUT` | Cut text |
| `ACTION_EXPAND` | Expand collapsible |
| `ACTION_COLLAPSE` | Collapse expandable |
| `ACTION_DISMISS` | Dismiss dialog/popup |
| `ACTION_SET_SELECTION` | Select text range |

## Layout Inspector (Android Studio)

Android Studio includes Layout Inspector for live UI inspection:

1. **Run app** on emulator or device
2. **Open Layout Inspector**: View → Tool Windows → Layout Inspector
3. **Select process** from the dropdown
4. **Click elements** to see properties
5. **3D view** to see layer hierarchy

Shows:
- Full view hierarchy
- View properties (all attributes)
- Compose semantics (for Compose apps)
- Bounds and measurements

## Accessibility Scanner

Google's Accessibility Scanner app runs automated checks:

```bash
# Install from Play Store on emulator
# Or use via adb
adb shell am start -n com.google.android.apps.accessibility.auditor/.ui.MainActivityForBroadcast
```

Checks for:
- Missing content descriptions
- Touch target size (minimum 48dp × 48dp)
- Text contrast ratios
- Label associations
- Duplicate descriptions

## TalkBack Testing

```bash
# Enable TalkBack via settings
adb shell settings put secure enabled_accessibility_services com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService
adb shell settings put secure accessibility_enabled 1

# Disable TalkBack
adb shell settings put secure enabled_accessibility_services ""
adb shell settings put secure accessibility_enabled 0
```

### TalkBack reading order
TalkBack reads elements in this order:
1. **Role** (announces "Button", "Edit box", etc. from `className`)
2. **Content description** or **text** (the element's label)
3. **State** ("disabled", "checked", etc.)
4. **Hint** if available
5. **Position** ("1 of 5" for lists)

## Programmatic Tree Extraction (for AI Drivers)

### Swift parser for UIAutomator XML

```swift
import Foundation

struct AndroidAccessibilityNode: Codable, Sendable {
    let className: String
    let text: String?
    let resourceId: String?
    let contentDescription: String?
    let bounds: String
    let clickable: Bool
    let enabled: Bool
    let focusable: Bool
    let scrollable: Bool
    let selected: Bool
    let checked: Bool
    let password: Bool
    let children: [AndroidAccessibilityNode]
}

/// Parse UIAutomator XML dump into structured nodes
func parseUIAutomatorDump(_ xmlData: Data) throws -> AndroidAccessibilityNode {
    let parser = UIAutomatorXMLParser(data: xmlData)
    return try parser.parse()
}

class UIAutomatorXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var nodeStack: [AndroidAccessibilityNode] = []
    private var rootNode: AndroidAccessibilityNode?

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }

    func parse() throws -> AndroidAccessibilityNode {
        parser.parse()
        guard let root = rootNode else {
            throw ParserError.noRootNode
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        guard elementName == "node" else { return }

        let node = AndroidAccessibilityNode(
            className: attributes["class"] ?? "",
            text: attributes["text"]?.isEmpty == true ? nil : attributes["text"],
            resourceId: attributes["resource-id"]?.isEmpty == true ? nil : attributes["resource-id"],
            contentDescription: attributes["content-desc"]?.isEmpty == true ? nil : attributes["content-desc"],
            bounds: attributes["bounds"] ?? "",
            clickable: attributes["clickable"] == "true",
            enabled: attributes["enabled"] == "true",
            focusable: attributes["focusable"] == "true",
            scrollable: attributes["scrollable"] == "true",
            selected: attributes["selected"] == "true",
            checked: attributes["checked"] == "true",
            password: attributes["password"] == "true",
            children: []
        )
        nodeStack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard elementName == "node", let completed = nodeStack.popLast() else { return }
        if nodeStack.isEmpty {
            rootNode = completed
        }
        // Note: simplified — full implementation needs mutable children
    }
}
```

## Best Practices for Testable Accessibility

### For app developers (making apps test-friendly)

1. **Always set `android:id`** on interactive elements — `resource-id` is the most stable selector
2. **Use `android:contentDescription`** for non-text elements (icons, images)
3. **Use `Modifier.testTag()`** in Compose — maps to `resource-id` in UIAutomator
4. **Set `contentDescription = null`** on decorative elements to hide from tree
5. **Use `labelFor`** to associate labels with inputs
6. **Minimum touch target: 48dp × 48dp** — Android enforces this recommendation

### For test automation

1. **Prefer `resource-id`** over text for element lookup (stable across translations)
2. **Wait for the tree to settle** — dump immediately after navigation may miss elements
3. **Check `enabled="true"` and `clickable="true"`** before tapping
4. **Use bounds center** for tap coordinates from `uiautomator dump`
5. **Handle system UI** — status bar, navigation bar, system dialogs can interfere
6. **Compose apps** may show `ComposeView` as a single node — enable semantics for testing

### Element lookup priority

1. `resource-id` — most stable, locale-independent
2. `content-desc` — readable, but changes with localization
3. `text` — visible text, changes with localization and state
4. `class` + position — fragile, use as last resort

### Dealing with dynamic content

```bash
# Wait before dumping (let animations/transitions finish)
sleep 1
adb exec-out uiautomator dump /dev/tty

# For RecyclerView/ListView — scroll and re-dump to find off-screen items
adb shell input swipe 500 1500 500 500 300
sleep 0.5
adb exec-out uiautomator dump /dev/tty
```
