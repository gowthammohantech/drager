package com.spatialbridge.android.content

import java.text.Normalizer

/**
 * Placeholder for Lane K's FilenameSanitizer port: the same rules as Swift's `FilenameSanitizer.sanitize`
 * (last path component, NFC, no control chars or colons, no leading dots, 255 UTF-8 bytes keeping the
 * extension). The `sanitizer` conformance vectors are the reference; swap in core's version when wiring.
 */
interface FilenameRules {
    fun sanitize(name: String, contentType: String? = null): String
}

class PlaceholderFilenameRules(private val utis: UtiResolver) : FilenameRules {
    override fun sanitize(name: String, contentType: String?): String {
        var base = name.split('/', '\\').lastOrNull().orEmpty()
        base = Normalizer.normalize(base, Normalizer.Form.NFC)
        base = base.filter { c -> !(c.code < 0x20 || c.code == 0x7F) && c != ':' }
        base = base.trim()
        base = base.trimStart('.').trim()
        if (base.isEmpty()) base = FALLBACK

        val dot = base.lastIndexOf('.')
        var stem = if (dot > 0) base.substring(0, dot) else base
        var ext = if (dot > 0) base.substring(dot + 1) else ""
        if (stem.isEmpty()) stem = FALLBACK
        if (ext.isEmpty() && contentType != null) ext = utis.preferredExtension(contentType).orEmpty()
        ext = ext.filter { it.isLetterOrDigit() || it == '-' || it == '_' }.lowercase().take(16)

        val suffix = if (ext.isEmpty()) "" else ".$ext"
        val budget = MAX_BYTES - suffix.encodeToByteArray().size
        var trimmed = stem
        while (trimmed.encodeToByteArray().size > budget && trimmed.isNotEmpty()) {
            // Drop whole code points, never half a surrogate pair.
            trimmed = trimmed.substring(0, trimmed.offsetByCodePoints(trimmed.length, -1))
        }
        if (trimmed.isEmpty()) trimmed = FALLBACK
        return trimmed + suffix
    }

    companion object {
        const val MAX_BYTES = 255
        const val FALLBACK = "Received file"
    }
}
