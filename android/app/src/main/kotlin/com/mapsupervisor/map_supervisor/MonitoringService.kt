package com.mapsupervisor.map_supervisor

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MonitoringService : Service() {
    private lateinit var workerThread: HandlerThread
    private lateinit var worker: Handler
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var intervalSeconds = 25 * 60
    private var oneShot = false
    private var intentionalStop = false
    private var emptyFrameRetries = 0
    private var overlay: MonitoringOverlay? = null

    private val captureTask = object : Runnable {
        override fun run() {
            captureFrame()
            if (!oneShot && running) {
                val next = System.currentTimeMillis() + intervalSeconds * 1000L
                emitStatus(next)
                worker.postDelayed(this, intervalSeconds * 1000L)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        ProcessDiagnostics.installCrashHandler(applicationContext)
        ProcessDiagnostics.record(applicationContext, "SERVICE_CREATE")
        workerThread = HandlerThread("MapSupervisorCapture").apply { start() }
        worker = Handler(workerThread.looper)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ProcessDiagnostics.record(
            applicationContext,
            "SERVICE_START_COMMAND",
            "action=${intent?.action ?: "null"} flags=$flags startId=$startId",
        )
        when (intent?.action) {
            ACTION_STOP -> stopProjection("监控已停止", false)
            ACTION_CAPTURE -> worker.post { captureFrame() }
            ACTION_START -> startProjection(intent)
        }
        return START_NOT_STICKY
    }

    private fun startProjection(intent: Intent) {
        intervalSeconds = intent.getIntExtra(EXTRA_INTERVAL, 25 * 60).coerceAtLeast(60)
        oneShot = intent.getBooleanExtra(EXTRA_ONE_SHOT, false)
        intentionalStop = false
        startAsForeground()
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        @Suppress("DEPRECATION")
        val resultData = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
        if (resultData == null) {
            stopProjection("屏幕捕获权限无效", true)
            return
        }
        try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val activeProjection = manager.getMediaProjection(resultCode, resultData)
                ?: throw IllegalStateException("系统未返回有效的屏幕捕获会话")
            activeProjection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    ProcessDiagnostics.record(
                        applicationContext,
                        "MEDIA_PROJECTION_STOP",
                        "intentional=$intentionalStop",
                    )
                    if (!intentionalStop) stopProjection("屏幕捕获权限已失效，请重新授权", true)
                }
            }, worker)
            projection = activeProjection
            createVirtualDisplay()
            running = true
            permissionRequired = false
            if (!oneShot) showOverlay()
            val initialDelay = if (oneShot) MANUAL_CAPTURE_DELAY_MS else 700L
            statusMessage = if (oneShot) "手动调试：请在 8 秒内切换到游戏" else "监控运行中"
            emitStatus(System.currentTimeMillis() + initialDelay)
            worker.removeCallbacks(captureTask)
            worker.postDelayed(captureTask, initialDelay)
            updateNotification()
            Log.i(TAG, "MONITOR_START interval=$intervalSeconds")
            ProcessDiagnostics.record(
                applicationContext,
                "MONITOR_START",
                "intervalSeconds=$intervalSeconds oneShot=$oneShot",
            )
        } catch (error: Exception) {
            Log.e(TAG, "MONITOR_ERROR", error)
            stopProjection("无法启动屏幕捕获：${error.message}", true)
            ProcessDiagnostics.record(
                applicationContext,
                "MONITOR_START_FAILED",
                "${error.javaClass.simpleName}: ${error.message}",
            )
        }
    }

    private fun createVirtualDisplay() {
        val metrics = resources.displayMetrics
        if (virtualDisplay != null) {
            refreshDisplayForCurrentOrientation()
            return
        }
        val reader = ImageReader.newInstance(
            metrics.widthPixels,
            metrics.heightPixels,
            PixelFormat.RGBA_8888,
            2,
        )
        imageReader = reader
        virtualDisplay = projection?.createVirtualDisplay(
            "MapSupervisorDisplay",
            metrics.widthPixels,
            metrics.heightPixels,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            worker,
        )
        Log.i(TAG, "DISPLAY_READY width=${metrics.widthPixels} height=${metrics.heightPixels} density=${metrics.densityDpi}")
    }

    private fun refreshDisplayForCurrentOrientation(): Boolean {
        val metrics = resources.displayMetrics
        val reader = imageReader
        if (reader != null && reader.width == metrics.widthPixels && reader.height == metrics.heightPixels) {
            return false
        }
        Log.i(TAG, "DISPLAY_RESIZE width=${reader?.width} height=${reader?.height} -> ${metrics.widthPixels}x${metrics.heightPixels}")
        val display = virtualDisplay ?: return false
        return try {
            val replacement = ImageReader.newInstance(
                metrics.widthPixels,
                metrics.heightPixels,
                PixelFormat.RGBA_8888,
                2,
            )
            display.resize(metrics.widthPixels, metrics.heightPixels, metrics.densityDpi)
            display.surface = replacement.surface
            imageReader = replacement
            reader?.close()
            ProcessDiagnostics.record(
                applicationContext,
                "DISPLAY_RESIZED",
                "width=${metrics.widthPixels} height=${metrics.heightPixels} density=${metrics.densityDpi}",
            )
            true
        } catch (error: Exception) {
            ProcessDiagnostics.record(
                applicationContext,
                "DISPLAY_RESIZE_FAILED",
                "${error.javaClass.simpleName}: ${error.message}",
            )
            Log.e(TAG, "DISPLAY_RESIZE_FAILED", error)
            emit(mapOf("type" to "captureFailed", "message" to "屏幕方向切换失败：${error.message}"))
            false
        }
    }

    private fun captureFrame() {
        if (!running) return
        if (refreshDisplayForCurrentOrientation()) {
            worker.postDelayed({ captureFrame() }, DISPLAY_SETTLE_DELAY_MS)
            return
        }
        Log.i(TAG, "CAPTURE_START")
        val image = imageReader?.acquireLatestImage()
        if (image == null) {
            if (emptyFrameRetries < MAX_EMPTY_FRAME_RETRIES) {
                emptyFrameRetries += 1
                Log.w(TAG, "CAPTURE_RETRY no_image attempt=$emptyFrameRetries")
                worker.postDelayed({ captureFrame() }, EMPTY_FRAME_RETRY_DELAY_MS)
                return
            }
            emptyFrameRetries = 0
            emit(mapOf("type" to "captureFailed", "message" to "无法读取屏幕画面，请确认游戏未禁止录屏"))
            Log.w(TAG, "CAPTURE_FAILED no_image")
            if (oneShot) stopProjection("测试截图失败：无法读取屏幕画面", false)
            return
        }
        emptyFrameRetries = 0
        try {
            val plane = image.planes[0]
            val width = image.width
            val height = image.height
            val rowPadding = plane.rowStride - plane.pixelStride * width
            val paddedWidth = width + rowPadding / plane.pixelStride
            val padded = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
            padded.copyPixelsFromBuffer(plane.buffer)
            val bitmap = Bitmap.createBitmap(padded, 0, 0, width, height)
            if (bitmap !== padded) padded.recycle()
            val now = Date()
            val directory = File(filesDir, SCREENSHOT_DIR).apply { mkdirs() }
            val fileName = "${SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(now)}.png"
            val file = File(directory, fileName)
            FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
            emit(mapOf(
                "type" to "captured",
                "path" to file.absolutePath,
                "timestamp" to now.time,
                "characterName" to RECORD_SOURCE,
            ))
            Log.i(TAG, "CAPTURE_SUCCESS file=$fileName")
            ProcessDiagnostics.record(applicationContext, "CAPTURE_SUCCESS", "file=$fileName")
            if (oneShot) stopProjection("测试截图完成", false)
        } catch (error: Exception) {
            Log.e(TAG, "CAPTURE_FAILED", error)
            ProcessDiagnostics.record(
                applicationContext,
                "CAPTURE_FAILED",
                "${error.javaClass.simpleName}: ${error.message}",
            )
            emit(mapOf("type" to "captureFailed", "message" to "截图失败：${error.message}"))
            if (oneShot) stopProjection("测试截图失败", false)
        } finally {
            image.close()
        }
    }

    private fun stopProjection(message: String, requirePermission: Boolean) {
        if (Looper.myLooper() != worker.looper) {
            worker.post { stopProjection(message, requirePermission) }
            return
        }
        intentionalStop = true
        hideOverlay()
        worker.removeCallbacks(captureTask)
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        projection?.stop()
        projection = null
        running = false
        permissionRequired = requirePermission
        statusMessage = message
        emitStatus()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
        Log.i(TAG, "MONITOR_STOP reason=$message")
        ProcessDiagnostics.record(
            applicationContext,
            "MONITOR_STOP",
            "reason=$message requirePermission=$requirePermission",
        )
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification() {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_menu_view)
        .setContentTitle("MapSupervisor 正在监控")
        .setContentText("监控间隔：${intervalSeconds / 60} 分钟")
        .setOngoing(true)
        .setContentIntent(PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        ))
        .build()

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "屏幕监控", NotificationManager.IMPORTANCE_LOW))
    }

    override fun onDestroy() {
        ProcessDiagnostics.record(
            applicationContext,
            "SERVICE_DESTROY",
            "intentionalStop=$intentionalStop running=$running",
        )
        hideOverlay()
        if (::worker.isInitialized) {
            worker.removeCallbacksAndMessages(null)
            workerThread.quitSafely()
        }
        running = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        ProcessDiagnostics.record(
            applicationContext,
            "TASK_REMOVED",
            "serviceRunning=$running projectionActive=${projection != null}",
        )
        super.onTaskRemoved(rootIntent)
    }

    override fun onTrimMemory(level: Int) {
        ProcessDiagnostics.record(
            applicationContext,
            "TRIM_MEMORY",
            "level=$level serviceRunning=$running projectionActive=${projection != null}",
        )
        super.onTrimMemory(level)
    }

    override fun onLowMemory() {
        ProcessDiagnostics.record(
            applicationContext,
            "LOW_MEMORY_CALLBACK",
            "serviceRunning=$running projectionActive=${projection != null}",
        )
        super.onLowMemory()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        main.post { overlay?.onConfigurationChanged() }
        if (::worker.isInitialized && running) {
            worker.post {
                val resized = refreshDisplayForCurrentOrientation()
                Log.i(TAG, "DISPLAY_CONFIGURATION_CHANGED orientation=${newConfig.orientation}")
                ProcessDiagnostics.record(
                    applicationContext,
                    "DISPLAY_CONFIGURATION_CHANGED",
                    "orientation=${newConfig.orientation} resized=$resized",
                )
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showOverlay() {
        main.post {
            val activeOverlay = overlay ?: MonitoringOverlay(
                context = applicationContext,
                onCapture = { worker.post { captureFrame() } },
                onStop = { worker.post { stopProjection("监控已停止", false) } },
                onOpenApp = {
                    packageManager.getLaunchIntentForPackage(packageName)?.let { launchIntent ->
                        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        startActivity(launchIntent)
                    }
                },
                onError = { action, error ->
                    ProcessDiagnostics.record(
                        applicationContext,
                        "OVERLAY_${action}_FAILED",
                        "${error.javaClass.simpleName}: ${error.message}",
                    )
                },
            ).also { overlay = it }
            activeOverlay.show()
        }
    }

    private fun hideOverlay() {
        main.post {
            overlay?.hide()
            overlay = null
        }
    }

    companion object {
        const val ACTION_START = "com.mapsupervisor.START"
        const val ACTION_STOP = "com.mapsupervisor.STOP"
        const val ACTION_CAPTURE = "com.mapsupervisor.CAPTURE"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_INTERVAL = "interval"
        const val EXTRA_ONE_SHOT = "oneShot"
        private const val CHANNEL_ID = "map_supervisor_monitoring"
        private const val NOTIFICATION_ID = 2401
        private const val SCREENSHOT_DIR = "screenshots"
        private const val TAG = "MapSupervisor"
        private const val RECORD_SOURCE = "monitor"
        private const val MANUAL_CAPTURE_DELAY_MS = 8_000L
        private const val DISPLAY_SETTLE_DELAY_MS = 700L
        private const val EMPTY_FRAME_RETRY_DELAY_MS = 400L
        private const val MAX_EMPTY_FRAME_RETRIES = 3
        private val main = Handler(Looper.getMainLooper())

        @Volatile var running = false
        @Volatile var permissionRequired = false
        @Volatile var statusMessage: String? = null
        @Volatile var eventSink: EventChannel.EventSink? = null

        fun emitStatus(nextCaptureAt: Long? = null) {
            val data = mutableMapOf<String, Any?>(
                "type" to "status",
                "running" to running,
                "permissionRequired" to permissionRequired,
                "message" to statusMessage,
            )
            if (nextCaptureAt != null) data["nextCaptureAt"] = nextCaptureAt
            emit(data)
        }

        private fun emit(value: Any) { main.post { eventSink?.success(value) } }

        fun emitPendingScreenshots(context: Context) {
            val directory = File(context.filesDir, SCREENSHOT_DIR)
            directory.listFiles { file -> file.extension.equals("png", true) }
                ?.sortedBy { it.lastModified() }
                ?.forEach { file ->
                    emit(mapOf(
                        "type" to "captured",
                        "path" to file.absolutePath,
                        "timestamp" to file.lastModified(),
                        "characterName" to RECORD_SOURCE,
                    ))
                }
        }
    }
}
