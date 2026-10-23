package com.spatialbridge.core.transfer

import com.spatialbridge.core.model.canonicallyEquals
import com.spatialbridge.core.model.graphemes
import java.text.Normalizer
import java.util.Locale

/**
 * Produces safe filenames from untrusted input, matching Swift's `FilenameSanitizer` (`sanitizer`
 * vectors): last path component, NFC, no C0/DEL/colon, trimmed, no leading dots, extension from the
 * content type when missing, conservative lowercase extension, at most 255 UTF-8 bytes by grapheme.
 */
object FilenameSanitizer {
    const val MAX_UTF8_BYTES = 255
    const val FALLBACK_BASE_NAME = "Received file"

    fun sanitize(name: String, contentType: String? = null): String {
        val components = splitPath(name)
        var base = components.lastOrNull() ?: ""
        base = Normalizer.normalize(base, Normalizer.Form.NFC)
        base = buildString {
            base.codePoints().forEach { cp -> if (cp >= 0x20 && cp != 0x7F && cp != ':'.code) appendCodePoint(cp) }
        }
        base = trimWhitespace(base)
        while (base.isNotEmpty() && graphemes(base).first() == ".") base = base.substring(1)
        base = trimWhitespace(base)
        if (base.isEmpty() || base == "." || base == "..") base = FALLBACK_BASE_NAME

        var stem = deletingPathExtension(base)
        var ext = pathExtension(base)
        if (stem.isEmpty()) stem = FALLBACK_BASE_NAME
        if (ext.isEmpty() && contentType != null) UtiMap.preferredExtension(contentType)?.let { ext = it }
        ext = buildString {
            ext.codePoints().forEach { cp -> if (isAlphanumeric(cp) || cp == '-'.code || cp == '_'.code) appendCodePoint(cp) }
        }.lowercase(Locale.ROOT)
        val extGraphemes = graphemes(ext)
        if (extGraphemes.size > 16) ext = extGraphemes.take(16).joinToString("")
        return truncate(stem, ext)
    }

    /**
     * `IMG.jpeg`, attempt 2 → `IMG 2.jpeg`. The stem is cut first, by grapheme, so `stem N.ext` fits
     * in 255 UTF-8 bytes and the counter is always kept (Swift `candidate(for:attempt:)`).
     */
    fun candidate(name: String, attempt: Int): String {
        if (attempt <= 1) return name
        val ext = pathExtension(name)
        val counter = " $attempt"
        val suffix = if (ext.isEmpty()) "" else ".$ext"
        var trimmed = trimToUtf8(deletingPathExtension(name), MAX_UTF8_BYTES - utf8Length(suffix) - utf8Length(counter))
        if (trimmed.isEmpty()) trimmed = FALLBACK_BASE_NAME
        return truncate(trimmed + counter, ext)
    }

    /**
     * True if [name] is what [sanitize] produces; used to validate incoming offers. Like Swift's
     * `String ==`, the comparison is by canonical equivalence, so a decomposed name is safe.
     */
    fun isSafe(name: String): Boolean = canonicallyEquals(sanitize(name), name) && '/' !in name && '\\' !in name

    private fun truncate(stem: String, ext: String): String {
        val suffix = if (ext.isEmpty()) "" else ".$ext"
        val budget = MAX_UTF8_BYTES - utf8Length(suffix)
        var trimmed = trimToUtf8(stem, budget)
        if (trimmed.isEmpty()) trimmed = FALLBACK_BASE_NAME
        return trimmed + suffix
    }

    /** Drops whole trailing grapheme clusters until [text] is at most [budget] UTF-8 bytes. */
    private fun trimToUtf8(text: String, budget: Int): String {
        if (utf8Length(text) <= budget) return text
        val clusters = graphemes(text).toMutableList()
        var length = utf8Length(text)
        while (length > budget && clusters.isNotEmpty()) length -= utf8Length(clusters.removeAt(clusters.size - 1))
        return clusters.joinToString("")
    }

    private fun utf8Length(text: String): Int = text.toByteArray(Charsets.UTF_8).size

    /** Swift `split(whereSeparator:)` on Characters equal to `/` or `\`, dropping empty pieces. */
    private fun splitPath(name: String): List<String> {
        val out = ArrayList<String>()
        val current = StringBuilder()
        for (cluster in graphemes(name)) {
            if (cluster == "/" || cluster == "\\") {
                if (current.isNotEmpty()) out += current.toString()
                current.clear()
            } else {
                current.append(cluster)
            }
        }
        if (current.isNotEmpty()) out += current.toString()
        return out
    }

    /** `CharacterSet.whitespacesAndNewlines`: Z*, U+0009–U+000D and U+0085. */
    private fun isWhitespace(cp: Int): Boolean = cp in 0x09..0x0D || cp == 0x85 || when (Character.getType(cp)) {
        Character.SPACE_SEPARATOR.toInt(), Character.LINE_SEPARATOR.toInt(), Character.PARAGRAPH_SEPARATOR.toInt() -> true
        else -> false
    }

    private fun trimWhitespace(text: String): String {
        var start = 0
        var end = text.length
        while (start < end && isWhitespace(text.codePointAt(start))) start += Character.charCount(text.codePointAt(start))
        while (end > start && isWhitespace(text.codePointBefore(end))) end -= Character.charCount(text.codePointBefore(end))
        return text.substring(start, end)
    }

    /** `CharacterSet.alphanumerics`: letters, marks and numbers. */
    private fun isAlphanumeric(cp: Int): Boolean = when (Character.getType(cp)) {
        Character.UPPERCASE_LETTER.toInt(), Character.LOWERCASE_LETTER.toInt(), Character.TITLECASE_LETTER.toInt(),
        Character.MODIFIER_LETTER.toInt(), Character.OTHER_LETTER.toInt(),
        Character.NON_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(),
        Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
        else -> false
    }

    /** The dot index that starts a valid extension, like `NSString.pathExtension`, or -1. */
    private fun extensionDot(name: String): Int {
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || dot == name.length - 1) return -1
        if (' ' in name.substring(dot + 1)) return -1
        return dot
    }

    fun pathExtension(name: String): String = extensionDot(name).let { if (it < 0) "" else name.substring(it + 1) }

    fun deletingPathExtension(name: String): String = extensionDot(name).let { if (it < 0) name else name.substring(0, it) }
}
