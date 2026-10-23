package com.spatialbridge.core.transfer

import java.util.Locale

/**
 * Content types on the wire are Apple UTIs (ADR-015). Android maps the file extension first, then
 * the MIME type, and falls back to `public.data`; it never sends `dyn.*`. The table also carries
 * enough of the conformance tree to mirror the Mac's offer policy (`uti-policy` vectors).
 */
object UtiMap {
    const val DATA = "public.data"

    private class Entry(val uti: String, val parent: String?, val extensions: List<String>, val mimes: List<String>)

    private val table = listOf(
        Entry("public.item", null, emptyList(), emptyList()),
        Entry("public.content", "public.item", emptyList(), emptyList()),
        Entry("public.data", "public.item", emptyList(), listOf("application/octet-stream")),
        Entry("public.image", "public.data", emptyList(), emptyList()),
        Entry("public.jpeg", "public.image", listOf("jpeg", "jpg", "jpe"), listOf("image/jpeg", "image/jpg", "image/pjpeg")),
        Entry("public.png", "public.image", listOf("png"), listOf("image/png")),
        Entry("public.heic", "public.image", listOf("heic"), listOf("image/heic")),
        Entry("public.heif", "public.image", listOf("heif", "heifs"), listOf("image/heif")),
        Entry("com.compuserve.gif", "public.image", listOf("gif"), listOf("image/gif")),
        Entry("org.webmproject.webp", "public.image", listOf("webp"), listOf("image/webp")),
        Entry("public.tiff", "public.image", listOf("tiff", "tif"), listOf("image/tiff")),
        Entry("com.microsoft.bmp", "public.image", listOf("bmp"), listOf("image/bmp", "image/x-ms-bmp")),
        Entry("public.avif", "public.image", listOf("avif"), listOf("image/avif")),
        Entry("public.svg-image", "public.image", listOf("svg"), listOf("image/svg+xml")),
        Entry("public.camera-raw-image", "public.image", listOf("dng"), listOf("image/x-adobe-dng")),
        Entry("public.audiovisual-content", "public.data", emptyList(), emptyList()),
        Entry("public.movie", "public.audiovisual-content", emptyList(), emptyList()),
        Entry("public.mpeg-4", "public.movie", listOf("mp4", "mp4v", "mpeg4"), listOf("video/mp4")),
        Entry("com.apple.quicktime-movie", "public.movie", listOf("mov", "qt"), listOf("video/quicktime")),
        Entry("com.apple.m4v-video", "public.movie", listOf("m4v"), listOf("video/x-m4v")),
        Entry("public.3gpp", "public.movie", listOf("3gp", "3gpp"), listOf("video/3gpp")),
        Entry("org.webmproject.webm", "public.movie", listOf("webm"), listOf("video/webm")),
        Entry("public.avi", "public.movie", listOf("avi"), listOf("video/avi", "video/x-msvideo")),
        Entry("public.mpeg", "public.movie", listOf("mpg", "mpeg"), listOf("video/mpeg")),
        Entry("org.matroska.mkv", "public.movie", listOf("mkv"), listOf("video/x-matroska")),
        Entry("public.audio", "public.audiovisual-content", emptyList(), emptyList()),
        Entry("public.mp3", "public.audio", listOf("mp3"), listOf("audio/mpeg", "audio/mp3")),
        Entry("com.apple.m4a-audio", "public.audio", listOf("m4a"), listOf("audio/mp4", "audio/x-m4a")),
        Entry("public.aac-audio", "public.audio", listOf("aac"), listOf("audio/aac")),
        Entry("com.microsoft.waveform-audio", "public.audio", listOf("wav", "wave"), listOf("audio/wav", "audio/x-wav", "audio/vnd.wave")),
        Entry("public.aiff-audio", "public.audio", listOf("aiff", "aif"), listOf("audio/aiff", "audio/x-aiff")),
        Entry("org.xiph.flac", "public.audio", listOf("flac"), listOf("audio/flac")),
        Entry("org.xiph.ogg-audio", "public.audio", listOf("ogg", "oga"), listOf("audio/ogg")),
        Entry("public.text", "public.data", emptyList(), emptyList()),
        Entry("public.plain-text", "public.text", listOf("txt", "text"), listOf("text/plain")),
        Entry("public.utf8-plain-text", "public.plain-text", emptyList(), emptyList()),
        Entry("net.daringfireball.markdown", "public.plain-text", listOf("md", "markdown"), listOf("text/markdown")),
        Entry("public.comma-separated-values-text", "public.text", listOf("csv"), listOf("text/csv")),
        Entry("public.json", "public.text", listOf("json"), listOf("application/json")),
        Entry("public.html", "public.text", listOf("html", "htm"), listOf("text/html")),
        Entry("public.xml", "public.text", listOf("xml"), listOf("application/xml", "text/xml")),
        Entry("public.rtf", "public.text", listOf("rtf"), listOf("text/rtf", "application/rtf")),
        Entry("public.vcard", "public.text", listOf("vcf"), listOf("text/vcard", "text/x-vcard")),
        Entry("public.calendar-event", "public.text", listOf("ics"), listOf("text/calendar")),
        Entry("public.source-code", "public.plain-text", emptyList(), emptyList()),
        Entry("public.script", "public.source-code", emptyList(), emptyList()),
        Entry("com.netscape.javascript-source", "public.script", listOf("js", "mjs"), listOf("text/javascript", "application/javascript")),
        Entry("public.shell-script", "public.script", listOf("sh"), listOf("application/x-sh", "text/x-sh")),
        Entry("public.bash-script", "public.shell-script", listOf("bash"), emptyList()),
        Entry("public.zsh-script", "public.shell-script", listOf("zsh"), emptyList()),
        Entry("public.csh-script", "public.shell-script", listOf("csh"), emptyList()),
        Entry("public.ksh-script", "public.shell-script", listOf("ksh"), emptyList()),
        Entry("public.tcsh-script", "public.shell-script", listOf("tcsh"), emptyList()),
        Entry("com.apple.terminal.shell-script", "public.shell-script", listOf("command", "tool"), emptyList()),
        Entry("public.python-script", "public.shell-script", listOf("py"), listOf("text/x-python", "text/x-python-script")),
        Entry("public.ruby-script", "public.shell-script", listOf("rb", "rbw"), listOf("text/x-ruby-script")),
        Entry("public.perl-script", "public.shell-script", listOf("pl", "pm"), listOf("text/x-perl-script")),
        Entry("public.php-script", "public.shell-script", listOf("php"), listOf("application/x-php")),
        Entry("com.apple.applescript.text", "public.script", listOf("applescript"), emptyList()),
        Entry("com.apple.applescript.script", "public.data", listOf("scpt"), emptyList()),
        Entry("com.apple.applescript.script-bundle", "com.apple.applescript.script", listOf("scptd"), emptyList()),
        Entry("com.adobe.pdf", "public.data", listOf("pdf"), listOf("application/pdf")),
        Entry("public.archive", "public.data", emptyList(), emptyList()),
        Entry("public.zip-archive", "public.archive", listOf("zip"), listOf("application/zip", "application/x-zip-compressed")),
        Entry("org.gnu.gnu-zip-archive", "public.archive", listOf("gz", "gzip"), listOf("application/gzip", "application/x-gzip")),
        Entry("public.tar-archive", "public.archive", listOf("tar"), listOf("application/x-tar")),
        Entry("org.7-zip.7-zip-archive", "public.archive", listOf("7z"), listOf("application/x-7z-compressed")),
        Entry("com.rarlab.rar-archive", "public.archive", listOf("rar"), listOf("application/vnd.rar", "application/x-rar-compressed")),
        Entry("com.apple.disk-image-udif", "public.data", listOf("dmg"), listOf("application/x-apple-diskimage")),
        Entry("com.microsoft.word.doc", "public.data", listOf("doc"), listOf("application/msword")),
        Entry("org.openxmlformats.wordprocessingml.document", "public.data", listOf("docx"), listOf("application/vnd.openxmlformats-officedocument.wordprocessingml.document")),
        Entry("com.microsoft.excel.xls", "public.data", listOf("xls"), listOf("application/vnd.ms-excel")),
        Entry("org.openxmlformats.spreadsheetml.sheet", "public.data", listOf("xlsx"), listOf("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")),
        Entry("com.microsoft.powerpoint.ppt", "public.data", listOf("ppt"), listOf("application/vnd.ms-powerpoint")),
        Entry("org.openxmlformats.presentationml.presentation", "public.data", listOf("pptx"), listOf("application/vnd.openxmlformats-officedocument.presentationml.presentation")),
        Entry("org.oasis-open.opendocument.text", "public.data", listOf("odt"), listOf("application/vnd.oasis.opendocument.text")),
        Entry("org.idpf.epub-container", "public.data", listOf("epub"), listOf("application/epub+zip")),
        Entry("com.apple.keynote.key", "public.data", listOf("key"), emptyList()),
        Entry("com.apple.iwork.pages.sffpages", "public.data", listOf("pages"), emptyList()),
        Entry("com.apple.iwork.numbers.sffnumbers", "public.data", listOf("numbers"), emptyList()),
        Entry("public.executable", "public.data", emptyList(), emptyList()),
        Entry("public.unix-executable", "public.executable", emptyList(), emptyList()),
        Entry("com.microsoft.windows-executable", "public.executable", listOf("exe"), listOf("application/x-msdownload", "application/vnd.microsoft.portable-executable")),
        Entry("com.microsoft.windows-dynamic-link-library", "public.executable", listOf("dll"), emptyList()),
        Entry("com.android.package-archive", "public.zip-archive", listOf("apk"), listOf("application/vnd.android.package-archive")),
        Entry("com.sun.java-archive", "public.zip-archive", listOf("jar"), listOf("application/java-archive")),
        Entry("com.apple.application", "public.data", emptyList(), emptyList()),
        Entry("com.apple.bundle", "public.data", emptyList(), emptyList()),
        Entry("com.apple.application-bundle", "com.apple.application", listOf("app"), emptyList()),
        Entry("com.apple.installer-package-archive", "public.data", listOf("pkg"), emptyList()),
    )

    private val byUti = table.associateBy { it.uti }
    private val byExtension = HashMap<String, String>().apply {
        for (entry in table) for (ext in entry.extensions) putIfAbsent(ext, entry.uti)
    }
    private val byMime = HashMap<String, String>().apply {
        for (entry in table) for (mime in entry.mimes) putIfAbsent(mime, entry.uti)
    }

    /** The Mac's never-accepted types (`TransferPolicy.defaultDeniedTypes`). */
    val deniedTypes = listOf(
        "com.apple.application", "public.unix-executable", "public.shell-script",
        "com.apple.applescript.text", "com.apple.applescript.script",
    )

    /** UTI for an outgoing file: extension first, then MIME type, then `public.data`. */
    fun utiFor(filename: String?, mimeType: String?): String {
        filename?.let(::extensionOf)?.let { byExtension[it.lowercase(Locale.ROOT)] }?.let { return it }
        mimeType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)?.let { byMime[it] }?.let { return it }
        return DATA
    }

    /** Same as [utiFor]; the name the app uses. */
    fun resolve(filename: String?, mimeType: String?): String = utiFor(filename, mimeType)

    fun utiForExtension(ext: String): String? = byExtension[ext.lowercase(Locale.ROOT)]

    /** `UTType(identifier).preferredFilenameExtension`, including the extension tag of `dyn.*` types. */
    fun preferredExtension(uti: String): String? {
        if (uti.startsWith("dyn.")) return decodeDynamic(uti)?.get("1")
        return byUti[uti]?.extensions?.firstOrNull()
    }

    /** True for identifiers the Mac's `UTType(_:)` would recognise in this table, including `dyn.*`. */
    fun isKnown(uti: String): Boolean = uti in byUti || (uti.startsWith("dyn.") && decodeDynamic(uti) != null)

    fun conforms(uti: String, to: String): Boolean {
        if (uti == to) return true
        if (uti.startsWith("dyn.")) {
            val ext = decodeDynamic(uti)?.get("1") ?: return to == DATA || to == "public.item"
            return byExtension[ext]?.let { conforms(it, to) } ?: (to == DATA || to == "public.item")
        }
        var current = byUti[uti]?.parent
        while (current != null) {
            if (current == to) return true
            current = byUti[current]?.parent
        }
        return false
    }

    fun isDenied(uti: String): Boolean = deniedTypes.any { conforms(uti, it) }

    /** The Mac's policy for an offer's name and type (UTI denials plus extension denials, ADR-015). */
    fun allowedOnMac(filename: String, contentType: String): Boolean {
        if (!FilenameSanitizer.isSafe(filename)) return false
        if (!isKnown(contentType) || isDenied(contentType)) return false
        val ext = FilenameSanitizer.pathExtension(filename)
        if (ext.isNotEmpty()) {
            val byExt = byExtension[ext.lowercase(Locale.ROOT)]
            if (byExt != null && isDenied(byExt)) return false
        }
        return true
    }

    /**
     * The receiver rule for UTIs this table doesn't know (ADR-015, as on Windows): they are plain data.
     * Known denied types and denied extensions are still refused.
     */
    fun allowedOnReceiver(filename: String, contentType: String): Boolean {
        if (!FilenameSanitizer.isSafe(filename) || contentType.isEmpty()) return false
        if (isKnown(contentType) && isDenied(contentType)) return false
        val ext = FilenameSanitizer.pathExtension(filename)
        return ext.isEmpty() || byExtension[ext.lowercase(Locale.ROOT)]?.let(::isDenied) != true
    }

    private fun extensionOf(filename: String): String? = FilenameSanitizer.pathExtension(filename).takeIf { it.isNotEmpty() }

    private const val DYN_ALPHABET = "abcdefghkmnpqrstuvwxyz0123456789"

    /** Decodes `dyn.a…` into its `?k=v:k=v` tag map. */
    private fun decodeDynamic(uti: String): Map<String, String>? {
        val body = uti.removePrefix("dyn.")
        if (!body.startsWith("a")) return null
        var bits = 0
        var bitCount = 0
        val out = StringBuilder()
        for (ch in body.drop(1)) {
            val value = DYN_ALPHABET.indexOf(ch).takeIf { it >= 0 } ?: return null
            bits = (bits shl 5) or value
            bitCount += 5
            if (bitCount >= 8) {
                bitCount -= 8
                out.append(((bits shr bitCount) and 0xFF).toChar())
            }
        }
        val text = out.toString()
        if (!text.startsWith("?")) return null
        return text.drop(1).split(':').mapNotNull { part ->
            val eq = part.indexOf('=')
            if (eq <= 0) null else part.substring(0, eq) to part.substring(eq + 1)
        }.toMap()
    }
}
