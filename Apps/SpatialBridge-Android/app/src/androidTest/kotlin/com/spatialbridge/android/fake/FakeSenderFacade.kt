package com.spatialbridge.android.fake

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.DiscoveredPeer
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.OutgoingFile
import com.spatialbridge.core.PairingState
import com.spatialbridge.core.SenderFacade
import com.spatialbridge.core.TransferState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Scripted stand-in for core's SenderService (lane AU). Discovery yields [Script.peers] after a delay,
 * pairing shows [Script.sasCode], and a send walks Connecting → Offering → Sending → AwaitingCommit →
 * Committed unless [Script.transferFailure] says otherwise. UI tests only: production uses core's SenderService.
 */
class FakeSenderFacade(
    private val scope: CoroutineScope,
    val script: Script = Script(),
) : SenderFacade {

    class Script(
        val peers: List<DiscoveredPeer> = DEFAULT_PEERS,
        val discoveryDelayMillis: Long = 700,
        val sasCode: String = "482915",
        val stepMillis: Long = 450,
        val chunks: Int = 8,
        /** Fails the next transfers with this code (offer-time codes fail at Offering, others mid-stream). */
        @Volatile var transferFailure: BridgeErrorCode? = null,
        /** Fails pairing after the user confirms (for example E004 or E014). */
        @Volatile var pairingFailure: BridgeErrorCode? = null,
        val initiallyTrusted: Set<String> = emptySet(),
    )

    private val trusted = MutableStateFlow(script.initiallyTrusted)
    private val visible = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    private val _peers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    override val peers: StateFlow<List<DiscoveredPeer>> = _peers.asStateFlow()
    private val _pairing = MutableStateFlow<PairingState>(PairingState.Idle)
    override val pairing: StateFlow<PairingState> = _pairing.asStateFlow()
    private val _transfer = MutableStateFlow<TransferState>(TransferState.Idle)
    override val transfer: StateFlow<TransferState> = _transfer.asStateFlow()

    private var discoveryJob: Job? = null
    private var answer: CompletableDeferred<Boolean>? = null
    @Volatile private var cancelRequested = false
    private var preferred: String? = null

    override fun startDiscovery() {
        if (discoveryJob?.isActive == true) return
        discoveryJob = scope.launch {
            delay(script.discoveryDelayMillis)
            visible.value = script.peers
            publish()
        }
    }

    override fun stopDiscovery() {
        discoveryJob?.cancel()
        discoveryJob = null
    }

    override suspend fun pair(peerID: String) {
        val peer = script.peers.firstOrNull { it.peerID == peerID }
        if (peer == null) {
            _pairing.value = PairingState.Failed(BridgeErrorCode.NO_PEER)
            return
        }
        _pairing.value = PairingState.Connecting
        delay(script.stepMillis)
        val pending = CompletableDeferred<Boolean>()
        answer = pending
        _pairing.value = PairingState.CompareCode(peer.displayName, script.sasCode)
        try {
            if (!pending.await()) {
                _pairing.value = PairingState.Failed(BridgeErrorCode.PAIRING_REJECTED)
                return
            }
        } finally {
            answer = null
        }
        _pairing.value = PairingState.WaitingForPeer
        delay(script.stepMillis)
        script.pairingFailure?.let {
            _pairing.value = PairingState.Failed(it)
            return
        }
        trusted.value = trusted.value + peerID
        if (preferred == null) preferred = peerID
        publish()
        _pairing.value = PairingState.Paired(peerID)
    }

    override fun answerPairing(codesMatch: Boolean) {
        answer?.complete(codesMatch)
    }

    override suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String?) {
        cancelRequested = false
        val target = peerID?.takeIf { it in trusted.value } ?: preferred?.takeIf { it in trusted.value } ?: trusted.value.firstOrNull()
        _transfer.value = TransferState.Connecting
        delay(script.stepMillis)
        if (target == null || visible.value.none { it.peerID == target }) return fail(BridgeErrorCode.NO_PEER)
        if (cancelRequested) return fail(BridgeErrorCode.TRANSFER_CANCELED)
        _transfer.value = TransferState.Offering
        delay(script.stepMillis)
        val failure = script.transferFailure
        if (failure in OFFER_TIME_FAILURES) return fail(failure!!)
        val total = file.byteCount.coerceAtLeast(1)
        for (i in 1..script.chunks) {
            if (cancelRequested) return fail(BridgeErrorCode.TRANSFER_CANCELED)
            _transfer.value = TransferState.Sending(total * i / script.chunks, total)
            delay(script.stepMillis / 3)
            if (failure != null && i == script.chunks / 2) return fail(failure)
        }
        _transfer.value = TransferState.AwaitingCommit
        delay(script.stepMillis)
        if (cancelRequested) return fail(BridgeErrorCode.TRANSFER_CANCELED)
        _transfer.value = TransferState.Committed(file.sanitizedName, file.byteCount)
    }

    override fun cancelTransfer() {
        cancelRequested = true
    }

    override suspend fun unpair(peerID: String) {
        trusted.value = trusted.value - peerID
        if (preferred == peerID) preferred = trusted.value.firstOrNull()
        publish()
    }

    override fun setPreferredPeer(peerID: String?) {
        preferred = peerID
    }

    private fun fail(code: BridgeErrorCode) {
        _transfer.value = TransferState.Failed(code)
    }

    private fun publish() {
        val t = trusted.value
        _peers.value = visible.value.map { it.copy(isTrusted = it.peerID in t) }
    }

    companion object {
        private val OFFER_TIME_FAILURES = setOf(
            BridgeErrorCode.UNSUPPORTED_FILE, BridgeErrorCode.SIZE_LIMIT, BridgeErrorCode.INSUFFICIENT_STORAGE,
            BridgeErrorCode.DESTINATION_PERMISSION_EXPIRED, BridgeErrorCode.AUTHENTICATION_FAILED,
        )

        val DEFAULT_PEERS = listOf(
            DiscoveredPeer("0f1e2d3c4b5a69788796a5b4c3d2e1f0", "Studio Mac", DevicePlatform.MACOS, isTrusted = false, pairingAvailable = true),
            DiscoveredPeer("a1b2c3d4e5f60718293a4b5c6d7e8f90", "Desk PC", DevicePlatform.WINDOWS, isTrusted = false, pairingAvailable = true),
        )
    }
}
