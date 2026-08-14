package com.amoo.companion.server

import io.grpc.ForwardingServerCall.SimpleForwardingServerCall
import io.grpc.Metadata
import io.grpc.ServerCall
import io.grpc.ServerCallHandler
import io.grpc.ServerInterceptor
import io.grpc.Status

/**
 * Backfills [Status.getDescription] from the failure's cause when a handler throws without
 * setting one.
 *
 * grpc-kotlin's coroutine stub converts an uncaught exception from a suspend handler via
 * `Status.fromThrowable`, which attaches the exception as [Status.getCause] but leaves the
 * description null/empty unless the handler explicitly set one. Clients then see an
 * unhelpful `unknown: ""` with no way to tell what actually failed, on every method — none
 * of the handlers under `com.amoo.companion.handlers` currently catch and describe their own
 * failures. Falling back to the cause's message (or its class name, when the exception
 * carries no message) makes every RPC failure actionable without requiring each handler to
 * remember to wrap its own exceptions.
 */
class DescriptionBackfillInterceptor : ServerInterceptor {
    override fun <ReqT, RespT> interceptCall(
        call: ServerCall<ReqT, RespT>,
        headers: Metadata,
        next: ServerCallHandler<ReqT, RespT>
    ): ServerCall.Listener<ReqT> {
        val wrapped = object : SimpleForwardingServerCall<ReqT, RespT>(call) {
            override fun close(status: Status, trailers: Metadata) {
                super.close(backfillDescription(status), trailers)
            }
        }
        return next.startCall(wrapped, headers)
    }

    private fun backfillDescription(status: Status): Status {
        if (!status.description.isNullOrEmpty()) return status
        val cause = status.cause ?: return status
        val description = cause.message?.takeIf { it.isNotEmpty() } ?: cause::class.simpleName
        return description?.let { status.withDescription(it) } ?: status
    }
}
