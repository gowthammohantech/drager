package com.spatialbridge.core.model

import com.spatialbridge.core.BridgeErrorCode
import kotlinx.coroutines.TimeoutCancellationException
import java.util.concurrent.CancellationException

/** A protocol failure with its wire code. [detail] is developer-facing and never holds secrets or filenames. */
class BridgeException(val code: BridgeErrorCode, val detail: String? = null, cause: Throwable? = null) :
    Exception(detail?.let { "${code.wire}: $it" } ?: code.wire, cause) {

    companion object {
        /** Maps any throwable to a [BridgeException], like `BridgeError.wrap`. */
        fun wrap(error: Throwable, networkContext: Boolean): BridgeException = when (error) {
            is BridgeException -> error
            is TimeoutCancellationException -> BridgeException(BridgeErrorCode.TIMEOUT, cause = error)
            is CancellationException -> BridgeException(BridgeErrorCode.TRANSFER_CANCELED, cause = error)
            else -> BridgeException(
                if (networkContext) BridgeErrorCode.PEER_LOST else BridgeErrorCode.WRITE_FAILED,
                error.javaClass.simpleName,
                error,
            )
        }
    }
}

/** The code for a wire string like `"E004"`, or null for codes this build does not know. */
fun bridgeErrorCodeOf(wire: String): BridgeErrorCode? = BridgeErrorCode.entries.firstOrNull { it.wire == wire }

/** Numeric part of the code, used as the CLI exit code (E004 → 4). */
val BridgeErrorCode.exitCode: Int get() = wire.drop(1).toInt()

val BridgeErrorCode.isRetryable: Boolean
    get() = when (this) {
        BridgeErrorCode.PEER_LOST, BridgeErrorCode.TIMEOUT, BridgeErrorCode.HASH_MISMATCH,
        BridgeErrorCode.WRITE_FAILED, BridgeErrorCode.NO_PEER -> true
        else -> false
    }
