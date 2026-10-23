package com.spatialbridge.android.diagnostics

import android.util.Log

/** Log-safe forms of sensitive values (mirrors Swift `Redaction`). Never log raw filenames or secrets. */
object Redaction {
    /** `***.jpg (a1b2c3)`: keeps the extension and a stable FNV-1a correlation hash. */
    fun filename(name: String): String {
        val dot = name.lastIndexOf('.')
        val ext = if (dot > 0 && dot < name.length - 1) name.substring(dot + 1) else ""
        val hash = stableHash(name)
        return if (ext.isEmpty()) "*** ($hash)" else "***.$ext ($hash)"
    }

    /** First 8 hex digits of a peer ID; enough to correlate, too short to matter. */
    fun peer(peerID: String): String = peerID.take(8) + "…"

    fun stableHash(string: String): String {
        var hash = 2_166_136_261u
        for (byte in string.encodeToByteArray()) {
            hash = hash xor byte.toUByte().toUInt()
            hash *= 16_777_619u
        }
        return "%06x".format((hash and 0xFFFFFFu).toInt())
    }
}

/** The only logging entry point in the app. Callers must pass already-redacted strings. */
object BridgeLog {
    private const val TAG = "SpatialBridge"
    fun info(message: String) { Log.i(TAG, message) }
    fun warn(message: String) { Log.w(TAG, message) }
}
