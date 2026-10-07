package com.mapsupervisor.map_supervisor

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.media.projection.MediaProjectionConfig
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val requestCapture = 7314
    private val requestOverlay = 7316
    private val requestConfigImport = 7317
    private val requestConfigExport = 7318
    private var pendingOneShot = false
    private var pendingInterval = 25 * 60
    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfigResult: MethodChannel.Result? = null
    private var pendingConfigJson: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        ProcessDiagnostics.installCrashHandler(applicationContext)
        ProcessDiagnostics.recordHistoricalExitReasons(applicationContext)
        ProcessDiagnostics.record(applicationContext, "ACTIVITY_CREATE")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startMonitoring" -> requestProjection(call.argument<Int>("intervalSeconds") ?: 25 * 60, false, result)
                "captureNow" -> {
                    if (MonitoringService.running) {
                        startService(Intent(this, MonitoringService::class.java).setAction(MonitoringService.ACTION_CAPTURE))
                        result.success(null)
                    } else {
                        requestProjection(call.argument<Int>("intervalSeconds") ?: 25 * 60, true, result)
                    }
                }
                "stopMonitoring" -> {
                    startService(Intent(this, MonitoringService::class.java).setAction(MonitoringService.ACTION_STOP))
                    result.success(null)
                }
                "getStatus" -> result.success(mapOf(
                    "running" to MonitoringService.running,
                    "permissionRequired" to MonitoringService.permissionRequired,
                    "message" to MonitoringService.statusMessage,
                ))
                "getDiagnostics" -> result.success(ProcessDiagnostics.read(applicationContext))
                "clearDiagnostics" -> {
                    ProcessDiagnostics.clear(applicationContext)
                    ProcessDiagnostics.record(applicationContext, "DIAGNOSTICS_CLEARED")
                    result.success(null)
                }
                "importConfigJson" -> importConfigJson(result)
                "exportConfigJson" -> exportConfigJson(
                    call.argument<String>("json") ?: "",
                    call.argument<String>("fileName") ?: "MapSupervisor-config.json",
                    result,
                )
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                MonitoringService.eventSink = events
                MonitoringService.emitStatus()
                MonitoringService.emitPendingScreenshots(applicationContext)
            }
            override fun onCancel(arguments: Any?) { MonitoringService.eventSink = null }
        })
    }

    override fun onStart() {
        super.onStart()
        ProcessDiagnostics.record(applicationContext, "ACTIVITY_START")
    }

    override fun onResume() {
        super.onResume()
        ProcessDiagnostics.record(applicationContext, "ACTIVITY_RESUME")
    }

    override fun onPause() {
        ProcessDiagnostics.record(applicationContext, "ACTIVITY_PAUSE")
        super.onPause()
    }

    override fun onStop() {
        ProcessDiagnostics.record(applicationContext, "ACTIVITY_STOP", "changingConfig=$isChangingConfigurations")
        super.onStop()
    }

    override fun onDestroy() {
        ProcessDiagnostics.record(applicationContext, "ACTIVITY_DESTROY", "changingConfig=$isChangingConfigurations")
        super.onDestroy()
    }

    private fun requestProjection(interval: Int, oneShot: Boolean, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("CAPTURE_REQUEST_ACTIVE", "屏幕捕获授权正在进行", null)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7315)
        }
        pendingInterval = interval.coerceAtLeast(60)
        pendingOneShot = oneShot
        pendingResult = result
        if (!oneShot && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            val overlayIntent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            startActivityForResult(overlayIntent, requestOverlay)
            return
        }
        launchProjectionPermission()
    }

    private fun launchProjectionPermission() {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val captureIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        startActivityForResult(captureIntent, requestCapture)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == requestConfigImport) {
            val result = pendingConfigResult
            pendingConfigResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(null)
                return
            }
            try {
                val source = contentResolver.openInputStream(data.data!!)
                    ?.bufferedReader(Charsets.UTF_8)
                    ?.use { it.readText() }
                    ?: throw IllegalStateException("无法读取所选文件")
                ProcessDiagnostics.record(applicationContext, "CONFIG_IMPORTED")
                result?.success(source)
            } catch (error: Exception) {
                ProcessDiagnostics.record(
                    applicationContext,
                    "CONFIG_IMPORT_FAILED",
                    "${error.javaClass.simpleName}: ${error.message}",
                )
                result?.error("CONFIG_IMPORT_FAILED", "读取配置文件失败：${error.message}", null)
            }
            return
        }
        if (requestCode == requestConfigExport) {
            val result = pendingConfigResult
            pendingConfigResult = null
            val json = pendingConfigJson
            pendingConfigJson = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(false)
                return
            }
            try {
                contentResolver.openOutputStream(data.data!!, "wt")
                    ?.bufferedWriter(Charsets.UTF_8)
                    ?.use { it.write(json ?: "") }
                    ?: throw IllegalStateException("无法写入所选文件")
                ProcessDiagnostics.record(applicationContext, "CONFIG_EXPORTED")
                result?.success(true)
            } catch (error: Exception) {
                ProcessDiagnostics.record(
                    applicationContext,
                    "CONFIG_EXPORT_FAILED",
                    "${error.javaClass.simpleName}: ${error.message}",
                )
                result?.error("CONFIG_EXPORT_FAILED", "写入配置文件失败：${error.message}", null)
            }
            return
        }
        if (requestCode == requestOverlay) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)) {
                launchProjectionPermission()
            } else {
                val result = pendingResult
                pendingResult = null
                result?.error("OVERLAY_PERMISSION_DENIED", "需要悬浮窗权限才能显示监控控制条", null)
            }
            return
        }
        if (requestCode != requestCapture) return
        val result = pendingResult
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            MonitoringService.permissionRequired = true
            MonitoringService.statusMessage = "用户未授予屏幕捕获权限"
            MonitoringService.emitStatus()
            result?.error("PERMISSION_DENIED", "未授予屏幕捕获权限", null)
            return
        }
        val intent = Intent(this, MonitoringService::class.java).apply {
            action = MonitoringService.ACTION_START
            putExtra(MonitoringService.EXTRA_RESULT_CODE, resultCode)
            putExtra(MonitoringService.EXTRA_RESULT_DATA, data)
            putExtra(MonitoringService.EXTRA_INTERVAL, pendingInterval)
            putExtra(MonitoringService.EXTRA_ONE_SHOT, pendingOneShot)
        }
        ContextCompat.startForegroundService(this, intent)
        result?.success(null)
    }

    private fun importConfigJson(result: MethodChannel.Result) {
        if (pendingConfigResult != null) {
            result.error("CONFIG_FILE_REQUEST_ACTIVE", "配置文件选择器正在使用", null)
            return
        }
        pendingConfigResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/json", "text/plain"))
        }
        startActivityForResult(intent, requestConfigImport)
    }

    private fun exportConfigJson(json: String, fileName: String, result: MethodChannel.Result) {
        if (pendingConfigResult != null) {
            result.error("CONFIG_FILE_REQUEST_ACTIVE", "配置文件选择器正在使用", null)
            return
        }
        pendingConfigResult = result
        pendingConfigJson = json
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, requestConfigExport)
    }

    companion object {
        const val CHANNEL = "com.mapsupervisor/capture"
        const val EVENTS = "com.mapsupervisor/capture_events"
    }
}
