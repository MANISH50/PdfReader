package com.pdfreader.pdfreader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Channel "pdfreader/system": small helpers for the onboarding screen.
 *  - `sdkInt` -> Int
 *  - `openDefaultAppSettings` -> Boolean (true if a settings screen was opened)
 */
object SystemSettingsChannel {
    const val CHANNEL = "pdfreader/system"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "openDefaultAppSettings" -> result.success(openDefaultAppSettings(activity))
                else -> result.notImplemented()
            }
        }
    }

    private fun openDefaultAppSettings(activity: Activity): Boolean {
        val pkg = Uri.fromParts("package", activity.packageName, null)
        val candidates = buildList {
            if (Build.VERSION.SDK_INT >= 31) {
                add(Intent(Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS, pkg))
            }
            add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg))
        }
        for (intent in candidates) {
            try {
                activity.startActivity(intent)
                return true
            } catch (e: ActivityNotFoundException) {
                // try the next one
            } catch (e: SecurityException) {
                // try the next one
            }
        }
        return false
    }
}
