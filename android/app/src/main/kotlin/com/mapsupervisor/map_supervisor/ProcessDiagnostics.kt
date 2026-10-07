package com.mapsupervisor.map_supervisor

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

object ProcessDiagnostics {
    private const val TAG = "MapSupervisorDiag"
    private const val FILE_NAME = "process-diagnostics.log"
    private const val MAX_FILE_BYTES = 512 * 1024L
    private const val PREFS = "process_diagnostics"
    private const val LAST_EXIT_TIMESTAMP = "last_exit_timestamp"
    private val lock = Any()
    private val crashHandlerInstalled = AtomicBoolean(false)

    fun installCrashHandler(context: Context) {
        if (!crashHandlerInstalled.compareAndSet(false, true)) return
        val applicationContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                record(
                    applicationContext,
                    "UNCAUGHT_EXCEPTION",
                    "thread=${thread.name} ${error.stackTraceToString()}",
                )
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun record(context: Context, event: String, details: String = "") {
        val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        val cleanDetails = details.replace('\n', ' ').replace('\r', ' ')
        val line = "$timestamp | $event${if (cleanDetails.isBlank()) "" else " | $cleanDetails"}\n"
        Log.i(TAG, line.trim())
        synchronized(lock) {
            val file = diagnosticFile(context)
            if (file.exists() && file.length() >= MAX_FILE_BYTES) {
                val backup = File(file.parentFile, "$FILE_NAME.1")
                if (backup.exists()) backup.delete()
                file.renameTo(backup)
            }
            file.appendText(line)
        }
    }

    fun read(context: Context): String = synchronized(lock) {
        val current = diagnosticFile(context)
        val backup = File(current.parentFile, "$FILE_NAME.1")
        buildString {
            if (backup.exists()) append(backup.readText())
            if (current.exists()) append(current.readText())
        }.ifBlank { "暂无进程诊断日志" }
    }

    fun clear(context: Context) = synchronized(lock) {
        val current = diagnosticFile(context)
        File(current.parentFile, "$FILE_NAME.1").delete()
        current.delete()
        Unit
    }

    fun recordHistoricalExitReasons(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        runCatching {
            val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val lastTimestamp = preferences.getLong(LAST_EXIT_TIMESTAMP, 0L)
            val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val exits = activityManager
                .getHistoricalProcessExitReasons(context.packageName, 0, 10)
                .filter { it.timestamp > lastTimestamp }
                .sortedBy { it.timestamp }
            exits.forEach { exit ->
                record(
                    context,
                    "PREVIOUS_PROCESS_EXIT",
                    "time=${formatTimestamp(exit.timestamp)} reason=${reasonName(exit.reason)} " +
                        "status=${exit.status} importance=${exit.importance} " +
                        "pssKb=${exit.pss / 1024} rssKb=${exit.rss / 1024} " +
                        "description=${exit.description ?: "-"}",
                )
            }
            exits.maxOfOrNull { it.timestamp }?.let { newest ->
                preferences.edit().putLong(LAST_EXIT_TIMESTAMP, newest).apply()
            }
        }.onFailure { error ->
            record(context, "EXIT_REASON_QUERY_FAILED", "${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun reasonName(reason: Int) = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        else -> "UNKNOWN($reason)"
    }

    private fun diagnosticFile(context: Context) = File(context.filesDir, FILE_NAME)

    private fun formatTimestamp(timestamp: Long) =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(timestamp))
}
