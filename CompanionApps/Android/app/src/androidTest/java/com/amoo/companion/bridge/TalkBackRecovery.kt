package com.amoo.companion.bridge

import android.app.UiAutomation
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.os.SystemClock
import android.view.accessibility.AccessibilityManager
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import java.io.File

/** Durable setting restoration; recovery runs before accepting requests after an interrupted traversal. */
class TalkBackRecovery {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val automation get() = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
    private val journalFile = File(context.noBackupFilesDir, "amoo-talkback-recovery.json")
    private val keys = listOf("enabled_accessibility_services", "accessibility_enabled", "tts_default_synth")

    companion object {
        const val NOTIFICATION_PERMISSION = "android.permission.POST_NOTIFICATIONS"
        val TALKBACK_PACKAGES = setOf("com.google.android.marvin.talkback", "com.samsung.android.accessibility.talkback")
    }

    fun recoverPending(): Map<String, String> {
        if (!journalFile.exists()) return emptyMap()
        return restore(JSONObject(journalFile.readText()))
    }

    fun begin(token: String, uid: Int, component: String): JSONObject {
        check(!journalFile.exists()) { "Pending TalkBack recovery must complete before another traversal" }
        val original = JSONObject().put("token", token).put("component", component)
        keys.forEach { original.put(it, Settings.Secure.getString(context.contentResolver, it) ?: JSONObject.NULL) }
        persistJournal(original)
        val marker = JSONObject().put("token", token).put("uid", uid)
        File(context.noBackupFilesDir, "amoo-speech-capture.json").writeText(marker.toString())
        return original
    }

    fun notePendingPermissionGrant(original: JSONObject, packageName: String): Boolean {
        require(packageName in TALKBACK_PACKAGES) { "Permission bookkeeping is scoped to known TalkBack packages" }
        val alreadyGranted = context.packageManager.checkPermission(NOTIFICATION_PERMISSION, packageName) == PackageManager.PERMISSION_GRANTED
        if (alreadyGranted) return false
        original.put("permission_package", packageName)
        persistJournal(original)
        return true
    }

    private fun persistJournal(contents: JSONObject) {
        val temporary = File(journalFile.path + ".tmp")
        temporary.writeText(contents.toString())
        check(temporary.renameTo(journalFile)) { "Could not persist TalkBack recovery journal" }
    }

    fun enableCapture(original: JSONObject) {
        val component = original.getString("component")
        val originalServices = value(original, "enabled_accessibility_services").orEmpty()
            .split(':').filter { it.isNotBlank() }
        put("enabled_accessibility_services", originalServices.filter { it != component }.joinToString(":"))
        waitForService(component, enabled = false)
        put("tts_default_synth", context.packageName)
        put("enabled_accessibility_services", (originalServices + component).distinct().joinToString(":"))
        put("accessibility_enabled", "1")
        waitForService(component, enabled = true)
    }

    fun restore(original: JSONObject): Map<String, String> {
        val component = original.getString("component")
        val services = Settings.Secure.getString(context.contentResolver, "enabled_accessibility_services")
            .orEmpty().split(':').filter { it.isNotBlank() && it != component }
        put("enabled_accessibility_services", services.joinToString(":"))
        waitForService(component, enabled = false)
        val evidence = mutableMapOf<String, String>()
        revokePendingPermissionGrant(original, evidence)
        put("tts_default_synth", value(original, "tts_default_synth"))
        put("enabled_accessibility_services", value(original, "enabled_accessibility_services"))
        put("accessibility_enabled", value(original, "accessibility_enabled"))
        val wasEnabled = value(original, "enabled_accessibility_services").orEmpty().split(':').contains(component)
        waitForService(component, enabled = wasEnabled)
        var matched = true
        keys.forEach {
            val actual = Settings.Secure.getString(context.contentResolver, it)
            val expected = value(original, it)
            evidence["original_$it"] = expected ?: "<null>"
            evidence["restored_$it"] = actual ?: "<null>"
            matched = matched && actual == expected
        }
        check(matched) { "TalkBack restoration verification did not match original settings" }
        File(context.noBackupFilesDir, "amoo-speech-capture.json").delete()
        File(context.noBackupFilesDir, "amoo-speech-${original.getString("token")}.jsonl").delete()
        // A capture started by an older companion wrote these under filesDir; remove them best effort.
        File(context.filesDir, "amoo-speech-capture.json").delete()
        File(context.filesDir, "amoo-speech-${original.getString("token")}.jsonl").delete()
        if (evidence["permission_restoration_status"] != "pending") {
            check(journalFile.delete()) { "Settings restored but recovery journal could not be cleared" }
        }
        evidence["restoration_status"] = "restored"
        return evidence
    }

    private fun revokePendingPermissionGrant(original: JSONObject, evidence: MutableMap<String, String>) {
        if (!original.has("permission_package")) return
        val packageName = original.getString("permission_package")
        val granted = context.packageManager.checkPermission(NOTIFICATION_PERMISSION, packageName) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            evidence["permission_restoration_status"] = "not_granted"
            return
        }
        val outcome = runCatching { automation.revokeRuntimePermission(packageName, NOTIFICATION_PERMISSION) }
        val stillGranted = context.packageManager.checkPermission(NOTIFICATION_PERMISSION, packageName) == PackageManager.PERMISSION_GRANTED
        evidence["permission_restoration_status"] = if (outcome.isSuccess && !stillGranted) "revoked" else "pending"
    }

    private fun value(original: JSONObject, key: String): String? =
        if (original.isNull(key)) null else original.getString(key)

    private fun put(key: String, value: String?) {
        automation.adoptShellPermissionIdentity(android.Manifest.permission.WRITE_SECURE_SETTINGS)
        try {
            check(Settings.Secure.putString(context.contentResolver, key, value)) { "Could not update $key" }
        } finally {
            automation.dropShellPermissionIdentity()
        }
    }

    private fun waitForService(component: String, enabled: Boolean) {
        val manager = context.getSystemService(AccessibilityManager::class.java)
        val deadline = SystemClock.elapsedRealtime() + 8000
        do {
            val live = manager.getEnabledAccessibilityServiceList(-1).any {
                android.content.ComponentName(it.resolveInfo.serviceInfo.packageName, it.resolveInfo.serviceInfo.name)
                    .flattenToString() == component
            }
            if (live == enabled) return
            SystemClock.sleep(100)
        } while (SystemClock.elapsedRealtime() < deadline)
        error("TalkBack service did not reach enabled=$enabled before its deadline")
    }
}
