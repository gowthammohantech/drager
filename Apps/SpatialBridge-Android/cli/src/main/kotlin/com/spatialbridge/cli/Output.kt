package com.spatialbridge.cli

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.json.CanonicalJson

/** JSON-lines events on stdout (CONFORMANCE.md §5). Never pass filenames, contents, PSKs or seeds. */
object Out {
    private val lock = Any()

    fun event(name: String, fields: Map<String, Any?> = emptyMap()) {
        val line = CanonicalJson.encodeToString(fields + ("event" to name))
        synchronized(lock) {
            System.out.println(line)
            System.out.flush()
        }
    }

    fun error(code: BridgeErrorCode, extra: Map<String, Any?> = emptyMap()) = event("error", extra + ("code" to code.wire))

    /** Diagnostics on stderr. Callers pass redacted text only. */
    fun log(message: String) {
        System.err.println("sb-jvm: $message")
    }
}

class UsageError(message: String) : Exception(message)

class Args(argv: List<String>) {
    val command: String? = argv.firstOrNull()
    private val values = mutableMapOf<String, String>()
    private val flags = mutableSetOf<String>()

    init {
        var i = 1
        while (i < argv.size) {
            val arg = argv[i]
            if (!arg.startsWith("--")) throw UsageError("unexpected argument")
            val name = arg.removePrefix("--")
            if (i + 1 < argv.size && !argv[i + 1].startsWith("--")) {
                values[name] = argv[i + 1]
                i += 2
            } else {
                flags += name
                i += 1
            }
        }
    }

    fun optional(name: String): String? = values[name]
    fun required(name: String): String = values[name] ?: throw UsageError("missing --$name")
    fun flag(name: String): Boolean = name in flags

    fun hostPort(name: String): Pair<String, Int> {
        val raw = required(name)
        val colon = raw.lastIndexOf(':')
        if (colon <= 0) throw UsageError("--$name must be HOST:PORT")
        val port = raw.substring(colon + 1).toIntOrNull()?.takeIf { it in 0..65535 } ?: throw UsageError("bad port")
        return raw.substring(0, colon).removePrefix("[").removeSuffix("]") to port
    }
}
