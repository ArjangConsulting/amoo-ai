---
name: ios-accessibility
description: Review or improve UIKit/SwiftUI accessibility and the corresponding amoo companion evidence, using the canonical platform audit and remediation skill.
---

The canonical skill ships in the amoo plugin. Read
[the ios accessibility skill](../../plugins/amoo/skills/ios-accessibility/SKILL.md)
and its linked platform checks when reviewing apps or changing companion evidence.
It covers configurable review scope, standards/impact distinctions, core checks,
LLM finding tags, evidence limitations and source fixes.

For amoo framework changes, also follow repository `AGENTS.md`, the shared protocols and
[the accessibility proposal](../../docs/accessibility-and-voiceover.md). Verify the changed
companion separately from SwiftPM, preserve unavailable metadata, and run final lint.
