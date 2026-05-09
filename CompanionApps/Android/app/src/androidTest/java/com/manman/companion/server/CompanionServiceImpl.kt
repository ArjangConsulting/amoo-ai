package com.manman.companion.server

import com.manman.companion.bridge.Direction
import com.manman.companion.bridge.ElementSnapshot
import com.manman.companion.bridge.UIAutomatorBridge
import com.manman.companion.handlers.AccessibilityHandler
import com.manman.companion.handlers.GestureHandler
import com.manman.companion.handlers.TextHandler
import com.manman.companion.handlers.TouchHandler
import mobile.testing.v1.ActionResponse
import mobile.testing.v1.CapabilitiesRequest
import mobile.testing.v1.CapabilitiesResponse
import mobile.testing.v1.CapabilityDescriptor
import mobile.testing.v1.CapabilityTier
import mobile.testing.v1.ClearTextRequest
import mobile.testing.v1.CompanionServiceGrpcKt
import mobile.testing.v1.Direction as ProtoDirection
import mobile.testing.v1.Empty
import mobile.testing.v1.EndSessionRequest
import mobile.testing.v1.EndSessionResponse
import mobile.testing.v1.FindByDescriptionRequest
import mobile.testing.v1.FindElementsRequest
import mobile.testing.v1.FindElementsResponse
import mobile.testing.v1.InteractableElementsResponse
import mobile.testing.v1.KeyboardVisibleResponse
import mobile.testing.v1.LongPressRequest
import mobile.testing.v1.ScreenContextRequest
import mobile.testing.v1.ScreenContextResponse
import mobile.testing.v1.ScreenshotRequest
import mobile.testing.v1.ScreenshotResponse
import mobile.testing.v1.ScrollRequest
import mobile.testing.v1.StartSessionRequest
import mobile.testing.v1.StartSessionResponse
import mobile.testing.v1.SwipeDirectionRequest
import mobile.testing.v1.SwipeRequest
import mobile.testing.v1.TapElementRequest
import mobile.testing.v1.TapRequest
import mobile.testing.v1.TypeTextRequest
import mobile.testing.v1.ViewHierarchyRequest
import mobile.testing.v1.ViewHierarchyResponse
import mobile.testing.v1.WaitForElementRequest
import mobile.testing.v1.WaitForElementResponse
import mobile.testing.v1.ElementInfo
import mobile.testing.v1.Rect
import mobile.testing.v1.ViewNode

class CompanionServiceImpl(
    private val touch: TouchHandler,
    private val gesture: GestureHandler,
    private val text: TextHandler,
    private val accessibility: AccessibilityHandler
) : CompanionServiceGrpcKt.CompanionServiceCoroutineImplBase() {

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
            capability("action.typeText", CapabilityTier.CAPABILITY_TIER_REQUIRED),
            capability("action.clearText", CapabilityTier.CAPABILITY_TIER_REQUIRED),
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
