package com.spatialbridge.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.spatialbridge.android.platform.KeystoreSecretStore
import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.store.PairSecretStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Settings › Reset on the real Keystore store: identity, PSKs, trust file and manual peer IDs all go. */
@RunWith(AndroidJUnit4::class)
class ResetTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val dir = "reset-test-secrets"
    private val alias = "spatialbridge.reset-test.v1"
    private val trustFile = File(context.noBackupFilesDir, "reset-test/trusted-peers.json")
    private val peer = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    private val graphs = mutableListOf<AppGraph>()

    private fun graph(memory: ManualPeerMemory) = AppGraph(
        context, KeystoreSecretStore(context, dir, alias), trustFile, memory, nsdEnabled = false, manualEndpointsAllowed = true,
    ).also { graphs += it }

    @After fun tearDown() {
        graphs.forEach { it.close() }
        KeystoreSecretStore(context, dir, alias).deleteAll()
        trustFile.parentFile?.deleteRecursively()
    }

    @Test
    fun wipeDeletesEverythingAndNextStartHasNewIdentity() = runBlocking {
        KeystoreSecretStore(context, dir, alias).deleteAll()
        trustFile.delete()
        val memory = InMemoryManualPeerMemory()
        val target = ManualEndpoint.parse("10.0.2.2:5000/5001")!!

        val first = graph(memory)
        val identity = first.peerID
        PairSecretStore(first.secrets).store(ByteArray(32) { 7 }, peer)
        first.trustedPeers.upsert(TrustedPeer(peer, "Studio Mac", DevicePlatform.MACOS, "Mac", ByteArray(32) { 1 }))
        memory.remember(target, peer)
        assertTrue(trustFile.exists())

        // Without a reset, the next start loads the same identity and keeps the pair key.
        val restarted = graph(memory)
        assertEquals(identity, restarted.peerID)
        assertEquals(32, PairSecretStore(restarted.secrets).psk(peer)?.size)

        first.wipe()

        assertFalse("trust file deleted", trustFile.exists())
        assertNull("manual peer ID forgotten", memory.peerID(target))
        val fresh = KeystoreSecretStore(context, dir, alias)
        assertNull("PSK deleted", PairSecretStore(fresh).psk(peer))
        val next = graph(memory)
        assertNotEquals("new identity after reset", identity, next.peerID)
        assertTrue(next.trustedPeers.all().isEmpty())
    }
}
