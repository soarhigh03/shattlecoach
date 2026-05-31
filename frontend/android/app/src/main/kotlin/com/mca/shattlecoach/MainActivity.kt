package com.mca.shattlecoach

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Bundle
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {

    private val channelName = "com.shattlecoach/frame_extractor"

    // Hide the system navigation bar from the splash screen onward so the app
    // renders fully edge-to-edge. Sticky behavior re-hides it after a swipe.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            val controller = WindowInsetsControllerCompat(window, window.decorView)
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getFrame" -> {
                    val path = call.argument<String>("path")
                    val timeMs = call.argument<Number>("timeMs")?.toLong()
                    val jpegQuality = call.argument<Number>("jpegQuality")?.toInt() ?: 85
                    if (path == null || timeMs == null) {
                        result.error("BAD_ARGS", "missing path/timeMs", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(extractFrameJpeg(path, timeMs, jpegQuality))
                    } catch (e: Throwable) {
                        result.error("EXTRACT_FAIL", "${e.javaClass.simpleName}: ${e.message}", null)
                    }
                }
                "getDurationMs" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("BAD_ARGS", "missing path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val r = MediaMetadataRetriever()
                        r.setDataSource(path)
                        val d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                        r.release()
                        result.success(d)
                    } catch (e: Throwable) {
                        result.error("DURATION_FAIL", "${e.javaClass.simpleName}: ${e.message}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun extractFrameJpeg(path: String, timeMs: Long, quality: Int): ByteArray {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val bitmap: Bitmap = retriever.getFrameAtTime(
                timeMs * 1000L, // microseconds
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.getFrameAtTime(
                timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST
            ) ?: throw RuntimeException("getFrameAtTime returned null at $timeMs ms")
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            bitmap.recycle()
            return out.toByteArray()
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }
}
