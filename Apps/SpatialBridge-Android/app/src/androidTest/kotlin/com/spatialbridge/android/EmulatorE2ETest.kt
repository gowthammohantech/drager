package com.spatialbridge.android

import android.os.Bundle
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.spatialbridge.android.content.CacheContentImporter
import com.spatialbridge.android.content.ImportResult
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.platform.KeystoreSecretStore
import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.InMemoryHistoryStore
import com.spatialbridge.android.settings.InMemorySettingsStore
import com.spatialbridge.android.ui.SpatialBridgeApp
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.PairingState
import com.spatialbridge.core.TransferState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import kotlin.random.Random

/**
 * End to end against a real receiver on the host (`sb-swift serve`, later `sb-dotnet serve`), through
 * the production graph: KeystoreSecretStore, the file trust store, core's SenderService and the debug
 * manual endpoint (NSD off, since the emulator can't see host mDNS). Driven through the real UI.
 *
 * Skipped unless the host passes `-e sbPairingPort N -e sbSessionPort M` (optionally `-e sbHost`).
 * Results the host script compares with `serve`'s events are reported as instrumentation status
 * (`am instrument -r`), never logged: `sas` (the code shown) and `sourceSha256` (the sent file).
 * Run it with `app/e2e/emulator-e2e.sh`.
 */
/** Needs a receiver on the host; excluded from `connectedDebugAndroidTest`, run by `app/e2e/emulator-e2e.sh`. */
@Retention(AnnotationRetention.RUNTIME)
@Target(AnnotationTarget.CLASS)
annotation class HostReceiverTest

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
@HostReceiverTest
class EmulatorE2ETest {
    @get:Rule val compose = createComposeRule()

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val args = InstrumentationRegistry.getArguments()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var graph: AppGraph? = null

    private fun report(key: String, value: String) {
        instrumentation.sendStatus(STATUS_CODE, Bundle().apply { putString(key, value) })
    }

    @After fun tearDown() {
        graph?.close()
        scope.cancel()
    }

    @Test
    fun pairSendCommitThenFailurePaths() {
        val host = args.getString("sbHost") ?: ManualEndpoint.EMULATOR_HOST
        val pairingPort = args.getString("sbPairingPort")
        val sessionPort = args.getString("sbSessionPort")
        assumeTrue("needs -e sbPairingPort and -e sbSessionPort", pairingPort != null && sessionPort != null)
        val endpoint = "$host:$pairingPort/$sessionPort"
        val target = ManualEndpoint.parse(endpoint)!!

        // Fresh, isolated identity and trust store for every run.
        val secretsDir = "e2e-secrets"
        val alias = "spatialbridge.e2e.v1"
        KeystoreSecretStore(context, secretsDir, alias).deleteAll()
        val trustFile = File(context.noBackupFilesDir, "e2e/trusted-peers.json").apply { delete() }
        val graph = AppGraph(
            context,
            secrets = KeystoreSecretStore(context, secretsDir, alias),
            trustedPeerFile = trustFile,
            manualPeerMemory = InMemoryManualPeerMemory(),
            nsdEnabled = false,
            manualEndpointsAllowed = true,
        ).also { graph = it }
        val importer = CacheContentImporter(context)
        val model = AppModel(
            graph.sender, InMemorySettingsStore(AppSettings(hasCompletedOnboarding = true, manualEndpoint = endpoint)),
            InMemoryHistoryStore(), importer, GestureEngineFactory.core(), scope, work = Dispatchers.Default,
        )
        graph.applyManualEndpoint(endpoint)
        model.start()
        compose.setContent { SpatialBridgeApp(model) }

        // Pair through the UI. serve auto-approves; we confirm after reading the code.
        waitForTag("home.pair")
        compose.onNodeWithTag("home.pair").performClick()
        waitForTag("discover.peer.${target.locatorID}")
        compose.onNodeWithTag("discover.peer.${target.locatorID}").performClick()
        waitForTag("pairing.code", 30_000)
        val shown = compose.onNodeWithTag("pairing.code").fetchSemanticsNode()
            .config[SemanticsProperties.Text].joinToString("") { it.text }
        val sas = shown.filter(Char::isDigit)
        assertEquals("SAS is six digits", 6, sas.length)
        report("sas", sas)
        compose.onNodeWithTag("pairing.match").performClick()
        waitForTag("pairing.done", 40_000)
        val paired = graph.sender.pairing.value
        assertTrue("pairing state: $paired", paired is PairingState.Paired)
        report("peerID", (paired as PairingState.Paired).peerID)
        compose.onNodeWithTag("pairing.done").performClick()
        compose.waitUntil(TIMEOUT) { model.trustedPeers.value.any { it.peerID == paired.peerID } }
        compose.onNodeWithTag("overlay.back").performClick()

        // 1. A 3 MiB file with an uppercase extension: offered as `E2E Payload.bin`, must commit.
        val payload = Random(42).nextBytes(3 * 1024 * 1024 + 123)
        report("sourceSha256", MessageDigest.getInstance("SHA-256").digest(payload).joinToString("") { "%02x".format(it) })
        report("sourceBytes", payload.size.toString())
        val big = stage(importer, model, payload, "E2E Payload.BIN", "application/octet-stream")
        assertEquals("public.data", big.contentType)
        compose.onNodeWithTag("home.send").performScrollTo().performClick()
        waitForTag("transfer.success", 120_000)
        val committed = graph.sender.transfer.value
        assertTrue("transfer state: $committed", committed is TransferState.Committed)
        assertEquals(payload.size.toLong(), (committed as TransferState.Committed).byteCount)
        report("committed", "true")
        compose.runOnIdle { model.dismissTransfer() }

        // 2. An unsafe type: the receiver's policy rejects a shell script with E006.
        stage(importer, model, "echo hi\n".encodeToByteArray(), "run.SH", null)
        compose.onNodeWithTag("home.send").performScrollTo().performClick()
        expectFailure(graph, BridgeErrorCode.UNSUPPORTED_FILE)
        report("unsafeType", "E006")
        compose.runOnIdle { model.dismissTransfer() }

        // 3. A 0-byte file: refused before the offer with E006, never shown as success.
        stage(importer, model, ByteArray(0), "empty.txt", "text/plain")
        compose.onNodeWithTag("home.send").performScrollTo().performClick()
        expectFailure(graph, BridgeErrorCode.UNSUPPORTED_FILE)
        report("emptyFile", "E006")
    }

    private fun stage(importer: CacheContentImporter, model: AppModel, bytes: ByteArray, name: String, mime: String?) =
        runBlocking { importer.importStream(ByteArrayInputStream(bytes), name, mime) }.let { result ->
            assertTrue("import: $result", result is ImportResult.Staged)
            val item = (result as ImportResult.Staged).item
            compose.runOnIdle { model.stage(item) }
            waitForTag("home.send")
            item.file
        }

    private fun expectFailure(graph: AppGraph, code: BridgeErrorCode) {
        waitForTag("transfer.error", 60_000)
        assertEquals(TransferState.Failed(code), graph.sender.transfer.value)
        compose.onNodeWithTag("transfer.success").assertDoesNotExist()
    }

    private fun waitForTag(tag: String, timeout: Long = TIMEOUT) = compose.waitUntilAtLeastOneExists(hasTestTag(tag), timeout)

    private companion object {
        const val TIMEOUT = 15_000L
        const val STATUS_CODE = 7
    }
}
