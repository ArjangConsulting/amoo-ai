package com.amoo.companion.server

import com.amoo.companion.bridge.UIAutomatorBridge
import com.amoo.companion.handlers.AccessibilityHandler
import com.amoo.companion.handlers.GestureHandler
import com.amoo.companion.handlers.TextHandler
import com.amoo.companion.handlers.TouchHandler
import io.grpc.Server
import io.grpc.netty.NettyServerBuilder
import java.net.InetAddress
import java.net.InetSocketAddress

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
        // Bind the ipv4 wildcard explicitly rather than `forPort(port)`. On this image both land
        // on a dual-stack `tcp6 [::]:<port>` socket (that is just how the JDK renders an ipv4
        // wildcard while `java.net.preferIPv4Stack` is false), and that socket already accepts the
        // ipv4-mapped connections `adb forward` makes — its device end always dials ipv4
        // `127.0.0.1:<port>`. The explicit `0.0.0.0` documents that requirement and keeps the
        // listener reachable even if a future image flips `preferIPv4Stack` or sets
        // `IPV6_V6ONLY`, either of which would otherwise leave a `forPort` listener refusing every
        // forwarded connection while still showing a LISTEN socket in `netstat` — from the host,
        // indistinguishable from a companion that is slow to start.
        server = NettyServerBuilder.forAddress(InetSocketAddress(InetAddress.getByName("0.0.0.0"), port))
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
