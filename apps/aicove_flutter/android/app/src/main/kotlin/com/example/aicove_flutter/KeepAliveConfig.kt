package com.example.aicove_flutter

import android.content.Context

object KeepAliveConfig {
    private const val PREFS_NAME = "aicove_keep_alive"
    private const val KEY_GUARD_ENABLED = "guard_enabled"

    fun isGuardEnabled(context: Context): Boolean {
        return prefs(context).getBoolean(KEY_GUARD_ENABLED, false)
    }

    fun setGuardEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_GUARD_ENABLED, enabled).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
