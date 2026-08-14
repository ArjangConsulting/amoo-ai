package com.amoo.companion.server

import com.amoo.companion.bridge.UIAutomatorBridge
import com.amoo.companion.handlers.AccessibilityHandler
import com.amoo.companion.handlers.GestureHandler
import com.amoo.companion.handlers.TextHandler
import com.amoo.companion.handlers.TouchHandler
import io.grpc.Server
import io.grpc.netty.NettyServerBuilder

/**
 * Manages the gRPC server lifecycle for the Android companion.
 *
 * The server runs inside an Android instrumentation test. The test method
 * starts the server and blocks, keeping the companion alive to accept
 * commands from the host.
 */
class CompanionServer(
    private val bridge: UIAutomatorBridge,
    private val port: Int = 22088
) {
    private val touch = TouchHandler(bridge)
    private val gesture = GestureHandler(bridge)
    private val text = TextHandler(bridge)
    private val accessibility = AccessibilityHandler(bridge)

    private var server: Server? = null

    /**
     * Start the gRPC server on the configured port.
     *
     * Implementation note: The actual gRPC server setup will use grpc-java
     * (io.grpc:grpc-netty) with the proto-generated stubs compiled into
     * this target.
     */
    fun start() {
        server = NettyServerBuilder.forPort(port)
            .addService(CompanionServiceImpl(touch, gesture, text, accessibility))
            .intercept(DescriptionBackfillInterceptor())
            .build()
            .start()
        println("[CompanionServer] Ready on port $port")
    }

    fun stop() {
        server?.shutdownNow()
        println("[CompanionServer] Shutting down")
    }

    fun blockUntilShutdown() {
        server?.awaitTermination()
    }
}
