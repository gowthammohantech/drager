package com.spatialbridge.android

import android.net.Uri
import com.spatialbridge.android.content.ContentImporter
import com.spatialbridge.android.content.ImportResult
import com.spatialbridge.android.content.StagedItem
import com.spatialbridge.android.gesture.PlaceholderGestureEngine
import com.spatialbridge.android.model.PhonePlacement
import com.spatialbridge.android.model.SpatialLayout
import com.spatialbridge.android.model.TransferPhase
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.InMemoryHistoryStore
import com.spatialbridge.android.settings.InMemorySettingsStore
import com.spatialbridge.android.settings.TransferOutcome
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DiscoveredPeer
import com.spatialbridge.core.Edge
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.OutgoingFile
import com.spatialbridge.core.PairingState
import com.spatialbridge.core.SenderFacade
import com.spatialbridge.core.TransferState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A facade the test drives by hand, to check the state-to-UI rules end to end through [AppModel]. */
private class ManualFacade : SenderFacade {
    val peerID = "0123456789abcdef0123456789abcdef"
    override val peers = MutableStateFlow(listOf(DiscoveredPeer(peerID, "Studio Mac", null, isTrusted = true, pairingAvailable = false)))
    override val pairing = MutableStateFlow<PairingState>(PairingState.Idle)
    override val transfer = MutableStateFlow<TransferState>(TransferState.Idle)
    var sends = 0
    var lastGesture: ExitGesture? = null
    override fun startDiscovery() = Unit
    override fun stopDiscovery() = Unit
    override suspend fun pair(peerID: String) = Unit
    override fun answerPairing(codesMatch: Boolean) = Unit
    override suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String?) { sends++; lastGesture = gesture }
    override fun cancelTransfer() { transfer.value = TransferState.Failed(BridgeErrorCode.TRANSFER_CANCELED) }
    override suspend fun unpair(peerID: String) = Unit
    override fun setPreferredPeer(peerID: String?) = Unit
}

private object NoImporter : ContentImporter {
    override suspend fun import(uri: Uri) = ImportResult.Unreadable
    override fun clear() = Unit
}

@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTest {
    private val item = StagedItem("1", "photo.jpg", OutgoingFile("/tmp/photo.jpg", "photo.jpg", "public.jpeg", 100), "image/jpeg")

    private fun setup(scope: kotlinx.coroutines.CoroutineScope, settings: AppSettings = AppSettings()): Triple<AppModel, ManualFacade, InMemoryHistoryStore> {
        val facade = ManualFacade()
        val history = InMemoryHistoryStore()
        val model = AppModel(facade, InMemorySettingsStore(settings), history, NoImporter, PlaceholderGestureEngine.factory, scope)
        model.stage(item)
        return Triple(model, facade, history)
    }

    @Test fun successOnlyAfterCommitted() = runTest(UnconfinedTestDispatcher()) {
        val (model, facade, history) = setup(backgroundScope)
        model.send(null)
        assertEquals(TransferPhase.PREPARING, model.transferUi.value.phase)
        facade.transfer.value = TransferState.Connecting
        facade.transfer.value = TransferState.Sending(100, 100)
        facade.transfer.value = TransferState.AwaitingCommit
        assertFalse(model.transferUi.value.isSuccess)
        assertTrue(history.records.value.isEmpty())
        facade.transfer.value = TransferState.Committed("photo.jpg", 100)
        assertTrue(model.transferUi.value.isSuccess)
        assertEquals(TransferOutcome.COMPLETED, history.records.value.single().outcome)
    }

    @Test fun staleCommittedFromPreviousTransferIsNotShownAsSuccess() = runTest(UnconfinedTestDispatcher()) {
        val (model, facade, _) = setup(backgroundScope)
        facade.transfer.value = TransferState.Committed("old.jpg", 1)
        model.send(null)
        // The facade has not moved yet: the old COMMITTED belongs to another transfer.
        assertFalse(model.transferUi.value.isSuccess)
        assertEquals(TransferPhase.PREPARING, model.transferUi.value.phase)
    }

    @Test fun oneActivationOneTransfer() = runTest(UnconfinedTestDispatcher()) {
        val (model, facade, _) = setup(backgroundScope)
        model.send(null)
        facade.transfer.value = TransferState.Sending(1, 100)
        model.send(null)
        model.send(null)
        assertEquals(1, facade.sends)
    }

    @Test fun failureIsRecordedWithCode() = runTest(UnconfinedTestDispatcher()) {
        val (model, facade, history) = setup(backgroundScope)
        model.send(null)
        facade.transfer.value = TransferState.Offering
        facade.transfer.value = TransferState.Failed(BridgeErrorCode.UNSUPPORTED_FILE)
        assertEquals(TransferPhase.FAILED, model.transferUi.value.phase)
        assertEquals(BridgeErrorCode.UNSUPPORTED_FILE, history.records.value.single().errorCode)
        model.dismissTransfer()
        assertEquals(TransferPhase.IDLE, model.transferUi.value.phase)
    }

    @Test fun calibrationIsAppliedToGesture() = runTest(UnconfinedTestDispatcher()) {
        val (model, facade, _) = setup(backgroundScope, AppSettings(layout = SpatialLayout(PhonePlacement.BELOW, alignmentOffset = 0.1, mirrored = true)))
        model.send(ExitGesture(Edge.TOP, 0.2, 900.0, 120.0, 0))
        assertEquals(0.9, facade.lastGesture!!.normalizedPosition, 1e-9)
    }

    @Test fun historyOffKeepsNothing() = runTest(UnconfinedTestDispatcher()) {
        val (model, facade, history) = setup(backgroundScope, AppSettings(keepHistory = false))
        model.send(null)
        facade.transfer.value = TransferState.Committed("photo.jpg", 100)
        assertTrue(history.records.value.isEmpty())
        assertNull(model.importError.value)
    }
}
