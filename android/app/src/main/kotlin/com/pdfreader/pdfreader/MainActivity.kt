package com.pdfreader.pdfreader

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var incoming: IncomingFilesHandler? = null

    /** True once the intent that launched this activity has been handed over. */
    private var launchIntentConsumed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must be decided before super.onCreate(), which configures the engine.
        // A recreated activity (process death) or a launch from Recents must not
        // re-import the file from the original launch intent.
        launchIntentConsumed = savedInstanceState?.getBoolean(KEY_CONSUMED) == true ||
            (intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        incoming?.dispose()
        incoming = IncomingFilesHandler(applicationContext, messenger).also { handler ->
            if (!launchIntentConsumed) {
                launchIntentConsumed = true
                handler.offer(intent)
            }
        }
        SystemSettingsChannel.register(this, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        incoming?.dispose()
        incoming = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incoming?.offer(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_CONSUMED, true)
    }

    private companion object {
        const val KEY_CONSUMED = "pdfreader.launchIntentConsumed"
    }
}
