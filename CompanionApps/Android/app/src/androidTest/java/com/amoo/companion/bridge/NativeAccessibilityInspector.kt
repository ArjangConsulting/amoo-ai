package com.amoo.companion.bridge

import amoo.v1.AccessibilityInspectionIssue
import amoo.v1.AccessibilityInspectionRequest
import amoo.v1.AccessibilityInspectionResponse
import amoo.v1.ElementInfo
import amoo.v1.ElementSemantics
import amoo.v1.Rect
import androidx.test.platform.app.InstrumentationRegistry
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityCheckResult.AccessibilityCheckResultType
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityHierarchyCheck
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityHierarchyCheckResult
import com.google.android.apps.common.testing.accessibility.framework.Parameters
import com.google.android.apps.common.testing.accessibility.framework.checks.DuplicateSpeakableTextCheck
import com.google.android.apps.common.testing.accessibility.framework.checks.EditableContentDescCheck
import com.google.android.apps.common.testing.accessibility.framework.checks.SpeakableTextPresentCheck
import com.google.android.apps.common.testing.accessibility.framework.checks.TextContrastCheck
import com.google.android.apps.common.testing.accessibility.framework.checks.TouchTargetSizeCheck
import com.google.android.apps.common.testing.accessibility.framework.uielement.AccessibilityHierarchyAndroid
import com.google.android.apps.common.testing.accessibility.framework.uielement.ViewHierarchyElement
import com.google.android.apps.common.testing.accessibility.framework.utils.contrast.BitmapImage
import java.util.Locale
import java.util.UUID

class NativeAccessibilityInspector(private val bridge: UIAutomatorBridge) {
    fun audit(request: AccessibilityInspectionRequest, isCancelled: () -> Boolean = { false }): AccessibilityInspectionResponse {
        val capture = UUID.randomUUID().toString()
        val result = AccessibilityInspectionResponse.newBuilder()
            .setProvider("androidNativeATF").setStatus("executionError")
            .addAllRequestedChecks(request.categoriesList)
            .putProvenance("provider_version", "4.1.1")
            .putProvenance("capture_reference", capture)
            .putProvenance("hierarchy_source", "AccessibilityNodeInfo; target app only; IME/system windows excluded")
            .addLimitations("Current presentation only. ATF findings do not establish whole-app conformance or TalkBack speech.")
            .addLimitations("Cross-app rendering metadata may be unavailable. Contrast uses a screenshot heuristic when possible.")
        request.categoriesList.forEach { result.putNotEvaluatedReasons(it, "Provider did not complete") }
        try {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            bridge.withAppAccessibilityRoot(request.appId) { root ->
                val hierarchy = AccessibilityHierarchyAndroid.newBuilder(root, instrumentation.targetContext).build()
                val screenshot = instrumentation.getUiAutomation(
                    android.app.UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES
                ).takeScreenshot()
                try {
                    val parameters = Parameters()
                    screenshot?.let { parameters.putScreenCapture(BitmapImage(it)) }
                    for (category in request.categoriesList.distinct()) {
                        check(!isCancelled()) { "Native audit cancelled before check completion" }
                        val check = checkFor(category)
                        if (check == null) {
                            result.putNotEvaluatedReasons(category, "No qualified Android ATF check for this category")
                            continue
                        }
                        val findings = check.runCheckOnHierarchy(hierarchy, null, parameters)
                        val missing = findings.filter { insufficientData(check, it) }
                        if (missing.isEmpty()) {
                            result.addEvaluatedChecks(category)
                            result.removeNotEvaluatedReasons(category)
                        } else {
                            result.putNotEvaluatedReasons(category,
                                "ATF could not evaluate ${missing.size} target(s); result IDs=${missing.map { it.resultId }.distinct()}")
                        }
                        for (finding in findings.filter {
                            it.type == AccessibilityCheckResultType.ERROR || it.type == AccessibilityCheckResultType.WARNING || insufficientData(check, it)
                        }) {
                            if (result.issuesCount >= 512) {
                                result.truncated = true
                                break
                            }
                            result.addIssues(issue(category, finding, capture))
                        }
                    }
                } finally {
                    screenshot?.recycle()
                }
            }
            val errors = result.issuesList.any { it.element.semantics.attributesMap["resultType"] == "ERROR" }
            result.status = if (errors) "fail" else if (result.issuesCount > 0) "observed" else "pass"
        } catch (error: Exception) {
            android.util.Log.e("AmooNativeAudit", "Audit execution failed: ${error.javaClass.simpleName}")
            result.error = "Android ATF capture/check failed: ${error.javaClass.simpleName}: ${error.message}"
        }
        return result.build()
    }

    private fun checkFor(category: String): AccessibilityHierarchyCheck? = when (category) {
        "sufficientElementDescription" -> SpeakableTextPresentCheck()
        "hitRegion" -> TouchTargetSizeCheck()
        "contrast" -> TextContrastCheck()
        "duplicateSpeakableText" -> DuplicateSpeakableTextCheck()
        "editableContentDescription" -> EditableContentDescCheck()
        else -> null
    }

    private fun insufficientData(check: AccessibilityHierarchyCheck, result: AccessibilityHierarchyCheckResult): Boolean {
        if (result.type != AccessibilityCheckResultType.NOT_RUN) return false
        if (check is TouchTargetSizeCheck) {
            return result.resultId !in setOf(TouchTargetSizeCheck.RESULT_ID_NOT_CLICKABLE, TouchTargetSizeCheck.RESULT_ID_NOT_VISIBLE)
        }
        if (check is SpeakableTextPresentCheck) {
            return result.resultId !in setOf(SpeakableTextPresentCheck.RESULT_ID_NOT_VISIBLE,
                SpeakableTextPresentCheck.RESULT_ID_NOT_IMPORTANT_FOR_ACCESSIBILITY, SpeakableTextPresentCheck.RESULT_ID_SHOULD_NOT_FOCUS)
        }
        return check is TextContrastCheck && result.resultId !in setOf(
            TextContrastCheck.RESULT_ID_NOT_VISIBLE, TextContrastCheck.RESULT_ID_NOT_TEXT_VIEW,
            TextContrastCheck.RESULT_ID_TEXTVIEW_EMPTY, TextContrastCheck.RESULT_ID_NOT_ENABLED
        )
    }

    private fun issue(category: String, finding: AccessibilityHierarchyCheckResult, capture: String): AccessibilityInspectionIssue {
        val element = finding.element
        val info = ElementInfo.newBuilder()
        val semantics = ElementSemantics.newBuilder()
            .setReference("$capture:atf:${element?.condensedUniqueId ?: "unavailable"}")
            .putAttributes("provider", "androidNativeATF")
            .putAttributes("providerVersion", "4.1.1")
            .putAttributes("coordinateUnit", "pixels")
            .putAttributes("resultType", finding.type.name)
            .putAttributes("resultId", finding.resultId.toString())
            .putAttributes("sourceCheck", finding.sourceCheckClass?.simpleName.orEmpty())
            .putAttributes("fullBoundsAvailability", "unavailable unless ATF reports nonclipped dimensions")
        finding.metadata?.let { metadata ->
            listOf("KEY_HAS_TOUCH_DELEGATE", "KEY_HAS_TOUCH_DELEGATE_WITH_HIT_RECT", "KEY_HAS_CLICKABLE_ANCESTOR",
                "KEY_IS_AGAINST_SCROLLABLE_EDGE", "KEY_IS_CLIPPED_BY_ANCESTOR", "KEY_IS_WEB_CONTENT").forEach { key ->
                if (metadata.containsKey(key)) semantics.putAttributes("atf.$key", metadata.getBoolean(key).toString())
            }
            listOf("KEY_WIDTH", "KEY_HEIGHT", "KEY_NONCLIPPED_WIDTH", "KEY_NONCLIPPED_HEIGHT", "KEY_REQUIRED_WIDTH",
                "KEY_REQUIRED_HEIGHT", "KEY_CUSTOMIZED_REQUIRED_WIDTH", "KEY_CUSTOMIZED_REQUIRED_HEIGHT",
                "KEY_HIT_RECT_WIDTH", "KEY_HIT_RECT_HEIGHT").forEach { key ->
                if (metadata.containsKey(key)) semantics.putAttributes("atf.$key", metadata.getInt(key).toString())
            }
            semantics.putAttributes("atf.measurementUnit", "dp; element bounds remain pixels")
        }
        if (element != null) {
            info.id = element.resourceName.orEmpty()
            info.label = element.contentDescription?.toString()?.ifBlank { null } ?: element.text?.toString().orEmpty()
            info.value = element.text?.toString().orEmpty()
            info.type = element.className?.toString().orEmpty()
            val bounds = element.boundsInScreen
            val rect = Rect.newBuilder().setX(bounds.left.toDouble()).setY(bounds.top.toDouble())
                .setWidth(bounds.width.toDouble()).setHeight(bounds.height.toDouble()).build()
            info.frame = rect
            semantics.visibleFrame = rect
            semantics.hierarchyPath = path(element)
            element.parentView?.let { semantics.parentReference = "$capture:atf:${it.condensedUniqueId}" }
            element.stateDescription?.let { semantics.stateDescription = it.toString() }
            semantics.putAttributes("origin", element.origin.name)
            element.nonclippedHeight?.let { semantics.putAttributes("nonclippedHeight", it.toString()) }
            element.nonclippedWidth?.let { semantics.putAttributes("nonclippedWidth", it.toString()) }
        } else {
            semantics.putAttributes("targetAvailability", "unavailable from ATF result")
        }
        info.semantics = semantics.build()
        return AccessibilityInspectionIssue.newBuilder().setCategory(category)
            .setDescription(finding.getMessage(Locale.getDefault()).toString().take(8192))
            .setDetails("${finding.sourceCheckClass?.simpleName}: resultId=${finding.resultId}, type=${finding.type}")
            .setElement(info).build()
    }

    private fun path(element: ViewHierarchyElement): String {
        val identifiers = mutableListOf<String>()
        var current: ViewHierarchyElement? = element
        while (current != null && identifiers.size < 256) {
            identifiers.add(current.id.toString())
            current = current.parentView
        }
        return identifiers.reversed().joinToString("/")
    }
}
