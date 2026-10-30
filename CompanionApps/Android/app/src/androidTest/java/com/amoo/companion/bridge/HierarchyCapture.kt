package com.amoo.companion.bridge

/** A tree changed during traversal; no part of that capture is safe to return. */
internal class HierarchyChangedException : IllegalStateException("Accessibility hierarchy changed during capture")

/** Serializes capture and allows up to three complete attempts while accessibility windows settle. */
internal class HierarchyCapture {
    @Synchronized
    fun <T> read(operation: () -> T): T {
        repeat(2) {
            try {
                return operation()
            } catch (_: HierarchyChangedException) {
                Thread.sleep(100)
            }
        }
        return operation()
    }
}
