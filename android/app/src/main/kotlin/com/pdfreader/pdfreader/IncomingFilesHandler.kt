package com.pdfreader.pdfreader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Receives PDFs from ACTION_VIEW / ACTION_SEND / ACTION_SEND_MULTIPLE intents and
 * hands them to Dart as private copies in the app's inbox.
 *
 * Protocol (channel "pdfreader/incoming"):
 *  - `configure({inbox: String, maxBytes: Long})` -> List<Map> results for every
 *    intent received before Dart was ready (normally the launch intent).
 *  - Later intents are delivered on the event channel "pdfreader/incoming/events",
 *    one List<Map> per intent.
 * A result map is either `{path, displayName, sourceUri, size}` or
 * `{error, displayName?, sourceUri?}`.
 *
 * All I/O runs on one background thread, in arrival order.
 */
class IncomingFilesHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    // Main-thread state.
    private var importer: InboxImporter? = null
    private val pendingIntents = mutableListOf<Intent>()
    private val undelivered = mutableListOf<List<Map<String, Any?>>>()
    private var sink: EventChannel.EventSink? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    /** Called on the main thread with the launch intent and every onNewIntent. */
    fun offer(intent: Intent?) {
        if (intent == null || intent.action !in HANDLED_ACTIONS) return
        val imp = importer
        if (imp == null) {
            pendingIntents += intent
            return
        }
        executor.execute {
            val results = importIntent(imp, intent)
            mainHandler.post { deliver(results) }
        }
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        sink = null
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> configure(call, result)
            else -> result.notImplemented()
        }
    }

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        val inbox = call.argument<String>("inbox")
        val maxBytes = call.argument<Number>("maxBytes")?.toLong()
        if (inbox.isNullOrEmpty() || maxBytes == null || maxBytes <= 0) {
            result.error("bad_args", "inbox and maxBytes are required", null)
            return
        }
        val imp = try {
            InboxImporter(context, File(inbox), maxBytes)
        } catch (e: IllegalArgumentException) {
            result.error("bad_inbox", "inbox must be inside app-private storage", null)
            return
        }
        importer = imp
        val queued = pendingIntents.toList()
        pendingIntents.clear()
        executor.execute {
            val results = queued.flatMap { importIntent(imp, it) }
            mainHandler.post { result.success(results) }
        }
    }

    private fun deliver(results: List<Map<String, Any?>>) {
        if (results.isEmpty()) return
        val s = sink
        if (s == null) undelivered += results else s.success(results)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val queued = undelivered.toList()
        undelivered.clear()
        queued.forEach { events.success(it) }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ---- intent parsing (background thread) ----------------------------

    private fun importIntent(imp: InboxImporter, intent: Intent): List<Map<String, Any?>> {
        val uris = urisOf(intent)
        val out = uris.take(MAX_FILES_PER_INTENT).map { imp.import(it) }.toMutableList()
        if (uris.size > MAX_FILES_PER_INTENT) out += mapOf("error" to "tooMany")
        return out
    }

    private fun urisOf(intent: Intent): List<Uri> {
        val list: List<Uri> = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(streamExtra(intent) ?: clipUris(intent).firstOrNull())
            Intent.ACTION_SEND_MULTIPLE -> streamListExtra(intent).ifEmpty { clipUris(intent) }
            else -> emptyList()
        }
        return list.distinct()
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? = try {
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri
        }
    } catch (e: RuntimeException) {
        null // malformed extras from a hostile sender
    }

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri> = try {
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        } else {
            intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM)
                .orEmpty().filterIsInstance<Uri>()
        }
    } catch (e: RuntimeException) {
        emptyList()
    }

    private fun clipUris(intent: Intent): List<Uri> {
        val clip = intent.clipData ?: return emptyList()
        return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it)?.uri }
    }

    companion object {
        const val METHOD_CHANNEL = "pdfreader/incoming"
        const val EVENT_CHANNEL = "pdfreader/incoming/events"
        const val MAX_FILES_PER_INTENT = 20
        private val HANDLED_ACTIONS =
            setOf(Intent.ACTION_VIEW, Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)
    }
}
