package com.spatialbridge.android.settings

import android.content.Context
import androidx.core.content.edit
import com.spatialbridge.android.model.PhonePlacement
import com.spatialbridge.android.model.SpatialLayout
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class AppSettings(
    val hasCompletedOnboarding: Boolean = false,
    val layout: SpatialLayout = SpatialLayout(),
    /** 0.5 (firm) … 2.0 (easy); divides the velocity threshold. */
    val gestureSensitivity: Double = 1.0,
    val preferredPeerID: String? = null,
    val keepHistory: Boolean = true,
    /** Debug builds only: `host:port` to bypass discovery (emulator → `10.0.2.2`). */
    val manualEndpoint: String? = null,
)

interface SettingsStore {
    val settings: StateFlow<AppSettings>
    fun update(transform: (AppSettings) -> AppSettings)
    fun reset()
}

class InMemorySettingsStore(initial: AppSettings = AppSettings()) : SettingsStore {
    private val state = MutableStateFlow(initial)
    override val settings: StateFlow<AppSettings> = state.asStateFlow()
    override fun update(transform: (AppSettings) -> AppSettings) = state.update(transform)
    override fun reset() { state.value = AppSettings() }
}

/** SharedPreferences-backed settings. Contains no secrets (those live in [com.spatialbridge.android.platform.KeystoreSecretStore]). */
class SharedPreferencesSettingsStore(context: Context) : SettingsStore {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val state = MutableStateFlow(load())
    override val settings: StateFlow<AppSettings> = state.asStateFlow()

    override fun update(transform: (AppSettings) -> AppSettings) {
        state.update(transform)
        save(state.value)
    }

    override fun reset() {
        prefs.edit { clear() }
        state.value = AppSettings()
    }

    private fun load() = AppSettings(
        hasCompletedOnboarding = prefs.getBoolean(K_ONBOARDED, false),
        layout = SpatialLayout(
            placement = PhonePlacement.fromRaw(prefs.getString(K_PLACEMENT, null)),
            alignmentOffset = prefs.getFloat(K_OFFSET, 0f).toDouble().coerceIn(-0.5, 0.5),
            mirrored = prefs.getBoolean(K_MIRRORED, false),
        ),
        gestureSensitivity = prefs.getFloat(K_SENSITIVITY, 1f).toDouble().coerceIn(0.5, 2.0),
        preferredPeerID = prefs.getString(K_PREFERRED, null),
        keepHistory = prefs.getBoolean(K_HISTORY, true),
        manualEndpoint = prefs.getString(K_MANUAL, null),
    )

    private fun save(s: AppSettings) = prefs.edit {
        putBoolean(K_ONBOARDED, s.hasCompletedOnboarding)
        putString(K_PLACEMENT, s.layout.placement.raw)
        putFloat(K_OFFSET, s.layout.alignmentOffset.toFloat())
        putBoolean(K_MIRRORED, s.layout.mirrored)
        putFloat(K_SENSITIVITY, s.gestureSensitivity.toFloat())
        putString(K_PREFERRED, s.preferredPeerID)
        putBoolean(K_HISTORY, s.keepHistory)
        putString(K_MANUAL, s.manualEndpoint)
    }

    private companion object {
        const val K_ONBOARDED = "onboarded"
        const val K_PLACEMENT = "layout.placement"
        const val K_OFFSET = "layout.offset"
        const val K_MIRRORED = "layout.mirrored"
        const val K_SENSITIVITY = "gesture.sensitivity"
        const val K_PREFERRED = "peer.preferred"
        const val K_HISTORY = "history.keep"
        const val K_MANUAL = "debug.manualEndpoint"
    }
}
