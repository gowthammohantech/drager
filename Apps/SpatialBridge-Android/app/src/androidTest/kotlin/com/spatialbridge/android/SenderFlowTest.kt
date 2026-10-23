package com.spatialbridge.android

import android.os.Build
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.geometry.Offset
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.spatialbridge.android.content.ContentImporter
import com.spatialbridge.android.content.ImportResult
import com.spatialbridge.android.content.StagedItem
import com.spatialbridge.android.fake.FakeSenderFacade
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.InMemoryHistoryStore
import com.spatialbridge.android.settings.InMemorySettingsStore
import com.spatialbridge.android.ui.SpatialBridgeApp
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.OutgoingFile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.RunWith

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class SenderFlowTest {
    private val compose = createComposeRule()

    @get:Rule
    val rules: TestRule = RuleChain
        .outerRule(
            if (Build.VERSION.SDK_INT >= 33) GrantPermissionRule.grant("android.permission.NEARBY_WIFI_DEVICES")
            else GrantPermissionRule.grant(),
        )
        .around(compose)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mac = FakeSenderFacade.DEFAULT_PEERS.first()
    private val timeout = 10_000L

    private val item = StagedItem(
        "test", "Holiday.jpg",
        OutgoingFile(
            InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.resolve("Holiday.jpg").absolutePath,
            "Holiday.jpg", "public.jpeg", 2_400_000,
        ),
        "image/jpeg",
    )

    private object NoImporter : ContentImporter {
        override suspend fun import(uri: android.net.Uri) = ImportResult.Unreadable
        override fun clear() = Unit
    }

    private fun launch(script: FakeSenderFacade.Script, settings: AppSettings = AppSettings()): AppModel {
        val model = AppModel(
            FakeSenderFacade(scope, script), InMemorySettingsStore(settings), InMemoryHistoryStore(), NoImporter,
            GestureEngineFactory.core(), scope,
        )
        if (settings.hasCompletedOnboarding) model.start()
        compose.setContent { SpatialBridgeApp(model) }
        return model
    }

    private fun fastScript(failure: BridgeErrorCode? = null, trusted: Set<String> = emptySet()) =
        FakeSenderFacade.Script(discoveryDelayMillis = 200, stepMillis = 150, transferFailure = failure, initiallyTrusted = trusted)

    private fun waitForTag(tag: String) = compose.waitUntilAtLeastOneExists(hasTestTag(tag), timeout)

    @After fun tearDown() = scope.cancel()

    @Test
    fun onboardingDiscoveryPairingSendSuccess() {
        val model = launch(fastScript())

        compose.onNodeWithTag("onboarding.start").performClick()
        compose.onNodeWithTag("onboarding.localNetwork.continue").performClick()

        // Discovery lists the computer with its platform.
        waitForTag("discover.peer.${mac.peerID}")
        compose.onNodeWithText("Studio Mac").assertExists()
        compose.onNodeWithText("Desk PC").assertExists()
        compose.onNodeWithTag("discover.peer.${mac.peerID}").performClick()

        // Pairing sheet: SAS and the comparison question.
        waitForTag("pairing.code")
        compose.onNodeWithText("Does this code match the one on your computer?").assertExists()
        compose.onNodeWithTag("pairing.code").assertTextContains("482 915")
        compose.onNodeWithTag("pairing.match").performClick()
        waitForTag("pairing.done")
        compose.onNodeWithText("Paired with Studio Mac").assertExists()
        compose.onNodeWithTag("pairing.done").performClick()

        waitForTag("onboarding.discover.continue")
        compose.onNodeWithTag("onboarding.discover.continue").performClick()
        compose.onNodeWithTag("onboarding.calibration.continue").performClick()
        compose.onNodeWithTag("onboarding.finish").performClick()

        // Home: stage a file (the system pickers can't be driven from a Compose test) and send.
        waitForTag("home.status")
        compose.onNodeWithTag("home.peerName").assertTextContains("Studio Mac")
        compose.runOnIdle { model.stage(item) }
        compose.onNodeWithTag("home.send").performScrollTo().performClick()

        waitForTag("transfer.progress")
        compose.onNodeWithTag("transfer.success").assertDoesNotExist()
        waitForTag("transfer.success")
        compose.onNodeWithTag("transfer.success").assertTextContains("Saved on Studio Mac")
        compose.onNodeWithTag("home.recent").assertExists()
    }

    @Test
    fun failedTransferShowsFriendlyMessageAndNoSuccess() {
        val model = launch(fastScript(BridgeErrorCode.UNSUPPORTED_FILE, setOf(mac.peerID)), AppSettings(hasCompletedOnboarding = true))
        compose.waitUntil(timeout) { model.trustedPeers.value.isNotEmpty() }
        compose.runOnIdle { model.stage(item) }
        compose.onNodeWithTag("home.send").performScrollTo().performClick()

        waitForTag("transfer.error")
        compose.onNodeWithText("This file type isn't supported.").assertExists()
        compose.onNodeWithText("Choose a different file.").assertExists()
        compose.onNodeWithTag("transfer.success").assertDoesNotExist()
        compose.onNodeWithTag("transfer.retry").assertExists()
    }

    @Test
    fun mismatchedCodesDeclinePairing() {
        launch(fastScript())
        compose.onNodeWithTag("onboarding.start").performClick()
        compose.onNodeWithTag("onboarding.localNetwork.continue").performClick()
        waitForTag("discover.peer.${mac.peerID}")
        compose.onNodeWithTag("discover.peer.${mac.peerID}").performClick()
        waitForTag("pairing.mismatch")
        compose.onNodeWithTag("pairing.mismatch").performClick()
        waitForTag("pairing.failed")
        compose.onNodeWithText("Pairing was declined.").assertExists()
        compose.onNodeWithTag("pairing.ok").performClick()
        compose.waitUntilDoesNotExist(hasTestTag("pairing.sheet"), timeout)
        compose.onNodeWithTag("onboarding.discover.continue").assertDoesNotExist()
    }

    @Test
    fun flickTowardTopEdgeSends() {
        val model = launch(fastScript(trusted = setOf(mac.peerID)), AppSettings(hasCompletedOnboarding = true))
        compose.waitUntil(timeout) { model.trustedPeers.value.isNotEmpty() }
        compose.runOnIdle { model.stage(item) }
        waitForTag("throw.canvas")
        compose.onNodeWithTag("throw.canvas").performTouchInput {
            swipe(start = center, end = Offset(centerX, 1f), durationMillis = 120)
        }
        waitForTag("transfer.success")
        compose.onNode(hasText("Saved on Studio Mac")).assertExists()
    }
}
