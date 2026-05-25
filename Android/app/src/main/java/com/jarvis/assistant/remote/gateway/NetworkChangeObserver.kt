package com.jarvis.assistant.remote.gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Monitors network connectivity and triggers gateway reconnection when
 * connectivity is restored after a loss.
 *
 * Use NetworkCallback (API 21+) as the primary mechanism.
 * The BroadcastReceiver fallback handles rare cases on older APIs.
 *
 * Call register() when the service starts, unregister() when it stops.
 */
class NetworkChangeObserver(
    private val context: Context,
    private val client: BrainGatewayWebSocketClient
) {
    companion object {
        private const val TAG = "NetworkChangeObserver"
        private const val RECONNECT_DELAY_MS = 1_000L
    }

    private val registered = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())

    // Track whether we were previously connected so we can detect lost→available transitions.
    @Volatile private var wasConnected: Boolean = false

    // ── Primary: NetworkCallback (API 21+) ───────────────────────────────────

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            Log.d(TAG, "Network available")
            if (!wasConnected) {
                // Transition from lost → available: schedule a reconnect.
                mainHandler.postDelayed({
                    if (client.status.value != GatewayWsStatus.Connected) {
                        Log.i(TAG, "Connectivity restored — starting gateway client")
                        client.start()
                    } else {
                        Log.d(TAG, "Connectivity restored — client already connected, no action needed")
                    }
                }, RECONNECT_DELAY_MS)
            }
            wasConnected = true
        }

        override fun onLost(network: Network) {
            Log.d(TAG, "Network lost — gateway client will handle its own reconnect loop")
            wasConnected = false
            // Do NOT stop the client — BrainGatewayWebSocketClient has its own
            // exponential back-off reconnect loop in connectLoop().
        }

        override fun onUnavailable() {
            Log.d(TAG, "Network unavailable")
            wasConnected = false
        }
    }

    // ── Fallback: BroadcastReceiver (API < 21, extremely rare) ───────────────

    private val legacyReceiver: BroadcastReceiver? = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
        object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                    ?: return
                @Suppress("DEPRECATION")
                val networkInfo = cm.activeNetworkInfo
                @Suppress("DEPRECATION")
                val isConnected = networkInfo?.isConnected == true

                if (isConnected && !wasConnected) {
                    Log.i(TAG, "[Legacy] Connectivity restored — starting gateway client")
                    mainHandler.postDelayed({
                        if (client.status.value != GatewayWsStatus.Connected) {
                            client.start()
                        }
                    }, RECONNECT_DELAY_MS)
                } else if (!isConnected) {
                    Log.d(TAG, "[Legacy] Network lost")
                }
                wasConnected = isConnected
            }
        }
    } else {
        null
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    fun register() {
        if (!registered.compareAndSet(false, true)) {
            Log.w(TAG, "register() called while already registered — ignoring")
            return
        }

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm == null) {
            Log.e(TAG, "ConnectivityManager unavailable — cannot register network observer")
            registered.set(false)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(request, networkCallback)
            Log.d(TAG, "NetworkCallback registered")
        } else {
            // Pre-API 21 fallback via BroadcastReceiver.
            @Suppress("DEPRECATION")
            legacyReceiver?.let {
                context.registerReceiver(
                    it,
                    IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION)
                )
                Log.d(TAG, "Legacy BroadcastReceiver registered (API < 21)")
            }
        }
    }

    fun unregister() {
        if (!registered.compareAndSet(true, false)) {
            Log.w(TAG, "unregister() called while not registered — ignoring")
            return
        }

        mainHandler.removeCallbacksAndMessages(null)

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                cm?.unregisterNetworkCallback(networkCallback)
                Log.d(TAG, "NetworkCallback unregistered")
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "NetworkCallback was not registered: ${e.message}")
            }
        } else {
            legacyReceiver?.let {
                try {
                    context.unregisterReceiver(it)
                    Log.d(TAG, "Legacy BroadcastReceiver unregistered")
                } catch (e: IllegalArgumentException) {
                    Log.w(TAG, "BroadcastReceiver was not registered: ${e.message}")
                }
            }
        }
    }
}
