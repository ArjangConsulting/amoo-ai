package com.amoo.companion.bridge

import android.app.UiAutomation
import android.content.ComponentName
import android.os.SystemClock
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import amoo.v1.AccessibilityInspectionRequest
import amoo.v1.AccessibilityInspectionResponse
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.util.UUID

/** Observes actual TalkBack focus and synthesis input; capture-engine output is intentionally silent. */
class TalkBackInspector(private val bridge: UIAutomatorBridge) {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val automation get() = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)

    fun inspect(request: AccessibilityInspectionRequest, isCancelled: () -> Boolean = { false }): AccessibilityInspectionResponse {
        val checks = (0 until request.steps).map { "talkBack.move.$it" } +
            if (request.activate) listOf("talkBack.activation") else emptyList()
        val result = AccessibilityInspectionResponse.newBuilder().setProvider("androidTalkBack")
            .setStatus("unsupported").addAllRequestedChecks(checks)
            .addLimitations("Speech evidence contains actual TalkBack TTS synthesis requests; the temporary engine renders silence.")
            .addLimitations("This does not verify audible output, whole-app conformance, rotor actions, or other screen readers.")
        checks.forEach { result.putNotEvaluatedReasons(it, "Traversal did not complete") }
        if (request.steps !in 1..30 || request.direction !in listOf("forward", "backward")) {
            return result.setError("Requires 1...30 forward/backward moves").build()
        }
        val expectations = if (request.speechExpectationsJson.isBlank()) null else
            runCatching { JSONArray(request.speechExpectationsJson) }.getOrNull()
        if (!request.speechExpectationsJson.isBlank()) {
            result.putProvenance("speech_expectations_json", request.speechExpectationsJson)
            if (expectations == null || expectations.length() != request.steps || request.activate) {
                return result.setError("Speech assertions require one expectation per move and no activation").build()
            }
            for (index in 0 until expectations.length()) {
                val item = expectations.optJSONObject(index)
                if (item == null || item.has("equals") == item.has("contains") || item.has("elementID")) {
                    return result.setError("Each speech expectation requires exactly one of equals/contains").build()
                }
            }
        }
        val manager = context.getSystemService(AccessibilityManager::class.java)
        val talkBack = manager.installedAccessibilityServiceList.firstOrNull {
            it.resolveInfo.serviceInfo.name.endsWith(".TalkBackService") &&
                it.resolveInfo.serviceInfo.packageName in setOf("com.google.android.marvin.talkback", "com.samsung.android.accessibility.talkback")
        } ?: return result.setError("A supported TalkBack installation is required; no settings were changed").build()
        if (bridge.currentPackageName() != request.appId) {
            return result.setError("Requested app must be foreground before TalkBack starts").build()
        }
        val service = talkBack.resolveInfo.serviceInfo
        val component = ComponentName(service.packageName, service.name).flattenToString()
        val token = UUID.randomUUID().toString()
        val recovery = TalkBackRecovery()
        var original: JSONObject? = null
        var input: TalkBackInput? = null
        try {
            recovery.recoverPending()
            input = TalkBackInput(automation)
            result.putProvenance("input_route", "temporary uinput keyboard; TalkBack default Alt+Left/Right and Alt+Enter shortcuts")
            result.addLimitations("Keyboard traversal only; touch gestures and custom keyboard mappings are not qualified.")
            original = recovery.begin(token, service.applicationInfo.uid, component)
            result.status = "executionError"
            result.putProvenance("capture_reference", token)
            result.putProvenance("screen_reader_component", component)
            result.putProvenance("screen_reader_version", context.packageManager.getPackageInfo(service.packageName, 0).versionName.orEmpty())
            result.putProvenance("speech_source", "TalkBack UID ${service.applicationInfo.uid}; TextToSpeechService.onSynthesizeText")
            result.putProvenance("capture_engine", context.packageName)
            recovery.enableCapture(original)
            awaitCaptureReady(token, request.appId)
            check(bridge.currentPackageName() == request.appId) { "TalkBack changed foreground; target traversal withheld" }
            awaitSpeech(token, 0)
            input.first()
            SystemClock.sleep(300)
            awaitSpeech(token, utterances(token).size)
            val initialFocus = focus()
            check(initialFocus != null && initialFocus.packageName == request.appId) { "Initial app-owned TalkBack focus unavailable" }
            result.putProvenance("initial_focus", initialFocus.description())
            result.putProvenance("initial_navigation", "Alt+Ctrl+Left sent before requested moves; default keymap first-item command")
            var offset = utterances(token).size
            var assertionFailed = false
            for (index in 0 until request.steps) {
                check(!Thread.currentThread().isInterrupted && !isCancelled()) { "Traversal cancelled" }
                val before = focus()
                input.move(request.direction == "forward")
                val after = awaitFocusChange(before)
                val captured = awaitSpeech(token, offset)
                offset += captured.size
                result.addAllUtterances(captured)
                result.addPhases(amoo.v1.VoiceOverPhaseObservation.newBuilder()
                    .setPhaseIndex(index).setRequestedSteps(1).setDirection(request.direction)
                    .addAllUtterances(captured).build())
                val check = "talkBack.move.$index"
                if (after != null && after != before && after.packageName == request.appId && captured.isNotEmpty()) {
                    result.addEvaluatedChecks(check)
                    result.removeNotEvaluatedReasons(check)
                    result.putProvenance("focus.$index", after.description())
                    if (expectations != null) {
                        val expectation = expectations.getJSONObject(index)
                        val actual = captured.joinToString(" ")
                        val matched = if (expectation.has("equals")) actual == expectation.getString("equals")
                            else actual.contains(expectation.getString("contains"))
                        assertionFailed = assertionFailed || !matched
                        result.putProvenance("speech_match.$index", if (matched) "pass" else "fail")
                    }
                } else {
                    result.putNotEvaluatedReasons(check, "Focus change and app-scoped synthesis speech were not both observed")
                }
            }
            if (request.activate) {
                val target = automation.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
                try {
                    check(target != null && target.packageName?.toString() == request.appId) {
                        "Activation requires an observed app-owned accessibility focus target"
                    }
                    input.activate()
                    result.putProvenance("activation_dispatch", "keyboard shortcut sent; application postcondition unverified")
                    result.putNotEvaluatedReasons("talkBack.activation", "Activation shortcut sent; assert an explicit app postcondition separately")
                    result.addAllUtterances(awaitSpeech(token, offset))
                } finally {
                    target?.recycle()
                }
            }
            result.status = if (expectations == null) "observed"
                else if (assertionFailed) "fail" else if (result.notEvaluatedReasonsCount == 0) "pass" else "observed"
        } catch (error: Exception) {
            result.error = "TalkBack inspection failed: ${error.javaClass.simpleName}: ${error.message}"
            android.util.Log.e("AmooTalkBack", "Traversal failed: ${error.javaClass.simpleName}")
        } finally {
            try {
                input?.close()
                result.putProvenance("input_cleanup", "removed")
            } catch (error: Exception) {
                result.cleanupError = "Temporary input cleanup failed: ${error.javaClass.simpleName}"
            }
            if (original != null) {
                try {
                    result.putAllProvenance(recovery.restore(original))
                } catch (error: Exception) {
                    result.cleanupError = "TalkBack restoration failed: ${error.javaClass.simpleName}: ${error.message}"
                    result.putProvenance("restoration_status", "failed")
                }
            }
        }
        return result.build()
    }

    private data class Focus(val packageName: String, val id: String, val bounds: String, val label: String) {
        fun description(): String = "$packageName/$id bounds=$bounds"
    }

    private fun focus(): Focus? {
        val node = automation.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY) ?: return null
        return try {
            val bounds = android.graphics.Rect().also { node.getBoundsInScreen(it) }
            Focus(node.packageName?.toString().orEmpty(), node.viewIdResourceName.orEmpty(), bounds.toShortString(),
                node.contentDescription?.toString() ?: node.text?.toString().orEmpty())
        } finally { node.recycle() }
    }

    private fun awaitFocusChange(before: Focus?): Focus? {
        val deadline = SystemClock.elapsedRealtime() + 2500
        do {
            val current = focus()
            if (current != null && current != before) return current
            SystemClock.sleep(100)
        } while (SystemClock.elapsedRealtime() < deadline)
        return focus()
    }

    private fun awaitCaptureReady(token: String, appId: String) {
        val deadline = SystemClock.elapsedRealtime() + 10000
        do {
            if (bridge.currentPackageName() == appId && utterances(token).isNotEmpty()) return
            SystemClock.sleep(100)
        } while (SystemClock.elapsedRealtime() < deadline)
        if (bridge.currentPackageName() != appId) {
            error("TalkBack startup opened another app or a system permission prompt; complete its first-run setup before retrying")
        }
        error("TalkBack did not produce a qualified synthesis request before startup deadline")
    }

    private fun awaitSpeech(token: String, offset: Int): List<String> {
        val deadline = SystemClock.elapsedRealtime() + 3500
        var previous = emptyList<String>()
        var unchangedSince = SystemClock.elapsedRealtime()
        do {
            val current = utterances(token).drop(offset)
            if (current != previous) {
                previous = current
                unchangedSince = SystemClock.elapsedRealtime()
            }
            if (current.isNotEmpty() && SystemClock.elapsedRealtime() - unchangedSince >= 650) return current
            SystemClock.sleep(50)
        } while (SystemClock.elapsedRealtime() < deadline)
        return previous
    }

    private fun utterances(token: String): List<String> {
        val file = File(context.filesDir, "amoo-speech-$token.jsonl")
        if (!file.exists()) return emptyList()
        val text = file.readText()
        return text.substringBeforeLast('\n', "").lineSequence().filter { it.isNotBlank() }
            .mapNotNull { runCatching { JSONObject(it).getString("text") }.getOrNull() }
            .filter { it.isNotBlank() }.take(512).toList()
    }
}
