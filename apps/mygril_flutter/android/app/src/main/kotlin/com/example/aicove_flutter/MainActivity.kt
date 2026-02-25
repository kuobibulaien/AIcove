package com.example.aicove_flutter

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SYSTEM_PROXY_CHANNEL = "com.example.aicove_flutter/system_proxy"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_PROXY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemProxy" -> result.success(querySystemProxy())
                    else -> result.notImplemented()
                }
            }
    }

    private fun querySystemProxy(): Map<String, Any?> {
        val fromConnectivity = queryConnectivityProxy()
        if (fromConnectivity != null) return fromConnectivity
        return querySystemPropertyProxy()
    }

    private fun queryConnectivityProxy(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }

        return try {
            val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return null
            val info = manager.defaultProxy ?: return null

            val host = info.host?.trim().orEmpty()
            val port = info.port
            val exclusionList = info.exclusionList?.joinToString(",") ?: ""
            val pacUrl = info.pacFileUrl?.toString().orEmpty()

            val enabled = host.isNotEmpty() && port > 0
            mapOf(
                "enabled" to enabled,
                "host" to if (host.isNotEmpty()) host else null,
                "port" to if (port > 0) port else null,
                "exclusionList" to exclusionList,
                "pacUrl" to pacUrl,
            )
        } catch (_: Throwable) {
            null
        }
    }

    private fun querySystemPropertyProxy(): Map<String, Any?> {
        val host = (System.getProperty("http.proxyHost")
            ?: System.getProperty("https.proxyHost")
            ?: "").trim()

        val portString = (System.getProperty("http.proxyPort")
            ?: System.getProperty("https.proxyPort")
            ?: "").trim()
        val port = portString.toIntOrNull()

        val exclusionList = (System.getProperty("http.nonProxyHosts")
            ?: System.getProperty("https.nonProxyHosts")
            ?: "").trim()

        val enabled = host.isNotEmpty() && (port ?: -1) > 0
        return mapOf(
            "enabled" to enabled,
            "host" to if (host.isNotEmpty()) host else null,
            "port" to port,
            "exclusionList" to exclusionList,
            "pacUrl" to "",
        )
    }
}
