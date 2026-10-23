package com.spatialbridge.android

import android.net.Uri
import com.spatialbridge.android.content.ContentImporter
import com.spatialbridge.android.content.ImportResult
import com.spatialbridge.android.content.StagedItem
import com.spatialbridge.android.diagnostics.BridgeLog
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.model.TransferPhase
import com.spatialbridge.android.model.TransferUi
import com.spatialbridge.android.model.TransferUiMapper
import com.spatialbridge.android.settings.AppSettings
import com.spatialbridge.android.settings.HistoryStore
import com.spatialbridge.android.settings.SettingsStore
import com.spatialbridge.android.settings.TransferOutcome
import com.spatialbridge.android.settings.TransferRecord
import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DiscoveredPeer
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.PairingState
import com.spatialbridge.core.SenderFacade
import com.spatialbridge.core.TransferState
import com.spatialbridge.core.gesture.GestureConfiguration
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** Pairing sheet content. `null` while the sheet is hidden. */
data class PairingSheetState(val peerName: String, val state: PairingState)

/** The transfer the UI is following. [baseline] is the facade state before it started (see [AppModel.transferUi]). */
private data class ActiveTransfer(
    val item: StagedItem,
    val gesture: ExitGesture?,
    val peerName: String?,
    val baseline: TransferState,
    val preparing: Boolean = true,
    val localFailure: BridgeErrorCode? = null,
    val recorded: Boolean = false,
    /** The facade's terminal state read when `send` returned (see [AppModel.transferUi]). */
    val finished: TransferState? = null,
)

/**
 * App-wide state and actions, the Android counterpart of the iOS `AppModel`. Views read flows and call
 * methods; all protocol work goes through [SenderFacade].
 */
class AppModel(
    private val facade: SenderFacade,
    val settingsStore: SettingsStore,
    val historyStore: HistoryStore,
    private val importer: ContentImporter,
    val gestureEngines: GestureEngineFactory,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Where pairing and unpairing run (crypto, socket and key-store work). Production passes `Dispatchers.Default`. */
    private val work: CoroutineContext = EmptyCoroutineContext,
) {
    val settings: StateFlow<AppSettings> = settingsStore.settings
    val peers: StateFlow<List<DiscoveredPeer>> = facade.peers
    val history: StateFlow<List<TransferRecord>> = historyStore.records

    /** Paired receivers: the visible ones from discovery, then offline ones from the trust store. */
    val trustedPeers: StateFlow<List<DiscoveredPeer>> = combine(facade.peers, facade.trustedPeers) { visible, stored ->
        val online = visible.filter { it.isTrusted }
        online + stored.filter { s -> online.none { it.peerID == s.peerID } }
            .map { DiscoveredPeer(it.peerID, it.displayName, it.platform, isTrusted = true, pairingAvailable = false) }
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    private val _staged = MutableStateFlow<StagedItem?>(null)
    val staged: StateFlow<StagedItem?> = _staged.asStateFlow()
    private val _importing = MutableStateFlow(false)
    val importing: StateFlow<Boolean> = _importing.asStateFlow()
    private val _importError = MutableStateFlow<BridgeErrorCode?>(null)
    val importError: StateFlow<BridgeErrorCode?> = _importError.asStateFlow()

    /** Set when the runtime local-network permission is denied or the network is unavailable (E001). */
    private val _localNetworkDenied = MutableStateFlow(false)
    val localNetworkDenied: StateFlow<Boolean> = combine(_localNetworkDenied, facade.discoveryError) { denied, error ->
        denied || error == BridgeErrorCode.LOCAL_NETWORK_DENIED
    }.stateIn(scope, SharingStarted.Eagerly, false)

    private val pairingPeer = MutableStateFlow<DiscoveredPeer?>(null)
    val pairingSheet: StateFlow<PairingSheetState?> = combine(pairingPeer, facade.pairing) { peer, state ->
        peer?.let { PairingSheetState(it.displayName, state) }
    }.stateIn(scope, SharingStarted.Eagerly, null)

    private val active = MutableStateFlow<ActiveTransfer?>(null)

    /**
     * What the transfer card shows. Until the facade publishes a state *newer than* [ActiveTransfer.baseline]
     * the card says "Preparing", so a stale `Committed` from the last transfer can never flash success for
     * this one. Success itself comes only from [TransferUiMapper] on [TransferState.Committed].
     *
     * StateFlow collectors skip values *equal* to the last one they saw, so a second transfer that ends in
     * the same `Failed(code)` as the baseline would never be observed through the flow. The terminal state
     * read when `send` returns ([ActiveTransfer.finished]) covers that case.
     */
    val transferUi: StateFlow<TransferUi> = combine(active, facade.transfer) { a, state ->
        when {
            a == null -> TransferUi.IDLE
            a.localFailure != null -> TransferUiMapper.map(TransferState.Failed(a.localFailure), a.item.displayName, a.peerName)
            a.finished != null -> TransferUiMapper.map(a.finished, a.item.displayName, a.peerName)
            a.preparing || state === a.baseline ->
                TransferUiMapper.map(TransferState.Idle, a.item.displayName, a.peerName, preparing = true)
            else -> TransferUiMapper.map(state, a.item.displayName, a.peerName)
        }
    }.stateIn(scope, SharingStarted.Eagerly, TransferUi.IDLE)

    private var started = false
    private var pairingJob: Job? = null
    private var transferJob: Job? = null
    private var importJob: Job? = null

    init {
        scope.launch { transferUi.collect(::recordIfFinished) }
    }

    val gestureConfiguration: GestureConfiguration
        get() = GestureConfiguration(sensitivity = settings.value.gestureSensitivity)

    val preferredPeer: DiscoveredPeer?
        get() {
            val trusted = trustedPeers.value
            return trusted.firstOrNull { it.peerID == settings.value.preferredPeerID } ?: trusted.firstOrNull()
        }

    // Lifecycle

    /** Starts discovery. Called once the local-network step is reached, or at launch after onboarding. */
    fun start() {
        if (started) return
        started = true
        facade.startDiscovery()
    }

    fun stop() {
        if (!started) return
        started = false
        facade.stopDiscovery()
    }

    fun setLocalNetworkDenied(denied: Boolean) {
        _localNetworkDenied.value = denied
    }

    fun completeOnboarding() {
        settingsStore.update { it.copy(hasCompletedOnboarding = true) }
        start()
    }

    // Pairing (FR-107)

    fun pair(peer: DiscoveredPeer) {
        if (pairingJob?.isActive == true) return
        pairingPeer.value = peer
        pairingJob = scope.launch {
            try {
                withContext(work) { facade.pair(peer.peerID) }
                val state = facade.pairing.value
                if (state is PairingState.Paired) {
                    if (settings.value.preferredPeerID == null) setPreferred(state.peerID)
                    BridgeLog.info("Paired")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                BridgeLog.warn("Pairing threw ${e.javaClass.simpleName}")
            }
        }
    }

    fun answerPairing(codesMatch: Boolean) = facade.answerPairing(codesMatch)

    fun cancelPairing() {
        facade.cancelPairing()
        pairingJob?.cancel()
        pairingJob = null
        pairingPeer.value = null
    }

    fun dismissPairing() {
        pairingPeer.value = null
    }

    fun unpair(peerID: String) {
        scope.launch {
            withContext(work) { facade.unpair(peerID) }
            if (settings.value.preferredPeerID == peerID) setPreferred(trustedPeers.value.firstOrNull { it.peerID != peerID }?.peerID)
        }
    }

    fun setPreferred(peerID: String?) {
        settingsStore.update { it.copy(preferredPeerID = peerID) }
        facade.setPreferredPeer(peerID)
    }

    // Content

    fun import(uri: Uri) {
        importJob?.cancel()
        _importError.value = null
        _importing.value = true
        importJob = scope.launch {
            try {
                when (val result = importer.import(uri)) {
                    is ImportResult.Staged -> _staged.value = result.item
                    ImportResult.TooLarge -> _importError.value = BridgeErrorCode.SIZE_LIMIT
                    ImportResult.Unreadable -> _importError.value = BridgeErrorCode.UNSUPPORTED_FILE
                }
            } finally {
                _importing.value = false
            }
        }
    }

    /** Stages an already-prepared item (used by import and by UI tests). */
    fun stage(item: StagedItem) {
        _staged.value = item
        _importError.value = null
    }

    fun clearStaged() {
        if (transferUi.value.phase.isActive) return
        _staged.value = null
    }

    // Transfers (FR-105, FR-106, FR-108)

    /**
     * Starts one transfer for one gesture or Send tap. Ignored while a transfer is active, so a single
     * activation never starts two transfers (FR-108). Phone-side calibration is applied here (ADR-004).
     */
    fun send(gesture: ExitGesture?) {
        val item = _staged.value ?: return
        if (transferUi.value.phase.isActive) return
        val layout = settings.value.layout
        val calibrated = gesture?.copy(normalizedPosition = layout.mapNormalizedPosition(gesture.normalizedPosition))
        run(item, calibrated)
    }

    fun retry() {
        val a = active.value ?: return
        if (transferUi.value.phase.isActive) return
        run(a.item, a.gesture)
    }

    fun cancelTransfer() {
        if (active.value?.preparing == true) {
            transferJob?.cancel()
            active.value = active.value?.copy(preparing = false, localFailure = BridgeErrorCode.TRANSFER_CANCELED)
            return
        }
        facade.cancelTransfer()
    }

    fun dismissTransfer() {
        if (transferUi.value.phase.isActive) return
        active.value = null
    }

    private fun run(item: StagedItem, gesture: ExitGesture?) {
        val peer = preferredPeer
        active.value = ActiveTransfer(item, gesture, peer?.displayName, baseline = facade.transfer.value)
        transferJob = scope.launch {
            active.value = active.value?.copy(preparing = false)
            try {
                facade.send(item.file, gesture, peer?.peerID)
                val final = facade.transfer.value
                val terminal = final is TransferState.Committed || final is TransferState.Failed
                if (terminal && final !== active.value?.baseline) active.value = active.value?.copy(finished = final)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                BridgeLog.warn("Send threw ${e.javaClass.simpleName}")
                active.value = active.value?.copy(localFailure = BridgeErrorCode.PEER_LOST)
            }
        }
    }

    private fun recordIfFinished(ui: TransferUi) {
        val a = active.value ?: return
        if (a.recorded) return
        val outcome = when (ui.phase) {
            TransferPhase.COMPLETED -> TransferOutcome.COMPLETED
            TransferPhase.FAILED -> TransferOutcome.FAILED
            TransferPhase.CANCELLED -> TransferOutcome.CANCELLED
            else -> return
        }
        active.value = a.copy(recorded = true)
        BridgeLog.info("Transfer finished: $outcome ${ui.error?.wire ?: ""}")
        if (settings.value.keepHistory) {
            historyStore.add(
                TransferRecord(
                    filename = ui.savedFilename ?: a.item.displayName,
                    byteCount = a.item.file.byteCount,
                    peerName = a.peerName ?: "Computer",
                    outcome = outcome,
                    errorCode = ui.error,
                    atMillis = clock(),
                ),
            )
        }
    }

    // Settings

    fun setKeepHistory(keep: Boolean) {
        settingsStore.update { it.copy(keepHistory = keep) }
        if (!keep) historyStore.clear()
    }

    fun clearHistory() = historyStore.clear()

    /** Unpairs everything, clears history, staged files and settings (Settings › Reset). */
    fun resetEverything() {
        scope.launch {
            withContext(work) { trustedPeers.value.forEach { facade.unpair(it.peerID) } }
            historyStore.clear()
            importer.clear()
            _staged.value = null
            active.value = null
            settingsStore.reset()
            stop()
        }
    }
}
