package com.amoo.companion.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class HierarchyCaptureTests {
    @Test
    fun changedTreeIsDiscardedAndRecaptured() {
        val capture = HierarchyCapture()
        var attempts = 0
        val result = capture.read {
            attempts++
            val nodes = mutableListOf("root-$attempts")
            if (attempts == 1) throw HierarchyChangedException()
            nodes.add("child-$attempts")
            nodes
        }
        assertEquals(listOf("root-2", "child-2"), result)
        assertEquals(2, attempts)
    }

    @Test
    fun repeatedChangesFailInsteadOfReturningAbsence() {
        var attempts = 0
        try {
            HierarchyCapture().read {
                attempts++
                throw HierarchyChangedException()
            }
            throw AssertionError("An incomplete tree must fail")
        } catch (_: HierarchyChangedException) {
            assertEquals(3, attempts)
        }
    }

    @Test
    fun initialWindowRegistrationCanSettleBeforeTheFinalCapture() {
        var attempts = 0
        val result = HierarchyCapture().read {
            attempts++
            if (attempts < 3) throw HierarchyChangedException()
            listOf("registered-window")
        }
        assertEquals(listOf("registered-window"), result)
        assertEquals(3, attempts)
    }

    @Test
    fun traversalLimitsAndCancellationAreNotRetried() {
        for (failure in listOf(IllegalStateException("Traversal limit exceeded"), java.util.concurrent.CancellationException())) {
            var attempts = 0
            try {
                HierarchyCapture().read {
                    attempts++
                    throw failure
                }
                throw AssertionError("The original failure must propagate")
            } catch (actual: Exception) {
                assertSame(failure, actual)
                assertEquals(1, attempts)
            }
        }
    }

    @Test
    fun concurrentCapturesCannotInvalidateEachOthersNodes() {
        val capture = HierarchyCapture()
        val executor = Executors.newFixedThreadPool(2)
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        try {
            val first = executor.submit(Callable {
                capture.read {
                    firstEntered.countDown()
                    assertTrue(releaseFirst.await(2, TimeUnit.SECONDS))
                    1
                }
            })
            assertTrue(firstEntered.await(2, TimeUnit.SECONDS))
            val second = executor.submit(Callable {
                secondStarted.countDown()
                capture.read {
                    secondEntered.countDown()
                    2
                }
            })
            assertTrue(secondStarted.await(2, TimeUnit.SECONDS))
            assertFalse(secondEntered.await(100, TimeUnit.MILLISECONDS))
            releaseFirst.countDown()
            assertEquals(1, first.get(2, TimeUnit.SECONDS))
            assertEquals(2, second.get(2, TimeUnit.SECONDS))
        } finally {
            releaseFirst.countDown()
            executor.shutdownNow()
        }
    }
}
