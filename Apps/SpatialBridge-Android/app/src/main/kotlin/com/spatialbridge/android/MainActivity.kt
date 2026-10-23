package com.spatialbridge.android

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.annotation.VisibleForTesting
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.spatialbridge.android.content.CacheContentImporter
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.settings.SharedPreferencesHistoryStore
import com.spatialbridge.android.settings.SharedPreferencesSettingsStore
import com.spatialbridge.android.ui.SpatialBridgeApp
import com.spatialbridge.android.ui.SpatialBridgeTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Instrumented tests only: replaces the production graph with a fake facade. Null in the app. */
@VisibleForTesting
object AppTestHooks {
    @Volatile var modelFactory: ((Application, CoroutineScope) -> AppModel)? = null
}

/** One app graph and the [AppModel] over it. Settings › Reset replaces it with a fresh one. */
class AppSession internal constructor(
    val generation: Int,
    val model: AppModel,
    private val graph: AppGraph?,
    private val scope: CoroutineScope,
) {
    internal fun close() {
        model.stop()
        graph?.close()
        scope.cancel()
    }
}

/**
 * Owns the [AppSession] (core's SenderService and the [AppModel]) across configuration changes, so a
 * transfer in flight survives rotation. The graph is built off the main thread (Keystore decrypt or
 * keygen); the UI shows a loading state until [session] is set. Torn down only when the activity
 * finishes for good.
 */
class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val _session = MutableStateFlow<AppSession?>(null)
    val session: StateFlow<AppSession?> = _session.asStateFlow()
    private var generation = 0

    init {
        viewModelScope.launch { open() }
    }

    private suspend fun open() {
        val app = getApplication<Application>()
        val scope = CoroutineScope(viewModelScope.coroutineContext + SupervisorJob(viewModelScope.coroutineContext[Job]))
        val factory = AppTestHooks.modelFactory
        val session = if (factory != null) {
            AppSession(++generation, factory(app, scope), null, scope)
        } else {
            val graph = AppGraph.load(app)
            val settings = withContext(Dispatchers.IO) { SharedPreferencesSettingsStore(app) }
            val history = withContext(Dispatchers.IO) { SharedPreferencesHistoryStore(app) }
            val model = AppModel(
                facade = graph.sender,
                settingsStore = settings,
                historyStore = history,
                importer = CacheContentImporter(app),
                gestureEngines = GestureEngineFactory.core(),
                scope = scope,
                work = Dispatchers.Default,
                platformReset = {
                    graph.wipe()
                    viewModelScope.launch { reopen() }
                },
            )
            scope.launch {
                model.settings.map { it.manualEndpoint }.distinctUntilChanged().collect(graph::applyManualEndpoint)
            }
            AppSession(++generation, model, graph, scope)
        }
        if (session.model.settings.value.hasCompletedOnboarding) session.model.start()
        _session.value = session
    }

    /** After a reset: drop the old graph (its identity was deleted) and build a new one with a new identity. */
    private suspend fun reopen() {
        val old = _session.value
        _session.value = null
        old?.close()
        open()
    }

    override fun onCleared() {
        _session.value?.close()
    }
}

class MainActivity : ComponentActivity() {
    @VisibleForTesting
    internal val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            val session by viewModel.session.collectAsStateWithLifecycle()
            val current = session
            if (current == null) {
                LoadingScreen()
            } else {
                key(current.generation) { SpatialBridgeApp(current.model) }
            }
        }
    }
}

@Composable
private fun LoadingScreen() {
    SpatialBridgeTheme {
        Box(
            Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag("app.loading"),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator()
        }
    }
}
