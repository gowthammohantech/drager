package com.spatialbridge.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel

enum class MainTab(val title: String) { SEND("Send"), HISTORY("History"), SETTINGS("Settings") }
enum class Overlay { NONE, PAIR, CALIBRATION }

/** Routes between onboarding and the main tabs, and hosts the pairing sheet. */
@Composable
fun SpatialBridgeApp(model: AppModel) {
    SpatialBridgeTheme {
        val settings by model.settings.collectAsStateWithLifecycle()
        Box(Modifier.fillMaxSize()) {
            if (settings.hasCompletedOnboarding) MainScreen(model) else OnboardingFlow(model)
            PairingSheetHost(model)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainScreen(model: AppModel) {
    var tab by rememberSaveable { mutableStateOf(MainTab.SEND) }
    var overlay by rememberSaveable { mutableStateOf(Overlay.NONE) }
    BackHandler(enabled = overlay != Overlay.NONE) { overlay = Overlay.NONE }

    if (overlay != Overlay.NONE) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(if (overlay == Overlay.PAIR) "Pair a computer" else "Calibration") },
                    navigationIcon = {
                        IconButton(onClick = { overlay = Overlay.NONE }, modifier = Modifier.testTag("overlay.back")) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    },
                )
            },
        ) { padding ->
            Box(Modifier.padding(padding)) {
                when (overlay) {
                    Overlay.PAIR -> DiscoveryScreen(model)
                    Overlay.CALIBRATION -> CalibrationScreen(model)
                    Overlay.NONE -> Unit
                }
            }
        }
        return
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text(if (tab == MainTab.SEND) "Spatial Bridge" else tab.title) }) },
        bottomBar = {
            NavigationBar {
                MainTab.entries.forEach { t ->
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = {
                            Icon(
                                when (t) {
                                    MainTab.SEND -> Icons.AutoMirrored.Filled.Send
                                    MainTab.HISTORY -> Icons.Filled.History
                                    MainTab.SETTINGS -> Icons.Filled.Settings
                                },
                                contentDescription = null,
                            )
                        },
                        label = { Text(t.title) },
                        modifier = Modifier.testTag("tab.${t.name.lowercase()}"),
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when (tab) {
                MainTab.SEND -> HomeScreen(model, onPair = { overlay = Overlay.PAIR })
                MainTab.HISTORY -> HistoryScreen(model)
                MainTab.SETTINGS -> SettingsScreen(
                    model,
                    onPair = { overlay = Overlay.PAIR },
                    onCalibrate = { overlay = Overlay.CALIBRATION },
                )
            }
        }
    }
}
