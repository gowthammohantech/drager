package com.spatialbridge.core.service

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.net.Endpoint
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** What an advertised service instance is for (TXT `role`). */
enum class ServiceRole(val wire: String) { SESSION("session"), PAIRING("pairing") }

/**
 * One receiver as discovery sees it, merged from its session and pairing instances by `pid`.
 * [id] is the advertised peer ID when present, otherwise a locator-specific key. TXT data is untrusted.
 */
data class LocatedPeer(
    val id: String,
    val displayName: String,
    val platform: DevicePlatform?,
    val roles: Set<ServiceRole>,
    val protocolVersion: Int? = null,
)

sealed interface DiscoveryState {
    data object Idle : DiscoveryState
    data object Browsing : DiscoveryState
    /** E001 when the OS denied local-network access. */
    data class Waiting(val code: BridgeErrorCode?) : DiscoveryState
    data class Failed(val code: BridgeErrorCode) : DiscoveryState
}

/** Finds receivers and their endpoints. The Android app implements it with NsdManager. */
interface PeerLocator {
    val peers: StateFlow<List<LocatedPeer>>
    val state: StateFlow<DiscoveryState>

    /** Where to connect for [role]; null if that instance is not currently visible. */
    fun endpoint(id: String, role: ServiceRole): Endpoint?

    fun start()
    fun stop()

    /** Called after a network change. */
    fun restart() {
        stop()
        start()
    }

    /** Called after pairing through [id] produced the authenticated [peerID] (lets manual entries re-key). */
    fun didPair(id: String, peerID: String) {}
}

/** Fixed endpoints: debug manual entry in the app, loopback in tests and the CLI. */
class ManualPeerLocator : PeerLocator {
    private data class Entry(val peer: LocatedPeer, val pairing: Endpoint?, val session: Endpoint?)

    private val entries = MutableStateFlow<Map<String, Entry>>(emptyMap())
    private val _peers = MutableStateFlow<List<LocatedPeer>>(emptyList())
    private val _state = MutableStateFlow<DiscoveryState>(DiscoveryState.Idle)
    override val peers: StateFlow<List<LocatedPeer>> = _peers.asStateFlow()
    override val state: StateFlow<DiscoveryState> = _state.asStateFlow()

    /** Adds or replaces an entry. [id] may be a real peer ID or any key such as `"manual:host:port"`. */
    fun add(id: String, displayName: String, pairing: Endpoint? = null, session: Endpoint? = null, platform: DevicePlatform? = null) {
        val roles = buildSet {
            if (pairing != null) add(ServiceRole.PAIRING)
            if (session != null) add(ServiceRole.SESSION)
        }
        entries.update { it + (id to Entry(LocatedPeer(id, displayName, platform, roles), pairing, session)) }
        publish()
    }

    fun remove(id: String) {
        entries.update { it - id }
        publish()
    }

    override fun endpoint(id: String, role: ServiceRole): Endpoint? = entries.value[id]?.let {
        if (role == ServiceRole.PAIRING) it.pairing else it.session
    }

    override fun start() {
        _state.value = DiscoveryState.Browsing
        publish()
    }

    override fun stop() {
        _state.value = DiscoveryState.Idle
    }

    override fun didPair(id: String, peerID: String) {
        if (id == peerID) return
        entries.update { current ->
            val entry = current[id] ?: return@update current
            current - id + (peerID to entry.copy(peer = entry.peer.copy(id = peerID)))
        }
        publish()
    }

    private fun publish() {
        _peers.value = entries.value.values.map { it.peer }
    }
}

/** One resolved DNS-SD instance (`_spatialbridge._tcp`), as the app's NsdManager reports it. TXT values are untrusted hints. */
data class ResolvedService(
    val instanceName: String,
    val role: ServiceRole,
    val endpoint: Endpoint,
    val peerID: String? = null,
    val displayName: String? = null,
    val platform: DevicePlatform? = null,
    val protocolVersion: Int? = null,
)

/**
 * A locator the app feeds from NSD: resolved instances are merged into one peer by TXT `pid`
 * (session + pairing instances), and manual endpoints bypass NSD entirely.
 */
class ResolvedPeerLocator(
    private val onStart: () -> Unit = {},
    private val onStop: () -> Unit = {},
) : PeerLocator {
    private val services = MutableStateFlow<Map<Pair<String, ServiceRole>, ResolvedService>>(emptyMap())
    private val manual = ManualPeerLocator()
    private val _peers = MutableStateFlow<List<LocatedPeer>>(emptyList())
    private val _state = MutableStateFlow<DiscoveryState>(DiscoveryState.Idle)
    override val peers: StateFlow<List<LocatedPeer>> = _peers.asStateFlow()
    override val state: StateFlow<DiscoveryState> = _state.asStateFlow()

    private fun key(service: ResolvedService) =
        service.peerID?.takeIf(com.spatialbridge.core.model.PeerIDs::isValid) ?: "nsd:${service.instanceName}"

    /** Replaces the whole resolved set. */
    fun submit(resolved: List<ResolvedService>) {
        services.value = resolved.associateBy { it.instanceName to it.role }
        publish()
    }

    fun upsert(service: ResolvedService) {
        services.update { it + ((service.instanceName to service.role) to service) }
        publish()
    }

    fun lost(instanceName: String) {
        services.update { current -> current.filterKeys { it.first != instanceName } }
        publish()
    }

    fun setState(state: DiscoveryState) {
        _state.value = state
    }

    /** A manual `host:port` entry (debug), independent of NSD. */
    fun addManual(id: String, displayName: String, pairing: Endpoint?, session: Endpoint?) {
        manual.add(id, displayName, pairing, session)
        publish()
    }

    fun removeManual(id: String) {
        manual.remove(id)
        publish()
    }

    override fun endpoint(id: String, role: ServiceRole): Endpoint? =
        services.value.values.firstOrNull { key(it) == id && it.role == role }?.endpoint ?: manual.endpoint(id, role)

    override fun start() {
        _state.value = DiscoveryState.Browsing
        onStart()
    }

    override fun stop() {
        onStop()
        services.value = emptyMap()
        _state.value = DiscoveryState.Idle
        publish()
    }

    override fun didPair(id: String, peerID: String) {
        manual.didPair(id, peerID)
        publish()
    }

    private fun publish() {
        val merged = services.value.values.groupBy(::key).map { (id, group) ->
            val primary = group.firstOrNull { it.role == ServiceRole.SESSION } ?: group.first()
            LocatedPeer(
                id = id,
                displayName = group.firstNotNullOfOrNull { it.displayName } ?: primary.instanceName,
                platform = group.firstNotNullOfOrNull { it.platform },
                roles = group.map { it.role }.toSet(),
                protocolVersion = group.firstNotNullOfOrNull { it.protocolVersion },
            )
        }
        val manualPeers = manual.peers.value.filter { m -> merged.none { it.id == m.id } }
        _peers.value = merged + manualPeers
    }
}
