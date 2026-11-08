package com.amoo.companion.server

import io.grpc.ForwardingServerCall.SimpleForwardingServerCall
import io.grpc.Metadata
import io.grpc.ServerCall
import io.grpc.ServerCallHandler
import io.grpc.ServerInterceptor
import io.grpc.Status
import java.util.Locale

/**
 * Reports how long the companion spent on each RPC in the `amoo-server-ms` trailer, so the host's
 * OpenTelemetry RPC span can separate on-device work (UIAutomator queries, gestures, captures)
 * from transport and host overhead.
 */
class ServerTimingInterceptor : ServerInterceptor {
    override fun <ReqT, RespT> interceptCall(
        call: ServerCall<ReqT, RespT>,
        headers: Metadata,
        next: ServerCallHandler<ReqT, RespT>
    ): ServerCall.Listener<ReqT> {
        val started = System.nanoTime()
        val wrapped = object : SimpleForwardingServerCall<ReqT, RespT>(call) {
            override fun close(status: Status, trailers: Metadata) {
                val milliseconds = (System.nanoTime() - started) / 1_000_000.0
                trailers.put(KEY, String.format(Locale.ROOT, "%.1f", milliseconds))
                super.close(status, trailers)
            }
        }
        return next.startCall(wrapped, headers)
    }

    companion object {
        val KEY: Metadata.Key<String> = Metadata.Key.of("amoo-server-ms", Metadata.ASCII_STRING_MARSHALLER)
    }
}
