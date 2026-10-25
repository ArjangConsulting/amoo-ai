package com.amoo.companion.bridge

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest

/** Installed-artifact provenance distinguishes a rebuilt checkout from packaged companion APKs. */
object AccessibilityProvenance {
    fun capture(appId: String): Map<String, String> {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val build = runCatching {
            val info = context.packageManager.getPackageInfo(appId, 0)
            "${info.versionName} (${if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode})"
        }.getOrDefault("unavailable from package visibility")
        return mapOf(
            "device_os" to "Android ${android.os.Build.VERSION.RELEASE}, API ${android.os.Build.VERSION.SDK_INT}",
            "companion_apk_sha256" to digest(context.applicationInfo.sourceDir),
            "companion_test_apk_sha256" to digest(instrumentation.context.applicationInfo.sourceDir),
            "app_build" to build,
            "app_build_source" to "installed PackageInfo versionName/versionCode",
            "app_locale" to "unavailable from external inspection",
            "system_font_scale" to context.resources.configuration.fontScale.toString(),
            "device_locale" to context.resources.configuration.locales[0].toLanguageTag()
        )
    }

    private fun digest(path: String): String = runCatching {
        val hash = MessageDigest.getInstance("SHA-256")
        File(path).inputStream().use { stream ->
            val buffer = ByteArray(65536)
            var count = stream.read(buffer)
            while (count != -1) {
                hash.update(buffer, 0, count)
                count = stream.read(buffer)
            }
        }
        hash.digest().joinToString("") { "%02x".format(it) }
    }.getOrDefault("unavailable")
}
