package com.spatialbridge.android.model

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.TransferState

/** User-facing transfer phases, mirroring the iOS `TransferPhase`. */
enum class TransferPhase(val title: String) {
    IDLE(""),
    PREPARING("Preparing"),
    CONNECTING("Connecting"),
    OFFERING("Offering"),
    SENDING("Sending"),
    AWAITING_COMMIT("Saving"),
    COMPLETED("Saved"),
    FAILED("Failed"),
    CANCELLED("Cancelled"),
    ;

    val isActive: Boolean get() = this in setOf(PREPARING, CONNECTING, OFFERING, SENDING, AWAITING_COMMIT)
    val showsProgress: Boolean get() = this == SENDING || this == AWAITING_COMMIT
}

/** Everything the transfer status card renders. */
data class TransferUi(
    val phase: TransferPhase,
    val title: String,
    val subtitle: String,
    val sentBytes: Long = 0,
    val totalBytes: Long = 0,
    val error: BridgeErrorCode? = null,
    val savedFilename: String? = null,
) {
    /** Success is shown only for this flag, which only [TransferState.Committed] sets (AGENTS.md). */
    val isSuccess: Boolean get() = phase == TransferPhase.COMPLETED
    val fraction: Float get() = if (totalBytes > 0) (sentBytes.toDouble() / totalBytes).coerceIn(0.0, 1.0).toFloat() else 0f
    val errorMessage: String? get() = error?.let(ErrorCopy::message)
    val recovery: String? get() = error?.let(ErrorCopy::recovery)

    companion object {
        val IDLE = TransferUi(TransferPhase.IDLE, "", "")
    }
}

/**
 * Maps core [TransferState] to [TransferUi]. Pure so the "success only on COMMITTED" rule is unit-tested:
 * [TransferPhase.COMPLETED] is produced by exactly one branch, [TransferState.Committed].
 */
object TransferUiMapper {
    fun map(state: TransferState, filename: String, peerName: String?, preparing: Boolean = false): TransferUi {
        val computer = peerName ?: "your computer"
        if (preparing && state is TransferState.Idle) {
            return TransferUi(TransferPhase.PREPARING, "Preparing", filename)
        }
        return when (state) {
            TransferState.Idle -> TransferUi.IDLE
            TransferState.Connecting ->
                TransferUi(TransferPhase.CONNECTING, "Connecting", "Waiting for $computer…")
            TransferState.Offering ->
                TransferUi(TransferPhase.OFFERING, "Offering", "Asking $computer to accept $filename")
            is TransferState.Sending ->
                TransferUi(TransferPhase.SENDING, "Sending", filename, state.sentBytes, state.totalBytes)
            TransferState.AwaitingCommit ->
                // Every byte is out, but nothing is saved until the receiver says COMMITTED.
                TransferUi(TransferPhase.AWAITING_COMMIT, "Saving on $computer", "Checking integrity and saving $filename", 1, 1)
            is TransferState.Committed ->
                TransferUi(
                    TransferPhase.COMPLETED, "Saved on $computer",
                    "${state.savedFilename} is on $computer",
                    state.byteCount, state.byteCount, savedFilename = state.savedFilename,
                )
            is TransferState.Failed ->
                if (state.code == BridgeErrorCode.TRANSFER_CANCELED) {
                    TransferUi(TransferPhase.CANCELLED, "Cancelled", filename, error = state.code)
                } else {
                    TransferUi(TransferPhase.FAILED, "Failed", filename, error = state.code)
                }
        }
    }
}
