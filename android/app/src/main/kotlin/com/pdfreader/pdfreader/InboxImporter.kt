package com.pdfreader.pdfreader

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * Copies one untrusted file URI into the private inbox.
 *
 * Defences:
 *  - only content:// and file:// schemes;
 *  - refuses URIs that point back into this app (our own content providers or our
 *    private data dir), so another app cannot make us re-share our own files;
 *  - file:// only from shared storage paths, after canonicalisation;
 *  - size cap enforced both from metadata and while streaming;
 *  - the inbox file name is generated, never derived from the sender; the
 *    sender's display name is sanitised and returned separately.
 */
class InboxImporter(
    private val context: Context,
    inbox: File,
    private val maxBytes: Long,
) {
    private val inboxDir: File
    private val privateRoots: List<String>

    init {
        val dataDir = File(context.applicationInfo.dataDir).canonicalFile
        val canon = inbox.canonicalFile
        require(canon.path.startsWith(dataDir.path + File.separator)) { "inbox outside app storage" }
        canon.mkdirs()
        // Write under the path Dart gave us (it may go through a symlink such as
        // /data/user/0 -> /data/data), so returned paths match Dart's inbox prefix.
        inboxDir = inbox.absoluteFile
        privateRoots = listOfNotNull(
            dataDir.path,
            context.filesDir?.parentFile?.canonicalPath,
            context.getExternalFilesDir(null)?.parentFile?.canonicalPath,
            context.externalCacheDir?.parentFile?.canonicalPath,
        ).distinct()
    }

    fun import(uri: Uri): Map<String, Any?> {
        val source = uri.toString()
        var name: String? = null
        try {
            val scheme = uri.scheme?.lowercase()
            val fileSource: File? = when (scheme) {
                "content" -> {
                    if (isOwnProvider(uri)) return failure("rejected", null, source)
                    null
                }
                "file" -> allowedFile(uri) ?: return failure("rejected", null, source)
                else -> return failure("unsupported", null, source)
            }

            val meta = if (fileSource != null) {
                Meta(fileSource.name, fileSource.length())
            } else {
                queryMeta(uri)
            }
            name = FileNames.sanitize(meta.name ?: uri.lastPathSegment)
            val declared = meta.size
            if (declared != null && declared > maxBytes) return failure("tooLarge", name, source)
            if (declared != null && inboxDir.usableSpace < declared + FREE_SPACE_RESERVE) {
                return failure("noSpace", name, source)
            }

            val input: InputStream = (if (fileSource != null) FileInputStream(fileSource)
            else context.contentResolver.openInputStream(uri))
                ?: return failure("unreadable", name, source)

            val stamp = "${System.currentTimeMillis()}_${counter.incrementAndGet()}"
            val target = File(inboxDir, "in_$stamp.pdf")
            val part = File(inboxDir, "in_$stamp.part")
            val total: Long
            try {
                total = copyCapped(input, part)
            } catch (e: TooLargeException) {
                part.delete()
                return failure("tooLarge", name, source)
            } catch (e: IOException) {
                part.delete()
                val code = if (inboxDir.usableSpace < FREE_SPACE_RESERVE) "noSpace" else "unreadable"
                return failure(code, name, source)
            }
            if (total == 0L) {
                part.delete()
                return failure("unreadable", name, source)
            }
            if (!part.renameTo(target)) {
                part.delete()
                return failure("unreadable", name, source)
            }
            return mapOf(
                "path" to target.path,
                "displayName" to name,
                "sourceUri" to source,
                "size" to total,
            )
        } catch (e: SecurityException) {
            return failure("unreadable", name, source) // grant missing or revoked
        } catch (e: IOException) {
            return failure("unreadable", name, source)
        } catch (e: RuntimeException) {
            return failure("unreadable", name, source) // hostile provider
        }
    }

    private fun copyCapped(input: InputStream, part: File): Long {
        var total = 0L
        input.use { src ->
            FileOutputStream(part).use { out ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = src.read(buf)
                    if (n < 0) break
                    total += n
                    if (total > maxBytes) throw TooLargeException()
                    out.write(buf, 0, n)
                }
                out.fd.sync()
            }
        }
        return total
    }

    private fun isOwnProvider(uri: Uri): Boolean {
        // Strip an optional "userId@" prefix the platform accepts in authorities.
        val authority = uri.authority?.substringAfterLast('@')?.lowercase() ?: return true
        val pkg = context.packageName.lowercase()
        if (authority == pkg || authority.startsWith("$pkg.")) return true
        @Suppress("DEPRECATION")
        val info = try {
            context.packageManager.resolveContentProvider(authority, 0)
        } catch (e: RuntimeException) {
            null
        }
        return info?.packageName == context.packageName
    }

    private fun allowedFile(uri: Uri): File? {
        val path = uri.path ?: return null
        val file = try {
            File(path).canonicalFile
        } catch (e: IOException) {
            return null
        }
        val p = file.path
        if (privateRoots.any { p == it || p.startsWith(it + File.separator) }) return null
        if (SHARED_PREFIXES.none { p.startsWith(it) }) return null
        if (!file.isFile) return null
        return file
    }

    private fun queryMeta(uri: Uri): Meta {
        var name: String? = null
        var size: Long? = null
        try {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si).takeIf { it >= 0 }
                }
            }
        } catch (e: RuntimeException) {
            // Metadata is best effort; the streaming cap still applies.
        }
        return Meta(name, size)
    }

    private data class Meta(val name: String?, val size: Long?)

    private class TooLargeException : IOException()

    private fun failure(code: String, name: String?, source: String?): Map<String, Any?> =
        mapOf("error" to code, "displayName" to name, "sourceUri" to source)

    private companion object {
        val counter = AtomicLong()
        const val FREE_SPACE_RESERVE = 16L * 1024 * 1024
        val SHARED_PREFIXES = listOf("/storage/", "/sdcard/", "/mnt/")
    }
}

/** Display-name sanitising, mirrored in Dart (lib/platform/file_names.dart). */
object FileNames {
    private const val MAX_LEN = 120
    private const val FALLBACK = "document.pdf"

    fun sanitize(raw: String?): String {
        var n = (raw ?: "").substringAfterLast('/').substringAfterLast('\\')
        n = n.filter { ch ->
            ch >= ' ' && ch != '\u007f' &&
                ch !in '‪'..'‮' && ch !in '⁦'..'⁩' &&
                ch != '‎' && ch != '‏' && ch != ':' && ch != '*' && ch != '?' &&
                ch != '"' && ch != '<' && ch != '>' && ch != '|'
        }
        n = n.trim().trimStart('.').trim()
        if (n.isEmpty()) return FALLBACK
        if (n.length > MAX_LEN) {
            val dot = n.lastIndexOf('.')
            val ext = if (dot > 0 && n.length - dot <= 10) n.substring(dot) else ""
            n = n.substring(0, MAX_LEN - ext.length).trimEnd() + ext
        }
        return n
    }
}
