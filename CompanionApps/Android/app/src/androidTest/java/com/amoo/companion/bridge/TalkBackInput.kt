package com.amoo.companion.bridge

import android.app.UiAutomation
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Hardware-level keyboard input reaches TalkBack; UiAutomation-injected motion bypasses its input filter. */
class TalkBackInput(automation: UiAutomation) : AutoCloseable {
    private val name = "amoo-talkback-${UUID.randomUUID()}"
    private var descriptors = emptyArray<ParcelFileDescriptor>()
    private var stream: ParcelFileDescriptor.AutoCloseOutputStream? = null

    init {
        check(Build.VERSION.SDK_INT >= 31) { "TalkBack input requires Android 12+ shell streaming support" }
        try {
            descriptors = automation.executeShellCommandRw("uinput -")
            stream = ParcelFileDescriptor.AutoCloseOutputStream(descriptors[1])
            val configuration = JSONArray()
                .put(JSONObject().put("type", 100).put("data", JSONArray(listOf(1))))
                .put(JSONObject().put("type", 101).put("data", JSONArray(listOf(28, 29, 56, 105, 106))))
            send(JSONObject().put("id", 1).put("command", "register").put("name", name)
                .put("vid", 6353).put("pid", 19790).put("bus", "usb").put("configuration", configuration))
            val deadline = SystemClock.elapsedRealtime() + 4000
            while (!isRegistered() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50)
            check(isRegistered()) { "The device does not permit registering a temporary uinput keyboard" }
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    fun move(forward: Boolean) = shortcut(if (forward) 106 else 105)

    fun activate() = shortcut(28)

    fun first() = shortcut(105, control = true)

    private fun shortcut(key: Int, control: Boolean = false) {
        send(JSONObject().put("id", 1).put("command", "updateTimeBase"))
        if (control) inject(1, 29, 1, 0, 0, 0)
        inject(1, 56, 1, 0, 0, 0, 1, key, 1, 0, 0, 0)
        send(JSONObject().put("id", 1).put("command", "delay").put("duration", 50))
        inject(1, key, 0, 0, 0, 0, 1, 56, 0, 0, 0, 0)
        if (control) inject(1, 29, 0, 0, 0, 0)
        SystemClock.sleep(100)
    }

    private fun inject(vararg events: Int) = send(JSONObject().put("id", 1).put("command", "inject")
        .put("events", JSONArray(events.toList())))

    private fun send(command: JSONObject) {
        checkNotNull(stream).apply {
            write((command.toString() + "\n").toByteArray(Charsets.UTF_8))
            flush()
        }
    }

    private fun isRegistered(): Boolean = InputDevice.getDeviceIds().any { InputDevice.getDevice(it)?.name == name }

    override fun close() {
        stream?.close()
        stream = null
        descriptors.firstOrNull()?.close()
        descriptors = emptyArray()
        val deadline = SystemClock.elapsedRealtime() + 2000
        while (isRegistered() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50)
        check(!isRegistered()) { "Temporary TalkBack keyboard removal was not observed" }
    }
}
