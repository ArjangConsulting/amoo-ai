package com.manman.companion

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.manman.companion.bridge.UIAutomatorBridge
import com.manman.companion.server.CompanionServer
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
 * 3. Host forwards port 22088 via `adb forward`
 * 4. Host sends gRPC commands to localhost:22088
 * 5. Host terminates the instrumentation when done
 */
@RunWith(AndroidJUnit4::class)
class CompanionRunner {

    @Test
    fun runCompanion() {
        val bridge = UIAutomatorBridge()
        val server = CompanionServer(bridge, port = 22088)

        server.start()
        server.blockUntilShutdown()
    }
}
