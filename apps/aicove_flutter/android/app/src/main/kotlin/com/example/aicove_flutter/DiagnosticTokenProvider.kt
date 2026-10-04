package com.example.aicove_flutter

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri

/**
 * Hands the in-memory diagnostic access token to an authorized ADB shell.
 *
 * Read access requires android.permission.DUMP (held by the adb shell user,
 * not grantable to ordinary apps), so other apps on the device still cannot
 * reach the loopback diagnostic channel. The token only exists while the
 * Flutter side has opened the channel; a cold process returns no rows.
 *
 *   adb shell content query --uri content://com.example.aicove_flutter.diagnostics/token
 */
class DiagnosticTokenProvider : ContentProvider() {
    companion object {
        @Volatile
        var token: String? = null
    }

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val cursor = MatrixCursor(arrayOf("token"))
        if (uri.lastPathSegment == "token") token?.let { cursor.addRow(arrayOf(it)) }
        return cursor
    }

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
