package com.amoo.companion.server

import com.amoo.companion.bridge.Direction
import com.amoo.companion.bridge.ElementSnapshot
import com.amoo.companion.bridge.UIAutomatorBridge
import com.amoo.companion.handlers.AccessibilityHandler
import com.amoo.companion.handlers.GestureHandler
import com.amoo.companion.handlers.TextHandler
import com.amoo.companion.handlers.TouchHandler
import amoo.v1.ActionResponse
import amoo.v1.CapabilitiesRequest
import amoo.v1.CapabilitiesResponse
import amoo.v1.CapabilityDescriptor
import amoo.v1.CapabilityTier
import amoo.v1.ClearTextRequest
import amoo.v1.CompanionServiceGrpcKt
import amoo.v1.Direction as ProtoDirection
import amoo.v1.DragRequest
import amoo.v1.Empty
import amoo.v1.EndSessionRequest
import amoo.v1.EndSessionResponse
import amoo.v1.FindByDescriptionRequest
import amoo.v1.FindElementsRequest
import amoo.v1.FindElementsResponse
import amoo.v1.InteractableElementsResponse
import amoo.v1.KeyboardVisibleResponse
import amoo.v1.LongPressRequest
import amoo.v1.ScreenContextRequest
import amoo.v1.ScreenContextResponse
import amoo.v1.ScreenshotRequest
import amoo.v1.ScreenshotResponse
import amoo.v1.ScrollRequest
import amoo.v1.StartSessionRequest
import amoo.v1.StartSessionResponse
import amoo.v1.SwipeDirectionRequest
import amoo.v1.SwipeRequest
import amoo.v1.TapElementRequest
import amoo.v1.TapRequest
import amoo.v1.TypeTextRequest
import amoo.v1.SetTextRequest
import amoo.v1.ViewHierarchyRequest
import amoo.v1.ViewHierarchyResponse
import amoo.v1.WaitForElementRequest
import amoo.v1.WaitForElementResponse
import amoo.v1.ElementInfo
import amoo.v1.Rect
import amoo.v1.ViewNode

class CompanionServiceImpl(
    private val touch: TouchHandler,
    private val gesture: GestureHandler,
    private val text: TextHandler,
    private val accessibility: AccessibilityHandler
) : CompanionServiceGrpcKt.CompanionServiceCoroutineImplBase() {

    private companion object {
        /**
         * Hold applied at the drag origin when the caller doesn't specify one. Matches the
         * Android long-press threshold, so an unqualified drag picks the target up rather
         * than degrading into a swipe.
         */
        const val DEFAULT_DRAG_HOLD_MS = 500
    }

    private var sessionId: String? = null
    private val bridge = UIAutomatorBridge()

    override suspend fun startSession(request: StartSessionRequest): StartSessionResponse {
        val id = request.requestedSessionId.takeUnless { it.isBlank() } ?: java.util.UUID.randomUUID().toString()
        sessionId = id
        return StartSessionResponse.newBuilder().setSessionId(id).build()
    }

    override suspend fun getCapabilities(request: CapabilitiesRequest): CapabilitiesResponse {
        request
        val capabilities = listOf(
            capability("action.tap", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.doubleTap", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.longPress", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.swipe", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.scroll", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.swipeInDirection", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.drag", CapabilityTier.CAPABILITY_TIER_OPTIONAL),
            capability("action.typeText", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.clearText", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.setText", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.tapElement", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.pressBack", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.pressHome", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("query.findElements", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("query.getViewHierarchy", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("query.isKeyboardVisible", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("capture.screenshot", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("ai.screenContext", CapabilityTier.CAPABILITY_TIER_OPTIONAL),
            capability("ai.findByDescription", CapabilityTier.CAPABILITY_TIER_OPTIONAL),
            capability("ai.interactableElements", CapabilityTier.CAPABILITY_TIER_OPTIONAL),
        )

        return CapabilitiesResponse.newBuilder()
            .addAllCapabilities(capabilities)
            .build()
    }

    override suspend fun endSession(request: EndSessionRequest): EndSessionResponse {
        request
        sessionId = null
        return EndSessionResponse.newBuilder().setEnded(true).build()
    }

    override suspend fun tap(request: TapRequest): ActionResponse {
        return actionResponse(touch.tap(request.point.x.toInt(), request.point.y.toInt()), "tap failed")
    }

    override suspend fun doubleTap(request: TapRequest): ActionResponse {
        return actionResponse(touch.doubleTap(request.point.x.toInt(), request.point.y.toInt()), "double tap failed")
    }

    override suspend fun longPress(request: LongPressRequest): ActionResponse {
        return actionResponse(
            touch.longPress(
                request.point.x.toInt(),
                request.point.y.toInt(),
                request.duration.milliseconds
            ),
            "long press failed"
        )
    }

    override suspend fun tapElement(request: TapElementRequest): ActionResponse {
        val id = request.selector.id.takeUnless { it.isBlank() }
        val label = request.selector.label.takeUnless { it.isBlank() }
            ?: request.selector.containsText.takeUnless { it.isBlank() }
        return actionResponse(touch.tapElement(id, label), "element not found")
    }

    override suspend fun swipe(request: SwipeRequest): ActionResponse {
        return actionResponse(
            gesture.swipe(
                request.from.x.toInt(),
                request.from.y.toInt(),
                request.to.x.toInt(),
                request.to.y.toInt(),
                request.duration.milliseconds
            ),
            "swipe failed"
        )
    }

    override suspend fun drag(request: DragRequest): ActionResponse {
        // hold_duration is a message field, so an explicit zero (caller wants no dwell)
        // is distinguishable from an omitted field (caller has no opinion).
        val holdMs = if (request.hasHoldDuration()) {
            request.holdDuration.milliseconds
        } else {
            DEFAULT_DRAG_HOLD_MS
        }
        return actionResponse(
            gesture.drag(
                request.from.x.toInt(),
                request.from.y.toInt(),
                request.to.x.toInt(),
                request.to.y.toInt(),
                request.duration.milliseconds,
                holdMs
            ),
            "drag failed"
        )
    }

    override suspend fun scroll(request: ScrollRequest): ActionResponse {
        return actionResponse(
            gesture.scroll(request.direction.coreDirection(), request.distance.toInt()),
            "scroll failed"
        )
    }

    override suspend fun swipeInDirection(request: SwipeDirectionRequest): ActionResponse {
        val direction = request.direction.coreDirection()
        val distance = if (request.distance > 0) request.distance.toInt() else 300
        val durationMs = if (request.durationMs > 0) request.durationMs else 400
        val resourceId = if (request.hasSelector())
            request.selector.id.takeUnless { it.isBlank() } else null
        val label = if (request.hasSelector())
            request.selector.label.takeUnless { it.isBlank() }
                ?: request.selector.containsText.takeUnless { it.isBlank() }
            else null
        return actionResponse(
            gesture.swipeInDirection(direction, distance, durationMs, resourceId, label),
            "swipeInDirection failed"
        )
    }

    override suspend fun typeText(request: TypeTextRequest): ActionResponse {
        text.typeText(request.text)
        return success("typed text")
    }

    override suspend fun clearText(request: ClearTextRequest): ActionResponse {
        request
        text.clearText()
        return success("cleared text")
    }

    override suspend fun setText(request: SetTextRequest): ActionResponse {
        val selector = request.selector
        return actionResponse(
            text.setText(
                selector.id.takeUnless { it.isBlank() },
                selector.label.takeUnless { it.isBlank() },
                selector.containsText.takeUnless { it.isBlank() },
                request.text
            ),
            "text field not found or value was not accepted"
        )
    }

    override suspend fun pressBack(request: Empty): ActionResponse {
        request
        return actionResponse(touchBack(), "back navigation failed")
    }

    override suspend fun pressHome(request: Empty): ActionResponse {
        request
        return actionResponse(pressHomeInternal(), "home navigation failed")
    }

    override suspend fun getViewHierarchy(request: ViewHierarchyRequest): ViewHierarchyResponse {
        request
        val children = accessibility.getAllElements().map { it.toViewNode() }
        val root = ViewNode.newBuilder()
            .setId("android-root")
            .setLabel(bridge.currentPackageName())
            .setType("other")
            .setIsEnabled(true)
            .setIsVisible(true)
            .addAllChildren(children)
            .build()

        return ViewHierarchyResponse.newBuilder().setRoot(root).build()
    }

    override suspend fun findElements(request: FindElementsRequest): FindElementsResponse {
        val selector = request.selector
        val matches = accessibility.findElements(
            selector.id.takeUnless { it.isBlank() },
            selector.label.takeUnless { it.isBlank() },
            selector.containsText.takeUnless { it.isBlank() }
        )
        return FindElementsResponse.newBuilder()
            .addAllElements(matches.map { it.toElementInfo() })
            .build()
    }

    override suspend fun waitForElement(request: WaitForElementRequest): WaitForElementResponse {
        val selector = request.selector
        val timeoutMs = request.timeout.milliseconds.takeIf { it > 0 } ?: 3_000
        val deadline = System.currentTimeMillis() + timeoutMs

        while (System.currentTimeMillis() < deadline) {
            val matches = accessibility.findElements(
                selector.id.takeUnless { it.isBlank() },
                selector.label.takeUnless { it.isBlank() },
                selector.containsText.takeUnless { it.isBlank() }
            )
            if (matches.isNotEmpty()) {
                return WaitForElementResponse.newBuilder().setFound(true).build()
            }
            Thread.sleep(100)
        }

        return WaitForElementResponse.newBuilder().setFound(false).build()
    }

    override suspend fun isKeyboardVisible(request: Empty): KeyboardVisibleResponse {
        request
        return KeyboardVisibleResponse.newBuilder()
            .setVisible(accessibility.isKeyboardVisible())
            .build()
    }

    override suspend fun getScreenContext(request: ScreenContextRequest): ScreenContextResponse {
        request
        val interactables = accessibility.getInteractableElements()
        val headline = accessibility.getAllElements()
            .mapNotNull { it.label.takeUnless(String::isBlank) }
            .firstOrNull()
            ?: "Android fixture screen"
        return ScreenContextResponse.newBuilder()
            .setSummary("$headline with ${interactables.size} interactable elements")
            .build()
    }

    override suspend fun findByDescription(request: FindByDescriptionRequest): FindElementsResponse {
        val matches = accessibility.findByDescription(request.description)
        return FindElementsResponse.newBuilder()
            .addAllElements(matches.map { it.toElementInfo() })
            .build()
    }

    override suspend fun getInteractableElements(request: Empty): InteractableElementsResponse {
        request
        return InteractableElementsResponse.newBuilder()
            .addAllElements(accessibility.getInteractableElements().map { it.toElementInfo() })
            .build()
    }

    override suspend fun takeScreenshot(request: ScreenshotRequest): ScreenshotResponse {
        request
        return ScreenshotResponse.newBuilder()
            .setData(com.google.protobuf.ByteString.copyFrom(accessibility.takeScreenshot()))
            .build()
    }

    private fun touchBack(): Boolean {
        return bridge.pressBack()
    }

    private fun pressHomeInternal(): Boolean {
        return bridge.pressHome()
    }

    private fun capability(key: String, tier: CapabilityTier): CapabilityDescriptor {
        return CapabilityDescriptor.newBuilder()
            .setKey(key)
            .setTier(tier)
            .setSupported(true)
            .build()
    }

    private fun success(message: String): ActionResponse {
        return ActionResponse.newBuilder().setSuccess(true).setMessage(message).build()
    }

    private fun actionResponse(success: Boolean, failureMessage: String): ActionResponse {
        return if (success) {
            success("ok")
        } else {
            ActionResponse.newBuilder().setSuccess(false).setMessage(failureMessage).build()
        }
    }
}

private fun ProtoDirection.coreDirection(): Direction {
    return when (this) {
        ProtoDirection.DIRECTION_UP -> Direction.UP
        ProtoDirection.DIRECTION_DOWN -> Direction.DOWN
        ProtoDirection.DIRECTION_LEFT -> Direction.LEFT
        ProtoDirection.DIRECTION_RIGHT -> Direction.RIGHT
        else -> Direction.DOWN
    }
}

private fun ElementSnapshot.toElementInfo(): ElementInfo {
    val rect = Rect.newBuilder()
        .setX(frame.x.toDouble())
        .setY(frame.y.toDouble())
        .setWidth(frame.width.toDouble())
        .setHeight(frame.height.toDouble())
        .build()

    return ElementInfo.newBuilder()
        .setId(id)
        .setLabel(label)
        .setValue(value)
        .setType(type)
        .setFrame(rect)
        .setIsEnabled(isEnabled)
        .setIsVisible(isVisible)
        .build()
}

private fun ElementSnapshot.toViewNode(): ViewNode {
    val rect = Rect.newBuilder()
        .setX(frame.x.toDouble())
        .setY(frame.y.toDouble())
        .setWidth(frame.width.toDouble())
        .setHeight(frame.height.toDouble())
        .build()

    return ViewNode.newBuilder()
        .setId(id)
        .setLabel(label)
        .setType(type)
        .setValue(value)
        .setFrame(rect)
        .setIsEnabled(isEnabled)
        .setIsVisible(isVisible)
        .build()
}
