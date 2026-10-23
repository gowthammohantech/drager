package com.spatialbridge.core.vectors

import com.spatialbridge.core.transfer.FilenameSanitizer
import com.spatialbridge.core.transfer.UtiMap
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.TestFactory

class TransferVectorTest {
    @TestFactory
    fun sanitizer() = Vectors.tests("sanitizer") { c ->
        when (c.str("op")) {
            "sanitize" -> {
                val sanitized = FilenameSanitizer.sanitize(c.str("input"), c.strOrNull("contentType"))
                assertEquals(c.str("sanitized"), sanitized)
                c.strOrNull("sanitizedUtf8Length")?.let { assertEquals(it.toInt(), sanitized.toByteArray().size) }
                assertEquals(c.bool("isSafe"), FilenameSanitizer.isSafe(c.str("input")), "isSafe(input)")
                assertEquals(c.bool("sanitizedIsSafe"), FilenameSanitizer.isSafe(sanitized), "isSafe(sanitized)")
            }
            "candidate" -> assertEquals(c.str("candidate"), FilenameSanitizer.candidate(c.str("input"), c.str("attempt").toInt()))
            else -> error("unknown op")
        }
    }

    @TestFactory
    fun `uti-policy`() = Vectors.tests("uti-policy") { c ->
        assertEquals(c.bool("allowedOnMac"), UtiMap.allowedOnMac(c.str("filename"), c.str("contentType")))
    }
}
