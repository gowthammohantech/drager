package com.spatialbridge.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/** Platform values carried in HELLO and TXT `plat` (ADR-015). Unknown values are kept as-is. */
@JvmInline
value class DevicePlatform(val raw: String) {
    companion object {
        val IOS = DevicePlatform("iOS")
        val MACOS = DevicePlatform("macOS")
        val ANDROID = DevicePlatform("android")
        val WINDOWS = DevicePlatform("windows")
    }
}

/** A receiver found on the local network (merged from its session and pairing instances by `pid`). */
data class DiscoveredPeer(
    val peerID: String,
    val displayName: String,
    val platform: DevicePlatform?,
    val isTrusted: Boolean,
    val pairingAvailable: Boolean,
)

/** Wire error codes E001–E014 (BridgeError.Code). Never invent new ones. */
enum class BridgeErrorCode(val wire: String) {
    LOCAL_NETWORK_DENIED("E001"), NO_PEER("E002"), PAIRING_REJECTED("E003"), AUTHENTICATION_FAILED("E004"),
    PEER_LOST("E005"), UNSUPPORTED_FILE("E006"), SIZE_LIMIT("E007"), INSUFFICIENT_STORAGE("E008"),
    DESTINATION_PERMISSION_EXPIRED("E009"), HASH_MISMATCH("E010"), WRITE_FAILED("E011"),
    PROTOCOL_MISMATCH("E012"), TRANSFER_CANCELED("E013"), TIMEOUT("E014"),
}

/** Edge of the sender's screen a gesture leaves through (top-left origin). */
enum class Edge { TOP, BOTTOM, LEFT, RIGHT }

data class ExitGesture(
    val edge: Edge,
    val normalizedPosition: Double,
    val outwardVelocity: Double,
    val travelDistance: Double,
    val firedAtMillis: Long,
)

/** A file prepared for sending: already copied to app storage, name already sanitized. */
data class OutgoingFile(
    val path: String,
    val sanitizedName: String,
    val contentType: String,
    val byteCount: Long,
)

sealed interface TransferState {
    data object Idle : TransferState
    data object Connecting : TransferState
    data object Offering : TransferState
    data class Sending(val sentBytes: Long, val totalBytes: Long) : TransferState
    data object AwaitingCommit : TransferState

    /** Only reached after the receiver sent COMMITTED. */
    data class Committed(val savedFilename: String, val byteCount: Long) : TransferState
    data class Failed(val code: BridgeErrorCode) : TransferState
}

sealed interface PairingState {
    data object Idle : PairingState
    data object Connecting : PairingState

    /** Show [code] and ask the user whether it matches the receiver's screen. */
    data class CompareCode(
        val peerName: String,
        val code: String,
        val platform: DevicePlatform? = null,
        /** `ab12 cd34 ef56 7890`: the receiver's key fingerprint. */
        val fingerprint: String? = null,
    ) : PairingState
    data object WaitingForPeer : PairingState
    data class Paired(val peerID: String) : PairingState
    data class Failed(val code: BridgeErrorCode) : PairingState
}

/** A paired receiver, shown even while it is offline. */
data class TrustedPeerInfo(val peerID: String, val displayName: String, val platform: DevicePlatform)

/** Link to the preferred receiver. */
data class ConnectionStatus(
    val state: State = State.IDLE,
    val peerID: String? = null,
    val lastError: BridgeErrorCode? = null,
) {
    enum class State { IDLE, DISCOVERING, PAIRING, AUTHENTICATING, CONNECTED, RECONNECTING, DISCONNECTED }
}

private val idleTrusted = MutableStateFlow<List<TrustedPeerInfo>>(emptyList()).asStateFlow()
private val idleDiscoveryError = MutableStateFlow<BridgeErrorCode?>(null).asStateFlow()
private val idleConnection = MutableStateFlow(ConnectionStatus()).asStateFlow()

/**
 * Everything the Android UI needs from the protocol core. The app shell is built against a fake
 * implementation first (XP1 lane AU) and wired to the real SenderService in XP2a.
 */
interface SenderFacade {
    val peers: StateFlow<List<DiscoveredPeer>>
    val pairing: StateFlow<PairingState>
    val transfer: StateFlow<TransferState>

    fun startDiscovery()
    fun stopDiscovery()

    suspend fun pair(peerID: String)
    fun answerPairing(codesMatch: Boolean)

    suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String? = null)
    fun cancelTransfer()

    suspend fun unpair(peerID: String)
    fun setPreferredPeer(peerID: String?)

    // Additions for XP2a. Defaults keep older implementations (fakes) compiling.

    /** Paired receivers, including offline ones. */
    val trustedPeers: StateFlow<List<TrustedPeerInfo>> get() = idleTrusted

    /** E001 when local-network access is denied, other discovery failures, or null. */
    val discoveryError: StateFlow<BridgeErrorCode?> get() = idleDiscoveryError

    val connection: StateFlow<ConnectionStatus> get() = idleConnection

    /** Abandons a pairing in progress; the receiver is told it was rejected. */
    fun cancelPairing() = answerPairing(false)

    /**
     * Like [send] with an explicit transfer ID. A retry of the same user activation reuses the ID, so
     * a receiver that already committed it answers COMMITTED and saves no second copy.
     */
    suspend fun send(file: OutgoingFile, gesture: ExitGesture?, peerID: String?, transferID: UUID) = send(file, gesture, peerID)
}
