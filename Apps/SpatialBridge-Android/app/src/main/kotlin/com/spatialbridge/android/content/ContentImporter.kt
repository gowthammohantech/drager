package com.spatialbridge.android.content

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.spatialbridge.android.diagnostics.BridgeLog
import com.spatialbridge.android.diagnostics.Redaction
import com.spatialbridge.core.OutgoingFile
import com.spatialbridge.core.transfer.FilenameSanitizer
import com.spatialbridge.core.transfer.UtiMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream
import java.util.UUID
import kotlin.coroutines.coroutineContext

/** A picked item staged in app cache, ready to send. `displayName` may be shown in UI, never logged. */
data class StagedItem(
    val id: String,
    val displayName: String,
    val file: OutgoingFile,
    val mimeType: String?,
) {
    val isImage: Boolean get() = mimeType?.startsWith("image/") == true || file.contentType in IMAGE_UTIS
    val isVideo: Boolean get() = mimeType?.startsWith("video/") == true

    private companion object {
        val IMAGE_UTIS = setOf("public.jpeg", "public.png", "public.heic", "public.heif", "com.compuserve.gif", "org.webmproject.webp")
    }
}

sealed interface ImportResult {
    data class Staged(val item: StagedItem) : ImportResult
    data object TooLarge : ImportResult
    data object Unreadable : ImportResult
}

interface ContentImporter {
    suspend fun import(uri: Uri): ImportResult
    fun clear()
}

/**
 * The name and type offered for a picked item: core's [UtiMap] (extension, then MIME, then
 * `public.data`) and [FilenameSanitizer]. The offered name is exactly the sanitizer's output, so the
 * extension is lowercase (`IMG.JPG` → `IMG.jpg`); receivers reject anything else with E006.
 */
object OfferNaming {
    data class Offer(val name: String, val contentType: String)

    fun offer(rawName: String?, mimeType: String?): Offer {
        val provisional = rawName ?: "Item"
        val uti = UtiMap.resolve(provisional, mimeType)
        return Offer(FilenameSanitizer.sanitize(provisional, uti), uti)
    }
}

/**
 * Copies picker/SAF content into `cacheDir/outgoing/<uuid>/` on [Dispatchers.IO]: the core reads a
 * stable local file, and the content URI grant can lapse without breaking a retry.
 */
class CacheContentImporter(
    private val context: Context,
    private val maxBytes: Long = MAX_FILE_BYTES,
) : ContentImporter {
    private val root: File get() = File(context.cacheDir, "outgoing")

    override suspend fun import(uri: Uri): ImportResult = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        var rawName: String? = null
        var declaredSize = -1L
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) rawName = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) declaredSize = c.getLong(s)
                }
            }
        }
        if (declaredSize > maxBytes) return@withContext ImportResult.TooLarge
        val mime = runCatching { resolver.getType(uri) }.getOrNull()
        val input = try {
            resolver.openInputStream(uri)
        } catch (e: java.io.IOException) {
            BridgeLog.warn("Import failed: ${e.javaClass.simpleName}")
            null
        } catch (e: SecurityException) {
            BridgeLog.warn("Import denied: ${e.javaClass.simpleName}")
            null
        } ?: return@withContext ImportResult.Unreadable
        importStream(input, rawName, mime)
    }

    /** Stages [input] (closed afterwards) under the sanitized form of [rawName]. Runs on [Dispatchers.IO]. */
    suspend fun importStream(input: InputStream, rawName: String?, mime: String?): ImportResult = withContext(Dispatchers.IO) {
        val offer = OfferNaming.offer(rawName, mime)
        val name = offer.name
        val uti = offer.contentType
        val dir = File(root, UUID.randomUUID().toString()).apply { mkdirs() }
        val target = File(dir, name)
        try {
            var copied = 0L
            input.use { source ->
                target.outputStream().use { sink ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = source.read(buffer)
                        if (read < 0) break
                        copied += read
                        if (copied > maxBytes) {
                            dir.deleteRecursively()
                            return@withContext ImportResult.TooLarge
                        }
                        sink.write(buffer, 0, read)
                    }
                }
            }
            BridgeLog.info("Staged ${Redaction.filename(name)} ($copied bytes)")
            ImportResult.Staged(StagedItem(dir.name, name, OutgoingFile(target.absolutePath, name, uti, copied), mime))
        } catch (e: java.io.IOException) {
            dir.deleteRecursively()
            BridgeLog.warn("Import failed: ${e.javaClass.simpleName}")
            ImportResult.Unreadable
        } catch (e: SecurityException) {
            dir.deleteRecursively()
            BridgeLog.warn("Import denied: ${e.javaClass.simpleName}")
            ImportResult.Unreadable
        }
    }

    override fun clear() {
        root.deleteRecursively()
    }

    companion object {
        /** TransferLimits.maxFileBytes: 100 MiB. */
        const val MAX_FILE_BYTES = 100L * 1024 * 1024
    }
}
