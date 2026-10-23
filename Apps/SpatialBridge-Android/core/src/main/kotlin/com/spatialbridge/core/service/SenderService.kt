package com.spatialbridge.core.service

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DiscoveredPeer
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.OutgoingFile
import com.spatialbridge.core.PairingState
import com.spatialbridge.core.SenderFacade
import com.spatialbridge.core.TransferState
import com.spatialbridge.core.TrustedPeerInfo
import com.spatialbridge.core.ConnectionStatus
import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.crypto.PairingCrypto
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.BridgeProtocol
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.PeerIDs
import com.spatialbridge.core.model.TransferLimits
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.net.Endpoint
import com.spatialbridge.core.net.PeerConnector
import com.spatialbridge.core.session.PairingProtocol
import com.spatialbridge.core.session.SessionAuthenticator
import com.spatialbridge.core.session.SessionChannel
import com.spatialbridge.core.store.PairSecretStore
import com.spatialbridge.core.store.TrustedPeerStore
import com.spatialbridge.core.transfer.SendPhase
import com.spatialbridge.core.transfer.TransferSender
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random

/** Exponential backoff with full jitter, like Swift's `RetryPolicy`. */
data class RetryPolicy(val initialDelayMillis: Long = 500, val maxDelayMillis: Long = 15_000, val multiplier: Double = 2.0) {
    /** Delay before attempt [attempt] (1-based); attempt 1 has none. */
    fun delayMillis(attempt: Int, jitter: Double = Random.nextDouble()): Long {
        if (attempt <= 1) return 0
        val base = initialDelayMillis * Math.pow(multiplier, (attempt - 2).toDouble())
        return (minOf(base, maxDelayMillis.toDouble()) * jitter.coerceIn(0.0, 1.0)).toLong()
    }
}

private fun LinkState.toConnectionState(): ConnectionStatus.State = when (this) {
    LinkState.Idle -> ConnectionStatus.State.IDLE
    LinkState.Discovering -> ConnectionStatus.State.DISCOVERING
    LinkState.Pairing -> ConnectionStatus.State.PAIRING
    LinkState.Authenticating -> ConnectionStatus.State.AUTHENTICATING
    LinkState.Connected -> ConnectionStatus.State.CONNECTED
    is LinkState.Reconnecting -> ConnectionStatus.State.RECONNECTING
    is LinkState.Disconnected -> ConnectionStatus.State.DISCONNECTED
}

/** Connection status of the link to the receiver. */
sealed interface LinkState {
    data object Idle : LinkState
    data object Discovering : LinkState
    data object Pairing : LinkState
    data object Authenticating : LinkState
    data object Connected : LinkState
    data class Reconnecting(val attempt: Int) : LinkState
    data class Disconnected(val reason: BridgeErrorCode?) : LinkState
}

data class LinkStatus(
    val state: LinkState = LinkState.Idle,
    val peerID: String? = null,
    val roundTripSeconds: Double? = null,
    val lastError: BridgeErrorCode? = null,
)

/**
 * Sender-side orchestration (Swift `SenderService`): discovery through a [PeerLocator], pairing, a
 * supervised session to the preferred receiver with backoff, and sending. A persistent E004 gets
 * three fast retries, then waits 30 s between attempts. Success is reported only on COMMITTED.
 */
class SenderService(
    private val identity: DeviceIdentity,
    private val device: DeviceInfo,
    private val pairSecrets: PairSecretStore,
    private val trustedPeerStore: TrustedPeerStore,
    private val locator: PeerLocator,
    private val limits: TransferLimits = TransferLimits.DEFAULT,
    private val retry: RetryPolicy = RetryPolicy(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    /** How long [send] waits for a session before failing. */
    private val sessionWaitMillis: Long = 10_000,
) : SenderFacade {
    private class ActiveSession(val peer: TrustedPeer, val channel: SessionChannel, val sender: TransferSender)

    private val _pairing = MutableStateFlow<PairingState>(PairingState.Idle)
    private val _transfer = MutableStateFlow<TransferState>(TransferState.Idle)
    private val _link = MutableStateFlow(LinkStatus())
    private val trusted = MutableStateFlow<List<TrustedPeer>>(emptyList())
    private val sessionFlow = MutableStateFlow<ActiveSession?>(null)

    override val pairing: StateFlow<PairingState> = _pairing.asStateFlow()

    override val trustedPeers: StateFlow<List<TrustedPeerInfo>> = trusted
        .map { list -> list.map { TrustedPeerInfo(it.peerID, it.displayName, it.platform) } }
        .stateIn(scope, SharingStarted.Eagerly, emptyList())

    override val discoveryError: StateFlow<BridgeErrorCode?> = locator.state
        .map { (it as? DiscoveryState.Waiting)?.code ?: (it as? DiscoveryState.Failed)?.code }
        .stateIn(scope, SharingStarted.Eagerly, null)

    override val connection: StateFlow<ConnectionStatus> = _link
        .map { ConnectionStatus(it.state.toConnectionState(), it.peerID, it.lastError) }
        .stateIn(scope, SharingStarted.Eagerly, ConnectionStatus())
    override val transfer: StateFlow<TransferState> = _transfer.asStateFlow()
    val link: StateFlow<LinkStatus> = _link.asStateFlow()

    override val peers: StateFlow<List<DiscoveredPeer>> = combine(locator.peers, trusted) { located, trust ->
        val trustedIDs = trust.map { it.peerID }.toSet()
        located.map {
            DiscoveredPeer(
                peerID = it.id,
                displayName = it.displayName,
                platform = it.platform,
                isTrusted = it.id in trustedIDs,
                pairingAvailable = ServiceRole.PAIRING in it.roles,
            )
        }
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    private val kicks = Channel<Unit>(Channel.CONFLATED)
    private val lifecycle = Mutex()
    private var supervisor: Job? = null
    private var watchers: List<Job> = emptyList()
    @Volatile private var preferredPeerID: String? = null
    @Volatile private var pairingDecision: CompletableDeferred<Boolean>? = null
    @Volatile private var sendJob: Job? = null
    @Volatile private var pairJob: Job? = null
    private val pairingLock = Mutex()

    // Lifecycle

    override fun startDiscovery() {
        scope.launch {
            lifecycle.withLock {
                if (supervisor != null) return@withLock
                refreshTrusted()
                locator.start()
                watchers = listOf(
                    scope.launch { locator.peers.collect { kick() } },
                    scope.launch { locator.state.collect { kick() } },
                )
                supervisor = scope.launch { supervise() }
            }
        }
    }

    override fun stopDiscovery() {
        scope.launch {
            lifecycle.withLock {
                supervisor?.cancel()
                supervisor = null
                watchers.forEach { it.cancel() }
                watchers = emptyList()
                locator.stop()
                sessionFlow.value?.channel?.close()
                sessionFlow.value = null
                _link.value = LinkStatus()
            }
        }
    }

    override fun setPreferredPeer(peerID: String?) {
        preferredPeerID = peerID
        kick()
    }

    /** Forces a reconnect attempt now ("Try again"). */
    fun reconnect() = kick()

    // Pairing

    override suspend fun pair(peerID: String) {
        if (!pairingLock.tryLock()) {
            _pairing.value = PairingState.Failed(BridgeErrorCode.PAIRING_REJECTED)
            return
        }
        pairJob = currentCoroutineContext()[Job]
        try {
            _pairing.value = PairingState.Connecting
            val located = locator.peers.value.firstOrNull { it.id == peerID }
            val endpoint = locator.endpoint(peerID, ServiceRole.PAIRING) ?: throw BridgeException(BridgeErrorCode.NO_PEER, "peer is not accepting pairing")
            _link.value = _link.value.copy(state = LinkState.Pairing)
            val outcome = PairingProtocol.runInitiator(
                SessionChannel(PeerConnector.openPairing(endpoint, limits), SessionChannel.Configuration.HANDSHAKE),
                identity,
                device,
            ) { prompt ->
                val decision = CompletableDeferred<Boolean>()
                pairingDecision = decision
                _pairing.value = PairingState.CompareCode(
                    peerName = prompt.peer.displayName,
                    code = PairingCrypto.formatForDisplay(prompt.shortAuthenticationString),
                    platform = prompt.peer.platform,
                    fingerprint = prompt.peerFingerprint,
                )
                try {
                    decision.await().also { if (it) _pairing.value = PairingState.WaitingForPeer }
                } finally {
                    pairingDecision = null
                }
            }
            val authenticated = outcome.trustedPeer.peerID
            // The TXT peer ID is only a hint; refuse if the authenticated key disagrees.
            val advertised = located?.id?.takeIf(PeerIDs::isValid)
            if (advertised != null && advertised != authenticated) {
                throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "advertised peer ID does not match paired key")
            }
            pairSecrets.store(outcome.preSharedKey, authenticated)
            trustedPeerStore.upsert(outcome.trustedPeer)
            locator.didPair(peerID, authenticated)
            refreshTrusted()
            sessionFlow.value?.takeIf { it.peer.peerID == authenticated }?.let {
                it.channel.close()
                sessionFlow.value = null
            }
            _pairing.value = PairingState.Paired(authenticated)
        } catch (e: CancellationException) {
            _pairing.value = PairingState.Failed(BridgeErrorCode.PAIRING_REJECTED)
            throw e
        } catch (e: Exception) {
            _pairing.value = PairingState.Failed(BridgeException.wrap(e, networkContext = true).code)
        } finally {
            pairJob = null
            pairingLock.unlock()
            kick()
        }
    }

    override fun cancelPairing() {
        val decision = pairingDecision
        if (decision != null) decision.complete(false) else pairJob?.cancel()
    }

    override fun answerPairing(codesMatch: Boolean) {
        pairingDecision?.complete(codesMatch)
    }

    override suspend fun unpair(peerID: String) {
        pairSecrets.remove(peerID)
        trustedPeerStore.remove(peerID)
        refreshTrusted()
        sessionFlow.value?.takeIf { it.peer.peerID == peerID }?.let {
            it.channel.close()
            sessionFlow.value = null
        }
        kick()
    }

    // Sending

    override suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String?) = send(file, gesture, peerID, UUID.randomUUID())

    override suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String?, transferID: UUID) {
        val job = scope.launch { performSend(file, gesture, peerID, transferID) }
        sendJob = job
        try {
            job.join()
        } catch (e: CancellationException) {
            job.cancel()
            throw e
        }
    }

    override fun cancelTransfer() {
        sendJob?.cancel()
    }

    private suspend fun performSend(file: OutgoingFile, gesture: ExitGesture?, peerID: String?, transferID: UUID) {
        _transfer.value = TransferState.Connecting
        try {
            if (peerID != null && peerID != preferredPeerID) setPreferredPeer(peerID)
            val session = awaitSession(peerID)
            _transfer.value = TransferState.Offering
            val committed = session.sender.send(File(file.path), file.sanitizedName, file.contentType, transferID, gesture) { progress ->
                when (progress.phase) {
                    SendPhase.STREAMING -> _transfer.value = TransferState.Sending(progress.bytesTransferred, progress.totalBytes)
                    SendPhase.VERIFYING -> _transfer.value = TransferState.AwaitingCommit
                    else -> Unit
                }
            }
            _transfer.value = TransferState.Committed(committed.savedFilename, committed.byteCount)
        } catch (e: CancellationException) {
            _transfer.value = TransferState.Failed(BridgeErrorCode.TRANSFER_CANCELED)
        } catch (e: Exception) {
            val code = BridgeException.wrap(e, networkContext = true).code
            _transfer.value = TransferState.Failed(code)
            if (code == BridgeErrorCode.PEER_LOST || code == BridgeErrorCode.TIMEOUT) kick()
        }
    }

    private suspend fun awaitSession(peerID: String?): ActiveSession {
        fun usable(s: ActiveSession?) = s != null && !s.channel.isClosed && (peerID == null || s.peer.peerID == peerID)
        sessionFlow.value?.let { if (usable(it)) return it }
        if (trusted.value.isEmpty()) refreshTrusted()
        if (trusted.value.isEmpty()) throw BridgeException(BridgeErrorCode.NO_PEER, "not paired")
        kick()
        return withTimeoutOrNull(sessionWaitMillis) { sessionFlow.first { usable(it) } }
            ?: throw BridgeException(_link.value.lastError.takeIf { it == BridgeErrorCode.AUTHENTICATION_FAILED || it == BridgeErrorCode.LOCAL_NETWORK_DENIED } ?: BridgeErrorCode.NO_PEER)
    }

    // Supervisor

    private fun kick() {
        kicks.trySend(Unit)
    }

    private suspend fun waitForKick(timeoutMillis: Long?) {
        if (timeoutMillis == null) kicks.receive() else withTimeoutOrNull(maxOf(1, timeoutMillis)) { kicks.receive() }
    }

    private suspend fun refreshTrusted() {
        trusted.value = trustedPeerStore.all()
    }

    private fun currentTarget(): TrustedPeer? {
        val all = trusted.value
        return preferredPeerID?.let { id -> all.firstOrNull { it.peerID == id } } ?: all.firstOrNull()
    }

    private fun publish(state: LinkState, peerID: String?, error: BridgeErrorCode?) {
        val current = _link.value
        _link.value = current.copy(
            state = state,
            peerID = peerID,
            lastError = error,
            roundTripSeconds = if (state == LinkState.Connected) current.roundTripSeconds else null,
        )
    }

    private suspend fun supervise() {
        var attempt = 0
        var authFailureStreak = 0
        var searchingSince: Long? = null
        while (scope.isActive) {
            val target = currentTarget()
            if (target == null) {
                sessionFlow.value?.channel?.close()
                sessionFlow.value = null
                publish(LinkState.Idle, null, null)
                waitForKick(null)
                continue
            }
            sessionFlow.value?.let { session ->
                if (session.peer.peerID == target.peerID && !session.channel.isClosed) {
                    waitForKick(null)
                    return@let
                }
                session.channel.close()
                sessionFlow.value = null
                attempt = maxOf(attempt, 1)
            }
            if (sessionFlow.value != null) continue

            val discovery = locator.state.value
            if (discovery is DiscoveryState.Waiting && discovery.code == BridgeErrorCode.LOCAL_NETWORK_DENIED) {
                publish(LinkState.Disconnected(BridgeErrorCode.LOCAL_NETWORK_DENIED), target.peerID, BridgeErrorCode.LOCAL_NETWORK_DENIED)
                waitForKick(10_000)
                continue
            }

            val endpoint = locator.endpoint(target.peerID, ServiceRole.SESSION)
            if (endpoint == null) {
                val since = searchingSince ?: System.nanoTime().also { searchingSince = it }
                val longSearch = (System.nanoTime() - since) / 1_000_000 > 8_000
                publish(
                    if (attempt == 0) LinkState.Discovering else LinkState.Reconnecting(attempt),
                    target.peerID,
                    if (longSearch) BridgeErrorCode.NO_PEER else _link.value.lastError,
                )
                waitForKick(2_000)
                continue
            }
            searchingSince = null

            publish(LinkState.Authenticating, target.peerID, null)
            try {
                val active = connect(target, endpoint)
                sessionFlow.value = active
                attempt = 0
                authFailureStreak = 0
                publish(LinkState.Connected, target.peerID, null)
                runCatching { trustedPeerStore.markSeen(target.peerID) }
                monitor(active)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val code = BridgeException.wrap(e, networkContext = true).code
                attempt += 1
                if (code == BridgeErrorCode.AUTHENTICATION_FAILED) authFailureStreak += 1
                if (code == BridgeErrorCode.AUTHENTICATION_FAILED && authFailureStreak > 3) {
                    // Right after pairing the receiver may still be re-keying its listener, so the first
                    // few failures retry quickly. A persistent failure usually means it no longer trusts us.
                    publish(LinkState.Disconnected(BridgeErrorCode.AUTHENTICATION_FAILED), target.peerID, BridgeErrorCode.AUTHENTICATION_FAILED)
                    waitForKick(30_000)
                } else {
                    publish(LinkState.Reconnecting(attempt), target.peerID, code)
                    waitForKick(maxOf(retry.delayMillis(attempt + 1), 250))
                }
            }
        }
    }

    private suspend fun connect(target: TrustedPeer, endpoint: Endpoint): ActiveSession {
        val psk = pairSecrets.psk(target.peerID) ?: throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "missing pair key")
        val transport = PeerConnector.openSession(endpoint, identity.peerID, psk, limits)
        val channel = SessionChannel(transport, SessionChannel.Configuration.SESSION)
        try {
            SessionAuthenticator.authenticateAsInitiator(channel, identity, device, target)
        } catch (e: Throwable) {
            channel.close(BridgeException.wrap(e, networkContext = true))
            throw e
        }
        return ActiveSession(target, channel, TransferSender(channel, identity.peerID, target.peerID, limits))
    }

    private fun monitor(active: ActiveSession) {
        scope.launch {
            val rtt = launch {
                active.channel.events.collect { event ->
                    if (event is SessionChannel.Event.RoundTripTime && sessionFlow.value === active) {
                        _link.value = _link.value.copy(roundTripSeconds = event.seconds)
                    }
                }
            }
            active.channel.awaitClosed()
            rtt.cancel()
            kick()
        }
    }

    companion object {
        /** Builds the HELLO device record for this Android device. */
        fun deviceInfo(identity: DeviceIdentity, displayName: String, model: String) =
            DeviceInfo.make(identity.peerID, displayName, com.spatialbridge.core.DevicePlatform.ANDROID, model)

        val SERVICE_TYPE = BridgeProtocol.SERVICE_TYPE
    }
}
