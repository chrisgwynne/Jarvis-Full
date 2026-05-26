package com.jarvis.assistant.ui.camera

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.graphics.Color

/**
 * MacCameraViewerActivity — full-screen activity that hosts [MacCameraViewerScreen].
 *
 * Opened from [MacCameraViewerTool] via startActivity(FLAG_ACTIVITY_NEW_TASK).
 * Closing the viewer returns the user to whatever was on screen before —
 * JarvisService keeps running and listening throughout.
 */
class MacCameraViewerActivity : ComponentActivity() {

    companion object {
        private const val TAG = "MacCameraViewerActivity"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "MAC_CAMERA_VIEWER_OPENED")
        Log.i(TAG, "LISTENING_STILL_ACTIVE_CAMERA_VIEWER")

        setContent {
            MaterialTheme(
                colorScheme = darkColorScheme(
                    background = Color(0xFF060B14),   // blueprint deepest navy
                    surface    = Color(0xFF0B1628),   // blueprint card surface
                )
            ) {
                MacCameraViewerScreen(onClose = { finish() })
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "MAC_CAMERA_VIEWER_CLOSED")
        Log.i(TAG, "CAMERA_VIEWER_CLOSED_LISTENING_OK")
    }
}
