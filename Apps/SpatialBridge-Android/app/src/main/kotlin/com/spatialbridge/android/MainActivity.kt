package com.spatialbridge.android

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.spatialbridge.android.content.CacheContentImporter
import com.spatialbridge.android.fake.FakeSenderFacade
import com.spatialbridge.android.gesture.PlaceholderGestureEngine
import com.spatialbridge.android.settings.SharedPreferencesHistoryStore
import com.spatialbridge.android.settings.SharedPreferencesSettingsStore
import com.spatialbridge.android.ui.SpatialBridgeApp

/** Owns the [AppModel] across configuration changes. XP2a swaps [FakeSenderFacade] for core's SenderService. */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    val model = AppModel(
        facade = FakeSenderFacade(viewModelScope),
        settingsStore = SharedPreferencesSettingsStore(application),
        historyStore = SharedPreferencesHistoryStore(application),
        importer = CacheContentImporter(application),
        gestureEngines = PlaceholderGestureEngine.factory,
        scope = viewModelScope,
    )

    override fun onCleared() {
        model.stop()
    }
}

class MainActivity : ComponentActivity() {
    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (viewModel.model.settings.value.hasCompletedOnboarding) viewModel.model.start()
        setContent { SpatialBridgeApp(viewModel.model) }
    }
}
