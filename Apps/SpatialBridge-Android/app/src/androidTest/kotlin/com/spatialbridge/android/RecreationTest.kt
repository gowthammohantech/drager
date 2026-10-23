package com.spatialbridge.android

import android.os.Build
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.spatialbridge.android.content.ContentImporter
import com.spatialbridge.android.content.ImportResult
import com.spatialbridge.android.content.StagedItem
import com.spatialbridge.android.fake.FakeSenderFacade
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.model.TransferPhase
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.InMemoryHistoryStore
import com.spatialbridge.android.settings.InMemorySettingsStore
import com.spatialbridge.android.settings.TransferOutcome
import com.spatialbridge.core.OutgoingFile
import com.spatialbridge.core.TransferState
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.RunWith

/**
 * A transfer started in MainActivity keeps running through an activity recreation (what rotation
 * does): the ViewModel keeps the same AppModel and facade, the new activity shows the same transfer,
 * and it reaches success exactly once. Uses the fake facade through [AppTestHooks].
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class RecreationTest {
    private val compose = createEmptyComposeRule()

    @get:Rule
    val rules: TestRule = RuleChain
        .outerRule(
            if (Build.VERSION.SDK_INT >= 33) GrantPermissionRule.grant("android.permission.NEARBY_WIFI_DEVICES")
            else GrantPermissionRule.grant(),
        )
        .around(compose)

    private val mac = FakeSenderFacade.DEFAULT_PEERS.first()
    private val item = StagedItem(
        "rotate", "Holiday.jpg",
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

    @After fun tearDown() {
        AppTestHooks.modelFactory = null
    }

    @Test
    fun transferSurvivesActivityRecreation() {
        var built = 0
        lateinit var facade: FakeSenderFacade
        val history = InMemoryHistoryStore()
        AppTestHooks.modelFactory = { _, scope ->
            built++
            // ~12 chunks at 400 ms each: the transfer is still streaming when the activity is recreated.
            facade = FakeSenderFacade(
                scope,
                FakeSenderFacade.Script(discoveryDelayMillis = 100, stepMillis = 1_200, chunks = 12, initiallyTrusted = setOf(mac.peerID)),
            )
            AppModel(
                facade, InMemorySettingsStore(AppSettings(hasCompletedOnboarding = true)), history, NoImporter,
                GestureEngineFactory.core(), scope,
            )
        }

        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var model: AppModel
            lateinit var firstActivity: MainActivity
            compose.waitUntil(TIMEOUT) {
                var ready = false
                scenario.onActivity { a -> a.viewModel.session.value?.let { model = it.model; firstActivity = a; ready = true } }
                ready
            }
            compose.waitUntil(TIMEOUT) { model.trustedPeers.value.isNotEmpty() }
            compose.runOnIdle { model.stage(item) }
            compose.onNodeWithTag("home.send").performScrollTo().performClick()
            compose.waitUntil(TIMEOUT) { facade.transfer.value is TransferState.Sending }
            compose.waitUntilAtLeastOneExists(hasTestTag("transfer.progress"), TIMEOUT)

            scenario.recreate()

            // A new activity, the same model and the same in-flight transfer.
            scenario.onActivity { a ->
                assertNotSame(firstActivity, a)
                assertSame(model, a.viewModel.session.value?.model)
            }
            assertEquals("graph built once", 1, built)
            assertTrue("still in flight after recreation: ${model.transferUi.value.phase}", model.transferUi.value.phase.isActive)
            compose.waitUntilAtLeastOneExists(hasTestTag("transfer.progress"), TIMEOUT)
            compose.onNodeWithTag("transfer.success").assertDoesNotExist()

            compose.waitUntilAtLeastOneExists(hasTestTag("transfer.success"), 60_000)
            assertEquals(TransferPhase.COMPLETED, model.transferUi.value.phase)
            assertTrue(facade.transfer.value is TransferState.Committed)
            assertEquals(1, history.records.value.size)
            assertEquals(TransferOutcome.COMPLETED, history.records.value.single().outcome)
        }
    }

    private companion object {
        const val TIMEOUT = 15_000L
    }
}
