package com.spatialbridge.android.content

/**
 * Maps an Android file to the Apple UTI the wire carries (ADR-015): extension first, then MIME type,
 * then `public.data`. Never returns `dyn.*`. This is a placeholder table; Lane K's UtiMap (shared with
 * the vectors) replaces it when the app is wired to core.
 */
interface UtiResolver {
    fun resolve(filename: String, mimeType: String?): String
    fun preferredExtension(uti: String): String?
}

object PlaceholderUtiResolver : UtiResolver {
    const val FALLBACK = "public.data"

    private val byExtension = mapOf(
        "jpg" to "public.jpeg", "jpeg" to "public.jpeg", "png" to "public.png", "gif" to "com.compuserve.gif",
        "heic" to "public.heic", "heif" to "public.heif", "webp" to "org.webmproject.webp", "bmp" to "com.microsoft.bmp",
        "tif" to "public.tiff", "tiff" to "public.tiff", "dng" to "com.adobe.raw-image",
        "mp4" to "public.mpeg-4", "m4v" to "com.apple.m4v-video", "mov" to "com.apple.quicktime-movie",
        "3gp" to "public.3gpp", "webm" to "org.webmproject.webm", "mkv" to "org.matroska.mkv",
        "mp3" to "public.mp3", "m4a" to "com.apple.m4a-audio", "wav" to "com.microsoft.waveform-audio",
        "aac" to "public.aac-audio", "ogg" to "org.xiph.ogg", "flac" to "org.xiph.flac",
        "pdf" to "com.adobe.pdf", "txt" to "public.plain-text", "md" to "net.daringfireball.markdown",
        "rtf" to "public.rtf", "html" to "public.html", "htm" to "public.html", "csv" to "public.comma-separated-values-text",
        "json" to "public.json", "xml" to "public.xml", "zip" to "public.zip-archive",
        "doc" to "com.microsoft.word.doc", "docx" to "org.openxmlformats.wordprocessingml.document",
        "xls" to "com.microsoft.excel.xls", "xlsx" to "org.openxmlformats.spreadsheetml.sheet",
        "ppt" to "com.microsoft.powerpoint.ppt", "pptx" to "org.openxmlformats.presentationml.presentation",
        "key" to "com.apple.keynote.key", "pages" to "com.apple.iwork.pages.sffpages", "numbers" to "com.apple.iwork.numbers.sffnumbers",
    )

    private val byMime = mapOf(
        "image/jpeg" to "public.jpeg", "image/png" to "public.png", "image/gif" to "com.compuserve.gif",
        "image/heic" to "public.heic", "image/heif" to "public.heif", "image/webp" to "org.webmproject.webp",
        "video/mp4" to "public.mpeg-4", "video/quicktime" to "com.apple.quicktime-movie", "video/3gpp" to "public.3gpp",
        "video/webm" to "org.webmproject.webm", "audio/mpeg" to "public.mp3", "audio/mp4" to "com.apple.m4a-audio",
        "application/pdf" to "com.adobe.pdf", "text/plain" to "public.plain-text", "text/html" to "public.html",
        "application/json" to "public.json", "application/zip" to "public.zip-archive",
        "image/*" to "public.image", "video/*" to "public.movie", "audio/*" to "public.audio", "text/*" to "public.text",
    )

    private val preferred: Map<String, String> = buildMap {
        byExtension.entries.reversed().forEach { (ext, uti) -> put(uti, ext) }
        put("public.jpeg", "jpeg")
    }

    override fun resolve(filename: String, mimeType: String?): String {
        val dot = filename.lastIndexOf('.')
        val ext = if (dot > 0) filename.substring(dot + 1).lowercase() else ""
        byExtension[ext]?.let { return it }
        val mime = mimeType?.lowercase()?.substringBefore(';')?.trim()
        if (mime != null) {
            byMime[mime]?.let { return it }
            byMime[mime.substringBefore('/') + "/*"]?.let { return it }
        }
        return FALLBACK
    }

    override fun preferredExtension(uti: String): String? = preferred[uti]
}
