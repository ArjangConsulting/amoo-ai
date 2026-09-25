package com.amoo.companion

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.amoo.companion.bridge.UIAutomatorBridge
import com.amoo.companion.server.CompanionServer
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Android instrumentation test entry point for the companion app.
 *
 * This test is designed to never finish — it starts the gRPC companion
 * server and blocks, keeping the companion alive to accept commands from
 * the host driver.
 *
 * The host driver controls the companion's lifecycle:
 * 1. Host installs the companion APK and test APK via `adb`
 * 2. Host runs this test via `adb shell am instrument`
 *    with `-e port <port>` (default 22088)
 * 3. Host forwards host `<port>` → device `<port>` via `adb forward`
 * 4. Host sends gRPC commands to localhost:<port>
 * 5. Host terminates the instrumentation when done
 */
@RunWith(AndroidJUnit4::class)
class CompanionRunner {

    @Test
    fun runCompanion() {
        val bridge = UIAutomatorBridge()
        val server = CompanionServer(bridge, port = requestedPort())

        server.start()
        server.blockUntilShutdown()
    }

    /** The `-e port` instrumentation argument, falling back to the default companion port. */
    private fun requestedPort(): Int =
        InstrumentationRegistry.getArguments().getString("port")?.toIntOrNull()
            ?.takeIf { it in 1..65535 }
            ?: DEFAULT_PORT

    private companion object {
        const val DEFAULT_PORT = 22088
    }
}
