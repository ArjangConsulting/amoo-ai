package com.amoo.companion.bridge

import com.google.android.apps.common.testing.accessibility.framework.AccessibilityHierarchyCheckResult
import com.google.android.apps.common.testing.accessibility.framework.Parameters
import com.google.android.apps.common.testing.accessibility.framework.checks.TextContrastCheck
import com.google.android.apps.common.testing.accessibility.framework.uielement.AccessibilityHierarchy
import com.google.android.apps.common.testing.accessibility.framework.uielement.ViewHierarchyElement
import com.google.android.apps.common.testing.accessibility.framework.utils.contrast.ContrastUtils
import org.json.JSONObject

internal object AtfContrastMeasurements {
    private const val MAX_CONTRAST_RATIO = 21.0
    private const val MEASUREMENT_THRESHOLD = MAX_CONTRAST_RATIO + 1.0
    private val replacedResultIds = setOf(
        TextContrastCheck.RESULT_ID_COULD_NOT_GET_TEXT_COLOR,
        TextContrastCheck.RESULT_ID_COULD_NOT_GET_BACKGROUND_COLOR,
        TextContrastCheck.RESULT_ID_BACKGROUND_MUST_BE_OPAQUE,
    )

    data class Measurement(val ratio: Double, val foreground: Int, val background: Int, val source: String) {
        fun toJson(reference: String, element: ViewHierarchyElement): JSONObject = JSONObject()
            .put("reference", reference)
            .put("element_id", element.resourceName.orEmpty())
            .put("ratio", ratio)
            .put("foreground", ContrastUtils.colorToHexString(foreground))
            .put("background", ContrastUtils.colorToHexString(background))
            .put("source", source)
    }

    fun capture(
        check: TextContrastCheck,
        hierarchy: AccessibilityHierarchy,
        parameters: Parameters,
    ): Map<ViewHierarchyElement, Measurement> {
        val measurementParameters = parameters.clone().apply { putCustomTextContrastRatio(MEASUREMENT_THRESHOLD) }
        return check.runCheckOnHierarchy(hierarchy, null, measurementParameters)
            .mapNotNull { result ->
                val element = result.element ?: return@mapNotNull null
                measurement(result)?.let { element to it }
            }
            .groupBy({ it.first }, { it.second })
            .mapValues { (_, samples) -> samples.minBy { it.ratio } }
    }

    fun hasFallbackMeasurement(
        result: AccessibilityHierarchyCheckResult,
        measurements: Map<ViewHierarchyElement, Measurement>,
    ): Boolean = result.resultId in replacedResultIds && result.element in measurements

    private fun measurement(result: AccessibilityHierarchyCheckResult): Measurement? {
        val source = when (result.resultId) {
            TextContrastCheck.RESULT_ID_CUSTOMIZED_TEXTVIEW_HEURISTIC_CONTRAST_NOT_SUFFICIENT -> "screenshotEstimate"
            TextContrastCheck.RESULT_ID_CUSTOMIZED_TEXTVIEW_CONTRAST_NOT_SUFFICIENT -> "renderingMetadata"
            else -> return null
        }
        val metadata = result.metadata ?: return null
        if (metadata.getBoolean(TextContrastCheck.KEY_IS_POTENTIALLY_OBSCURED, false) ||
            metadata.getBoolean(TextContrastCheck.KEY_IS_AGAINST_SCROLLABLE_EDGE, false)) return null
        val foregroundKey = if (source == "screenshotEstimate") TextContrastCheck.KEY_FOREGROUND_COLOR
            else TextContrastCheck.KEY_TEXT_COLOR
        if (!metadata.containsKey(foregroundKey) || !metadata.containsKey(TextContrastCheck.KEY_BACKGROUND_COLOR)) return null
        val ratio = metadata.getDouble(TextContrastCheck.KEY_CONTRAST_RATIO, Double.NaN)
        if (ratio !in 1.0..MAX_CONTRAST_RATIO) return null
        return Measurement(ratio, metadata.getInt(foregroundKey), metadata.getInt(TextContrastCheck.KEY_BACKGROUND_COLOR), source)
    }
}
