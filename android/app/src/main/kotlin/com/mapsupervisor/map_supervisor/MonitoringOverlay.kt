package com.mapsupervisor.map_supervisor

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

class MonitoringOverlay(
    private val context: Context,
    private val onCapture: () -> Unit,
    private val onStop: () -> Unit,
    private val onOpenApp: () -> Unit,
    private val onError: (String, Throwable) -> Unit,
) {
    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private var root: LinearLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var sideIndicator: TextView? = null
    private var collapsed = preferences.getBoolean(KEY_COLLAPSED, false)
    private var side = OverlaySide.from(preferences.getString(KEY_SIDE, null))

    fun show() {
        if (root != null || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(context))) return

        val density = context.resources.displayMetrics.density
        val container = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            elevation = dp(8, density).toFloat()
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.START or Gravity.BOTTOM
            x = 0
            y = preferences.getInt(KEY_VERTICAL_POSITION, dp(72, density))
        }

        root = container
        layoutParams = params
        render()
        runCatching {
            windowManager.addView(container, params)
            container.post { snapToSide(side, persist = false) }
        }.onFailure { error ->
            root = null
            layoutParams = null
            onError("SHOW", error)
        }
    }

    fun hide() {
        val active = root ?: return
        runCatching { windowManager.removeView(active) }
            .onFailure { error -> onError("HIDE", error) }
        root = null
        layoutParams = null
    }

    fun onConfigurationChanged() {
        root?.post { snapToSide(side, persist = false) }
    }

    private fun render() {
        val container = root ?: return
        val params = layoutParams ?: return
        val density = context.resources.displayMetrics.density
        container.removeAllViews()
        container.setOnTouchListener(null)
        sideIndicator = null
        container.minimumWidth = 0
        container.setPadding(
            dp(if (collapsed) 7 else 12, density),
            dp(6, density),
            dp(if (collapsed) 7 else 6, density),
            dp(6, density),
        )
        container.background = overlayBackground(density)

        if (collapsed) {
            container.minimumWidth = dp(48, density)
            container.contentDescription = "展开 MapSupervisor 悬浮窗"
            val tab = label(
                if (side == OverlaySide.LEFT) "●  ›" else "‹  ●",
                Color.rgb(76, 217, 100),
                density,
            ).apply {
                textSize = 16f
                setPadding(dp(3, density), 0, dp(3, density), 0)
            }
            sideIndicator = tab
            container.addView(tab)
            makeDraggable(container, container, params) { setCollapsed(false) }
            return
        }

        container.contentDescription = "MapSupervisor 监控悬浮窗"
        val status = label("● 监控中", Color.rgb(76, 217, 100), density).apply {
            setPadding(dp(4, density), 0, dp(10, density), 0)
            contentDescription = "拖动监控悬浮窗"
        }
        container.addView(status)
        container.addView(action("截图", density, onCapture))
        container.addView(action("打开", density, onOpenApp))
        container.addView(action("停止", density, onStop, Color.rgb(255, 110, 100)))
        val collapse = action(
            if (side == OverlaySide.LEFT) "‹" else "›",
            density,
            { setCollapsed(true) },
            Color.rgb(190, 200, 220),
        ).apply { contentDescription = "收起到侧边" }
        sideIndicator = collapse
        container.addView(collapse)
        makeDraggable(status, container, params)
    }

    private fun setCollapsed(value: Boolean) {
        if (collapsed == value) return
        collapsed = value
        preferences.edit().putBoolean(KEY_COLLAPSED, collapsed).apply()
        root?.post {
            render()
            root?.post { snapToSide(side) }
        }
    }

    private fun action(
        text: String,
        density: Float,
        callback: () -> Unit,
        color: Int = Color.WHITE,
    ) = label(text, color, density).apply {
        setPadding(dp(10, density), dp(8, density), dp(10, density), dp(8, density))
        setOnClickListener { callback() }
    }

    private fun label(text: String, color: Int, density: Float) = TextView(context).apply {
        this.text = text
        setTextColor(color)
        textSize = 14f
        gravity = Gravity.CENTER
        minHeight = dp(36, density)
    }

    private fun overlayBackground(density: Float) = GradientDrawable().apply {
        cornerRadius = dp(if (collapsed) 16 else 24, density).toFloat()
        setColor(Color.argb(225, 25, 28, 34))
        setStroke(dp(1, density), Color.argb(190, 120, 130, 150))
    }

    private fun makeDraggable(
        handle: View,
        target: View,
        params: WindowManager.LayoutParams,
        onTap: (() -> Unit)? = null,
    ) {
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        val threshold = dp(6, context.resources.displayMetrics.density)
        handle.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    moved = moved || abs(dx) > threshold || abs(dy) > threshold
                    val (screenWidth, screenHeight) = screenSize()
                    params.x = (startX + dx).toInt().coerceIn(0, (screenWidth - target.width).coerceAtLeast(0))
                    params.y = (startY - dy).toInt().coerceIn(0, (screenHeight - target.height).coerceAtLeast(0))
                    runCatching { windowManager.updateViewLayout(target, params) }
                        .onFailure { error -> onError("MOVE", error) }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) {
                        val (screenWidth, _) = screenSize()
                        val targetSide = if (params.x + target.width / 2 < screenWidth / 2) {
                            OverlaySide.LEFT
                        } else {
                            OverlaySide.RIGHT
                        }
                        snapToSide(targetSide)
                    } else {
                        onTap?.invoke()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    if (moved) snapToSide(side)
                    true
                }
                else -> false
            }
        }
    }

    private fun snapToSide(targetSide: OverlaySide, persist: Boolean = true) {
        val target = root ?: return
        val params = layoutParams ?: return
        val (screenWidth, screenHeight) = screenSize()
        side = targetSide
        params.x = if (side == OverlaySide.LEFT) 0 else (screenWidth - target.width).coerceAtLeast(0)
        params.y = params.y.coerceIn(0, (screenHeight - target.height).coerceAtLeast(0))
        runCatching { windowManager.updateViewLayout(target, params) }
            .onFailure { error -> onError("SNAP", error) }
        if (persist) {
            preferences.edit()
                .putString(KEY_SIDE, side.name)
                .putInt(KEY_VERTICAL_POSITION, params.y)
                .apply()
        }
        sideIndicator?.text = if (collapsed) {
            if (side == OverlaySide.LEFT) "●  ›" else "‹  ●"
        } else {
            if (side == OverlaySide.LEFT) "‹" else "›"
        }
    }

    private fun screenSize(): Pair<Int, Int> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        val bounds = windowManager.currentWindowMetrics.bounds
        bounds.width() to bounds.height()
    } else {
        @Suppress("DEPRECATION")
        context.resources.displayMetrics.run { widthPixels to heightPixels }
    }

    private fun dp(value: Int, density: Float) = (value * density).toInt()

    private enum class OverlaySide {
        LEFT,
        RIGHT;

        companion object {
            fun from(value: String?) = values().firstOrNull { it.name == value } ?: LEFT
        }
    }

    companion object {
        private const val PREFERENCES = "monitoring_overlay"
        private const val KEY_COLLAPSED = "collapsed"
        private const val KEY_SIDE = "side"
        private const val KEY_VERTICAL_POSITION = "vertical_position"
    }
}
