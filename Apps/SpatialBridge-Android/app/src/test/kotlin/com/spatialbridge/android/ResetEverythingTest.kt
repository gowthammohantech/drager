package com.spatialbridge.android

import android.net.Uri
import com.spatialbridge.android.content.ContentImporter
import com.spatialbridge.android.content.ImportResult
import com.spatialbridge.android.content.StagedItem
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.InMemoryHistoryStore
import com.spatialbridge.android.settings.InMemorySettingsStore
import com.spatialbridge.android.settings.TransferOutcome
import com.spatialbridge.android.settings.TransferRecord
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.DiscoveredPeer
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.OutgoingFile
import com.spatialbridge.core.PairingState
import com.spatialbridge.core.SenderFacade
import com.spatialbridge.core.TransferState
import com.spatialbridge.core.TrustedPeerInfo
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** One visible trusted peer and one stored-only (offline) trusted peer. */
private class ResetFacade : SenderFacade {
    val online = "0123456789abcdef0123456789abcdef"
    val offline = "fedcba9876543210fedcba9876543210"
    override val peers = MutableStateFlow(listOf(DiscoveredPeer(online, "Studio Mac", null, isTrusted = true, pairingAvailable = false)))
    override val trustedPeers = MutableStateFlow(
        listOf(TrustedPeerInfo(online, "Studio Mac", DevicePlatform.MACOS), TrustedPeerInfo(offline, "Desk PC", DevicePlatform.WINDOWS)),
    )
    override val pairing = MutableStateFlow<PairingState>(PairingState.Idle)
    override val transfer = MutableStateFlow<TransferState>(TransferState.Idle)
    val unpaired = mutableListOf<String>()
    var discovering = false
    override fun startDiscovery() { discovering = true }
    override fun stopDiscovery() { discovering = false }
    override suspend fun pair(peerID: String) = Unit
    override fun answerPairing(codesMatch: Boolean) = Unit
    override suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String?) = Unit
    override fun cancelTransfer() = Unit
    override suspend fun unpair(peerID: String) {
        unpaired += peerID
        trustedPeers.value = trustedPeers.value.filter { it.peerID != peerID }
        peers.value = peers.value.filter { it.peerID != peerID }
    }
    override fun setPreferredPeer(peerID: String?) = Unit
}

private class CountingImporter : ContentImporter {
    var cleared = 0
    override suspend fun import(uri: Uri) = ImportResult.Unreadable
    override fun clear() { cleared++ }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ResetEverythingTest {
    @Test fun resetClearsAppStateUnpairsStoredPeersAndRunsPlatformReset() = runTest(UnconfinedTestDispatcher()) {
        val facade = ResetFacade()
        val settings = InMemorySettingsStore(
            AppSettings(hasCompletedOnboarding = true, preferredPeerID = facade.online, keepHistory = true, manualEndpoint = "10.0.2.2:1/2"),
        )
        val history = InMemoryHistoryStore().apply {
            add(TransferRecord("a.jpg", 1, "Studio Mac", TransferOutcome.COMPLETED, null, 1))
        }
        val importer = CountingImporter()
        var platformResets = 0
        val model = AppModel(
            facade, settings, history, importer, GestureEngineFactory.core(), backgroundScope,
            platformReset = { platformResets++ },
        )
        model.start()
        model.stage(StagedItem("1", "a.jpg", OutgoingFile("/tmp/a.jpg", "a.jpg", "public.jpeg", 1), "image/jpeg"))

        model.resetEverything()

        assertEquals(setOf(facade.online, facade.offline), facade.unpaired.toSet())
        assertTrue(history.records.value.isEmpty())
        assertEquals(AppSettings(), settings.settings.value)
        assertFalse(settings.settings.value.hasCompletedOnboarding)
        assertNull(model.staged.value)
        assertEquals(1, importer.cleared)
        assertFalse("discovery stopped", facade.discovering)
        assertEquals("identity, PSKs, trust file and manual peers wiped once", 1, platformResets)
    }
}
