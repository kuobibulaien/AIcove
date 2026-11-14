package com.example.aicove_flutter

import android.content.Context
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.ConnectivityManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import java.io.File
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SYSTEM_PROXY_CHANNEL = "com.example.aicove_flutter/system_proxy"
    }

    private var keepAliveChannel: MethodChannel? = null

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

        // 只读自身构建/运行身份，无导出组件、无新系统权限。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.aicove_flutter/diagnostic_identity")
            .setMethodCallHandler { call, result ->
                if (call.method == "read") {
                    result.success(mapOf(
                        "buildId" to BuildConfig.DIAGNOSTIC_BUILD_ID,
                        "buildType" to BuildConfig.BUILD_TYPE,
                        "versionName" to BuildConfig.VERSION_NAME,
                        "versionCode" to BuildConfig.VERSION_CODE,
                        "deviceModel" to Build.MODEL,
                        "androidApi" to Build.VERSION.SDK_INT,
                        "identityScope" to "android_source_snapshot_no_hot_reload"
                    ))
                } else if (call.method == "publishAccessToken") {
                    DiagnosticTokenProvider.token = call.arguments as? String
                    result.success(null)
                } else result.notImplemented()
            }

        // 设备显示名：系统“关于手机”里的设备名，读不到时用厂商+型号；无需权限。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aicove/device_name")
            .setMethodCallHandler { call, result ->
                if (call.method != "read") return@setMethodCallHandler result.notImplemented()
                val named = Settings.Global.getString(contentResolver, "device_name")
                result.success(
                    named?.takeIf { it.isNotBlank() }
                        ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"
                )
            }

        // 空间文件用系统默认应用查看；路径只来自应用缓存里的副本。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aicove/open_file")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") return@setMethodCallHandler result.notImplemented()
                val path = call.argument<String>("path")
                    ?: return@setMethodCallHandler result.error("bad_args", "path", null)
                val uri = FileProvider.getUriForFile(this, "$packageName.workspace_files", File(path))
                val intent = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, call.argument<String>("mime") ?: "*/*")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                try {
                    startActivity(intent)
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_PROXY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemProxy" -> result.success(querySystemProxy())
                    else -> result.notImplemented()
                }
            }

        val channel = KeepAliveConfig.createChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        keepAliveChannel = channel
        ProactiveAlarmScheduler.attachMainChannel(applicationContext, channel)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        keepAliveChannel?.let { channel ->
            ProactiveAlarmScheduler.detachMainChannel(applicationContext, channel)
            channel.setMethodCallHandler(null)
        }
        keepAliveChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
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
