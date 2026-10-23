package com.spatialbridge.core

import kotlinx.coroutines.flow.StateFlow

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
    data class CompareCode(val peerName: String, val code: String) : PairingState
    data object WaitingForPeer : PairingState
    data class Paired(val peerID: String) : PairingState
    data class Failed(val code: BridgeErrorCode) : PairingState
}

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
}
