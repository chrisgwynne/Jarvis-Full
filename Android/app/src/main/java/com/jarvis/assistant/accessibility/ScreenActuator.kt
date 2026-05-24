package com.jarvis.assistant.accessibility

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import com.jarvis.assistant.accessibility.AppControlService.ScrollDirection

/**
 * ScreenActuator — performs taps / scrolls / text input against the live
 * accessibility node tree.  Pairs with [ScreenInspector]: callers identify
 * a target by [ScreenNode.index] in a snapshot, then ask the actuator to
 * perform an action against the same coordinates.
 *
 * Why coordinates rather than refreshing nodes?  The snapshot has already
 * walked the tree once and the alternative — keeping live AccessibilityNodeInfo
 * references on the call site — is fragile (the OS recycles them across
 * windows).  Coordinates are durable for the few hundred milliseconds
 * between snapshot and tap.
 */
object ScreenActuator {

    private const val TAG = "ScreenActuator"
    private const val TAP_DURATION_MS = 60L

    /**
     * Perform a click on the node at [node.center].  Falls back to a synthesised
     * tap gesture when the node itself doesn't accept ACTION_CLICK (icon-only
     * buttons in some apps respond to gestures only).
     */
    fun click(service: AccessibilityService, node: ScreenNode): Boolean {
        // Prefer ACTION_CLICK on the live node when we can find one with a
        // matching viewId — semantic clicks beat synthesised gestures, which
        // can land in scroll containers.
        val live = findLiveNode(service, node)
        if (live != null && live.isClickable &&
            live.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
            Log.d(TAG, "Clicked via ACTION_CLICK on ${node.matchLabel}")
            return true
        }
        return tapAt(service, node.centerX, node.centerY)
    }

    /** Synthesised tap at absolute screen coordinates. */
    fun tapAt(service: AccessibilityService, x: Int, y: Int): Boolean {
        val path = Path().apply { moveTo(x.toFloat(), y.toFloat()) }
        val stroke = GestureDescription.StrokeDescription(path, 0L, TAP_DURATION_MS)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return service.dispatchGesture(gesture, null, null)
            .also { Log.d(TAG, "tapAt($x,$y) dispatched=$it") }
    }

    /**
     * Set the text on the editable node represented by [node].  Returns false
     * when the node isn't editable or we can't locate it on the live tree.
     */
    fun setText(service: AccessibilityService, node: ScreenNode, text: String): Boolean {
        val live = findLiveNode(service, node) ?: return false
        if (!live.isEditable) return false
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return live.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            .also { Log.d(TAG, "setText on ${node.matchLabel} → $it") }
    }

    /**
     * Scroll the foreground window.
     *
     * Strategy:
     *   1. Find the largest scrollable, enabled container and fire
     *      ACTION_SCROLL_FORWARD (down) / ACTION_SCROLL_BACKWARD (up) on it.
     *   2. If no scrollable node is found, fall back to a swipe gesture in the
     *      centre of the screen.
     */
    fun scroll(service: AccessibilityService, direction: ScrollDirection): Boolean {
        val root = service.rootInActiveWindow
        val scrollNode = root?.let { findLargestScrollable(it) }

        if (scrollNode != null) {
            val action = if (direction == ScrollDirection.DOWN)
                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            else
                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            val ok = scrollNode.performAction(action)
            Log.d(TAG, "scroll via ACTION on scrollable node ok=$ok")
            if (ok) return true
        }

        // Gesture fallback — swipe from centre ±30% of screen height
        Log.d(TAG, "scroll via gesture fallback direction=$direction")
        return swipeGesture(service, direction)
    }

    private fun findLargestScrollable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var best: AccessibilityNodeInfo? = null
        var bestArea = 0
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (node.isScrollable && node.isEnabled) {
                val bounds = android.graphics.Rect()
                node.getBoundsInScreen(bounds)
                val area = bounds.width() * bounds.height()
                if (area > bestArea) {
                    bestArea = area
                    best = node
                }
            }
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.add(it) }
            }
        }
        return best
    }

    private fun swipeGesture(service: AccessibilityService, direction: ScrollDirection): Boolean {
        val displayMetrics = service.resources.displayMetrics
        val w = displayMetrics.widthPixels
        val h = displayMetrics.heightPixels
        val cx = w / 2f
        val fromY: Float
        val toY: Float
        if (direction == ScrollDirection.DOWN) {
            fromY = h * 0.65f
            toY   = h * 0.35f
        } else {
            fromY = h * 0.35f
            toY   = h * 0.65f
        }
        val path = Path().apply {
            moveTo(cx, fromY)
            lineTo(cx, toY)
        }
        val stroke  = GestureDescription.StrokeDescription(path, 0L, 300L)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return service.dispatchGesture(gesture, null, null)
            .also { Log.d(TAG, "swipeGesture dispatched=$it direction=$direction") }
    }

    /** Walk the live tree looking for a node with the same viewId or label. */
    private fun findLiveNode(
        service: AccessibilityService,
        target: ScreenNode
    ): AccessibilityNodeInfo? {
        val root = service.rootInActiveWindow ?: return null
        if (target.viewId.isNotBlank()) {
            root.findAccessibilityNodeInfosByViewId(target.viewId)
                .firstOrNull { it.isVisibleToUser }
                ?.let { return it }
        }
        val needle = target.matchLabel
        if (needle.isNotBlank()) {
            root.findAccessibilityNodeInfosByText(needle)
                .firstOrNull { it.isVisibleToUser }
                ?.let { return it }
        }
        return null
    }
}
