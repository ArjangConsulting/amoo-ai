package com.amoo.companion.bridge

import amoo.v1.AccessibilityInspectionRequest
import amoo.v1.AccessibilityInspectionResponse
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.amoo.companion.MainActivity
import com.amoo.companion.R
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeContrastTests {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val appId = instrumentation.targetContext.packageName
    private val inspector = NativeAccessibilityInspector(UIAutomatorBridge())

    @Test
    fun cleanStatusHasARecordedRatio() = launch("audit-clean").use {
        val report = audit()
        val status = measurement(report, "fixture_audit_status")
        assertTrue("Status text contrast must be at least 4.5:1: $status", status.getDouble("ratio") >= 4.5)
        assertTrue(report.issuesList.none { it.element.id.endsWith(":id/fixture_audit_status") })
    }

    @Test
    fun seededLowContrastRemainsAProviderFinding() = launch("audit").use {
        val report = audit()
        val lowContrast = measurement(report, "fixture_audit_contrast")
        assertEquals(1.01, lowContrast.getDouble("ratio"), 0.02)
        assertTrue(report.issuesList.any {
            it.element.id.endsWith(":id/fixture_audit_contrast") && it.element.semantics.attributesMap["resultType"] == "WARNING"
        })
    }

    @Test
    fun uniformScreenshotRegionRemainsUnassessed() = launch("audit-clean").use { scenario ->
        scenario.onActivity {
            it.findViewById<TextView>(R.id.fixture_audit_contrast).setTextColor(Color.WHITE)
        }
        val report = audit()
        assertTrue(measurements(report).none { it.getString("element_id").endsWith(":id/fixture_audit_contrast") })
        assertTrue(report.notEvaluatedReasonsMap.containsKey("contrast"))
    }

    private fun launch(route: String): ActivityScenario<MainActivity> =
        ActivityScenario.launch(Intent(Intent.ACTION_VIEW, Uri.parse("amoo://$route"), instrumentation.targetContext, MainActivity::class.java))

    private fun audit(): AccessibilityInspectionResponse {
        instrumentation.waitForIdleSync()
        val report = inspector.audit(
            AccessibilityInspectionRequest.newBuilder().setAppId(appId).addCategories("contrast").build()
        )
        assertTrue(report.error, report.error.isEmpty())
        return report
    }

    private fun measurement(report: AccessibilityInspectionResponse, resourceName: String): JSONObject =
        measurements(report).single { it.getString("element_id").endsWith(":id/$resourceName") }

    private fun measurements(report: AccessibilityInspectionResponse): List<JSONObject> {
        val samples = JSONArray(report.getProvenanceOrThrow("contrast_measurements_json"))
        return (0 until samples.length()).map(samples::getJSONObject)
    }
}
