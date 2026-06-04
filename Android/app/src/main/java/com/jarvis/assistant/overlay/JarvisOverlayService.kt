package com.jarvis.assistant.overlay

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.IBinder
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import com.jarvis.assistant.core.events.EventBus
import com.jarvis.assistant.core.events.EventKind
import com.jarvis.assistant.overlay.model.OverlayCard
import com.jarvis.assistant.overlay.model.OverlayCardType
import com.jarvis.assistant.overlay.model.OverlayPriority
import com.jarvis.assistant.overlay.ui.OverlayContent
import com.jarvis.assistant.reliability.HealthMonitor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * JarvisOverlayService — owns the floating overlay window.
 *
 * ## Lifecycle
 *   Started by [JarvisOverlayService.startIfPermitted] when SYSTEM_ALERT_WINDOW
 *   is granted.  Stopped via [stop] when Jarvis shuts down.  Uses
 *   START_NOT_STICKY — it is not a foreground service, so it is re-started
 *   explicitly by JarvisService rather than auto-recovered with a null intent.
 *
 * ## Window management
 *   A single [ComposeView] is added to [WindowManager] with WRAP_CONTENT dimensions
 *   and FLAG_NOT_FOCUSABLE so it never intercepts key events.  The view is only
 *   attached when [OverlayCardManager.cards] is non-empty; it detaches when the
 *   list empties, avoiding a transparent but ever-present overlay plane.
 *
 * ## Compose in a Service
 *   [ComposeView] requires a [LifecycleOwner] and [SavedStateRegistryOwner] via
 *   ViewTree APIs.  This service implements both and drives the lifecycle registry
 *   through the standard ON_CREATE → ON_START → ON_RESUME / ON_PAUSE → ON_STOP →
 *   ON_DESTROY sequence so Compose recomposition and remembered state work normally.
 *
 * ## HA alert subscription
 *   The service also subscribes to [EventBus] for [EventKind.SMART_HOME_STATE]
 *   events and surfaces alert-worthy ones (motion, door, lock, alarm…) as
 *   [OverlayCardType.HOME_ASSISTANT_ALERT] cards via [OverlayEventBridge].
 */
class JarvisOverlayService : Service(), LifecycleOwner, SavedStateRegistryOwner {

    companion object {
        private const val TAG = "OverlayService"

        fun startIfPermitted(context: Context) {
            if (OverlayPermission.hasPermission(context)) {
                context.startService(Intent(context, JarvisOverlayService::class.java))
                Log.d(TAG, "start requested")
            } else {
                Log.d(TAG, "skipping start — SYSTEM_ALERT_WINDOW not granted")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, JarvisOverlayService::class.java))
        }
    }

    // ── Lifecycle / SavedState (required by ComposeView in non-Activity host) ──

    private val lifecycleRegistry        = LifecycleRegistry(this)
    private val savedStateController     = SavedStateRegistryController.create(this)

    override val lifecycle: Lifecycle
        get() = lifecycleRegistry
    override val savedStateRegistry: SavedStateRegistry
        get() = savedStateController.savedStateRegistry

    // ── WindowManager + Compose view ──────────────────────────────────────────

    private lateinit var windowManager: WindowManager
    private var composeView: ComposeView? = null
    private var windowParams: WindowManager.LayoutParams? = null
    private var viewAttached = false

    // ── Coroutine scope (Main — drives StateFlow collection + HA subscription) ─

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // ── Service lifecycle ─────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        savedStateController.performRestore(null)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)

        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        setupWindow()
        observeCards()
        subscribeHaAlerts()
        com.jarvis.assistant.reliability.ListenerDiagnostics.activeHaSubscriptionCount.incrementAndGet()
        HealthMonitor.setOverlayServiceRunning(true)
        Log.d(TAG, "created")
    }

    // #35: START_NOT_STICKY — this overlay service does NOT call startForeground,
    // so a sticky auto-restart with a null intent would be recreated by the
    // system expecting a foreground promotion that never comes (crash on A8+).
    // It is restarted explicitly by JarvisService when overlays are needed.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onDestroy() {
        // 1. Cancel coroutines first — no new attach / detach work after this point.
        com.jarvis.assistant.reliability.ListenerDiagnostics.activeHaSubscriptionCount.decrementAndGet()
        serviceScope.cancel()
        OverlayCardManager.dismissAll()

        // 2. Detach the view SYNCHRONOUSLY (removeViewImmediate) BEFORE firing ON_DESTROY.
        //    removeView() is asynchronous: it posts to the main queue and returns immediately.
        //    That leaves ViewRootImpl$2 (the binder W-stub) holding ViewRootImpl → ComposeView
        //    → setViewTreeLifecycleOwner → lifecycleRegistry → this service, which is exactly
        //    the chain LeakCanary reports.  removeViewImmediate() tears it down in this
        //    callstack so no reference survives past onDestroy.
        detachView()
        composeView = null

        // 3. Fire lifecycle events AFTER physical detachment so Compose gets
        //    onDetachedFromWindow() (which disposes the composition) before ON_DESTROY is
        //    signalled.  Reversing this order disposes the composition while the view is
        //    still window-attached, causing inconsistent state.
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)

        HealthMonitor.setOverlayServiceRunning(false)
        Log.d(TAG, "destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Window setup ──────────────────────────────────────────────────────────

    private fun setupWindow() {
        windowParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).also { p ->
            p.gravity = Gravity.TOP or Gravity.END
            p.x = dp(8)
            p.y = dp(56)   // below status bar on most devices
        }

        composeView = ComposeView(this).also { cv ->
            cv.setViewTreeLifecycleOwner(this)
            cv.setViewTreeSavedStateRegistryOwner(this)
            cv.setContent { OverlayContent() }
        }
    }

    private fun observeCards() {
        serviceScope.launch {
            OverlayCardManager.cards.collect { cards ->
                when {
                    cards.isNotEmpty() && !viewAttached -> attachView()
                    cards.isEmpty()    &&  viewAttached -> detachView()
                }
            }
        }
    }

    private fun attachView() {
        val v = composeView ?: return
        val p = windowParams ?: return
        runCatching { windowManager.addView(v, p) }
            .onSuccess {
                viewAttached = true
                com.jarvis.assistant.reliability.ListenerDiagnostics.activeOverlayViewCount.incrementAndGet()
                Log.d(TAG, "window attached")
            }
            .onFailure { Log.e(TAG, "addView failed: ${it.message}") }
    }

    private fun detachView() {
        val v = composeView ?: return
        if (!viewAttached) return
        // removeViewImmediate() is synchronous — it tears down ViewRootImpl and its binder
        // callback (ViewRootImpl$2) in the current callstack rather than posting async removal
        // to the main queue.  This is safe here because detachView() is always called from the
        // main thread (either directly in onDestroy or via Dispatchers.Main.immediate coroutine).
        runCatching { windowManager.removeViewImmediate(v) }
            .onSuccess {
                viewAttached = false
                com.jarvis.assistant.reliability.ListenerDiagnostics.activeOverlayViewCount.decrementAndGet()
                Log.d(TAG, "window detached")
            }
            .onFailure { Log.e(TAG, "removeViewImmediate failed: ${it.message}") }
    }

    // ── Home Assistant alert subscription ─────────────────────────────────────

    private fun subscribeHaAlerts() {
        serviceScope.launch {
            EventBus.ofKind(EventKind.SMART_HOME_STATE).collect { event ->
                val entityId = event.payload["entity_id"] ?: return@collect
                val state    = event.payload["state"]      ?: return@collect
                if (!isAlertWorthy(state, entityId)) return@collect

                val friendly = event.payload["friendly_name"]
                    ?: entityId
                        .removePrefix("binary_sensor.").removePrefix("sensor.")
                        .removePrefix("switch.").replace('_', ' ').trim()
                        .replaceFirstChar { it.uppercase() }

                OverlayEventBridge.haAlert(
                    title    = friendly,
                    message  = state.replaceFirstChar { it.uppercase() },
                    entityId = entityId,   // enables per-entity cooldown + dedup in OverlayPolicy
                )
            }
        }
    }

    private fun isAlertWorthy(state: String, entityId: String): Boolean {
        if (state.lowercase() !in setOf("on", "open", "unlocked", "triggered", "detected")) {
            return false
        }
        val id = entityId.lowercase()
        return id.contains("motion")  || id.contains("door")  || id.contains("lock") ||
               id.contains("alarm")   || id.contains("smoke") || id.contains("leak") ||
               id.contains("window")  || id.contains("garage")
    }

    // ── Utility ───────────────────────────────────────────────────────────────

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()
}
