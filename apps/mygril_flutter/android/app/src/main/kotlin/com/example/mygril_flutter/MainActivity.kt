package com.example.mygril_flutter

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/// MainActivity - 应用入口
/// 
/// 更新记录：
/// - 2025-12-08: 启用 120Hz 高刷新率支持
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // 请求最高刷新率（120Hz / 90Hz）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ 使用新 API
            window.attributes.layoutInDisplayCutoutMode = 
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            
            val display = display
            if (display != null) {
                val modes = display.supportedModes
                val highestMode = modes.maxByOrNull { it.refreshRate }
                if (highestMode != null) {
                    val params = window.attributes
                    params.preferredDisplayModeId = highestMode.modeId
                    window.attributes = params
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Android 6-10 使用旧 API
            @Suppress("DEPRECATION")
            val display = windowManager.defaultDisplay
            val modes = display.supportedModes
            val highestMode = modes.maxByOrNull { it.refreshRate }
            if (highestMode != null) {
                val params = window.attributes
                params.preferredDisplayModeId = highestMode.modeId
                window.attributes = params
            }
        }
    }
}
