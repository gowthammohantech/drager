package com.spatialbridge.android

import com.spatialbridge.android.model.ErrorCopy
import com.spatialbridge.android.model.TransferPhase
import com.spatialbridge.android.model.TransferUiMapper
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.TransferState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferUiMapperTest {
    private fun map(state: TransferState) = TransferUiMapper.map(state, "photo.jpg", "Studio Mac")

    @Test fun successOnlyOnCommitted() {
        val nonCommitted = listOf(
            TransferState.Idle, TransferState.Connecting, TransferState.Offering,
            TransferState.Sending(10, 10), TransferState.Sending(10, 0), TransferState.AwaitingCommit,
        ) + BridgeErrorCode.entries.map { TransferState.Failed(it) }
        nonCommitted.forEach { state ->
            val ui = map(state)
            assertFalse("$state must not show success", ui.isSuccess)
            assertTrue(ui.phase != TransferPhase.COMPLETED)
        }
        val committed = map(TransferState.Committed("photo 2.jpg", 42))
        assertTrue(committed.isSuccess)
        assertEquals("photo 2.jpg", committed.savedFilename)
        assertEquals("Saved on Studio Mac", committed.title)
    }

    @Test fun allBytesSentIsStillNotSuccess() {
        val ui = map(TransferState.Sending(100, 100))
        assertEquals(1f, ui.fraction)
        assertFalse(ui.isSuccess)
        assertEquals(TransferPhase.AWAITING_COMMIT, map(TransferState.AwaitingCommit).phase)
        assertTrue(map(TransferState.AwaitingCommit).phase.isActive)
    }

    @Test fun phasesAndProgress() {
        assertEquals(TransferPhase.IDLE, map(TransferState.Idle).phase)
        assertEquals(TransferPhase.CONNECTING, map(TransferState.Connecting).phase)
        assertEquals(TransferPhase.OFFERING, map(TransferState.Offering).phase)
        val sending = map(TransferState.Sending(25, 100))
        assertEquals(TransferPhase.SENDING, sending.phase)
        assertEquals(0.25f, sending.fraction)
        assertEquals(TransferPhase.PREPARING, TransferUiMapper.map(TransferState.Idle, "a", null, preparing = true).phase)
        assertTrue(map(TransferState.Connecting).subtitle.contains("Studio Mac"))
        assertTrue(TransferUiMapper.map(TransferState.Connecting, "a", null).subtitle.contains("your computer"))
    }

    @Test fun failuresMapToFriendlyMessages() {
        BridgeErrorCode.entries.forEach { code ->
            val ui = map(TransferState.Failed(code))
            assertEquals(code, ui.error)
            assertEquals(ErrorCopy.message(code), ui.errorMessage)
            assertTrue(ui.recovery!!.isNotBlank())
            assertFalse(ui.phase.isActive)
            val expected = if (code == BridgeErrorCode.TRANSFER_CANCELED) TransferPhase.CANCELLED else TransferPhase.FAILED
            assertEquals(expected, ui.phase)
        }
        assertEquals("This file type isn't supported.", map(TransferState.Failed(BridgeErrorCode.UNSUPPORTED_FILE)).errorMessage)
    }

    @Test fun errorCopyIsDistinctPerCode() {
        assertEquals(BridgeErrorCode.entries.size, BridgeErrorCode.entries.map(ErrorCopy::message).toSet().size)
        assertTrue(ErrorCopy.isRetryable(BridgeErrorCode.PEER_LOST))
        assertFalse(ErrorCopy.isRetryable(BridgeErrorCode.UNSUPPORTED_FILE))
    }
}
