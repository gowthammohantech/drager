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
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.settings.SharedPreferencesHistoryStore
import com.spatialbridge.android.settings.SharedPreferencesSettingsStore
import com.spatialbridge.android.ui.SpatialBridgeApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Owns the [AppGraph] (core's SenderService) and the [AppModel] across configuration changes, so a
 * transfer in flight survives rotation. Torn down only when the activity finishes for good.
 */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val graph = AppGraph(application)
    val model = AppModel(
        facade = graph.sender,
        settingsStore = SharedPreferencesSettingsStore(application),
        historyStore = SharedPreferencesHistoryStore(application),
        importer = CacheContentImporter(application),
        gestureEngines = GestureEngineFactory.core(),
        scope = viewModelScope,
        work = Dispatchers.Default,
    )

    init {
        viewModelScope.launch {
            model.settings.map { it.manualEndpoint }.distinctUntilChanged().collect(graph::applyManualEndpoint)
        }
    }

    override fun onCleared() {
        model.stop()
        graph.close()
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
