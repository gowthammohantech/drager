package com.spatialbridge.core.model

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.json.CanonicalJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.Base64
import java.util.UUID

class Hello(
    val protocolVersion: Int = BridgeProtocol.VERSION,
    val device: DeviceInfo,
    val capabilities: List<String> = DEFAULT_CAPABILITIES,
    val sessionNonce: ByteArray,
) {
    companion object {
        val DEFAULT_CAPABILITIES = listOf("transfer.v1", "gesture.v1")
        const val PAIRING_CAPABILITY = "pair.v1"
        const val SESSION_CAPABILITY = "session.v1"
    }
}

class PairRequest(val ephemeralPublicKey: ByteArray, val signingPublicKey: ByteArray, val displayName: String, val challenge: ByteArray)

class PairResponse(
    val ephemeralPublicKey: ByteArray,
    val signingPublicKey: ByteArray,
    val displayName: String,
    val challenge: ByteArray,
    val transcriptSignature: ByteArray,
)

class PairConfirm(val challengeResponse: ByteArray, val approvedPeerID: String, val transcriptSignature: ByteArray)

data class TransferOffer(
    val protocolVersion: Int = BridgeProtocol.VERSION,
    val transferID: UUID,
    val sourcePeerID: String,
    val targetPeerID: String,
    val filename: String,
    val contentType: String,
    val byteCount: Long,
    val sha256Hex: String,
    val gesture: ExitGesture?,
    val createdAtMillis: Long,
)

/** All control messages: `{"body":{...},"kind":KIND}` (PROTOCOL.md). */
sealed interface ControlMessage {
    val kind: Kind

    enum class Kind(val wire: String) {
        HELLO("HELLO"), PAIR_REQUEST("PAIR_REQUEST"), PAIR_RESPONSE("PAIR_RESPONSE"), PAIR_CONFIRM("PAIR_CONFIRM"),
        PAIR_REJECT("PAIR_REJECT"), SESSION_AUTH("SESSION_AUTH"), TRANSFER_OFFER("TRANSFER_OFFER"),
        TRANSFER_ACCEPT("TRANSFER_ACCEPT"), TRANSFER_REJECT("TRANSFER_REJECT"), PROGRESS("PROGRESS"),
        COMPLETE("COMPLETE"), COMMITTED("COMMITTED"), ERROR("ERROR"), CANCEL("CANCEL"), PING("PING"), PONG("PONG"),
    }

    /** Transfer this message refers to, if any. */
    val transferID: UUID? get() = null

    class HelloMsg(val hello: Hello) : ControlMessage { override val kind get() = Kind.HELLO }
    class PairRequestMsg(val request: PairRequest) : ControlMessage { override val kind get() = Kind.PAIR_REQUEST }
    class PairResponseMsg(val response: PairResponse) : ControlMessage { override val kind get() = Kind.PAIR_RESPONSE }
    class PairConfirmMsg(val confirm: PairConfirm) : ControlMessage { override val kind get() = Kind.PAIR_CONFIRM }
    data class PairReject(val reason: BridgeErrorCode = BridgeErrorCode.PAIRING_REJECTED) : ControlMessage {
        override val kind get() = Kind.PAIR_REJECT
    }
    class SessionAuth(val signature: ByteArray) : ControlMessage { override val kind get() = Kind.SESSION_AUTH }
    data class Offer(val offer: TransferOffer) : ControlMessage {
        override val kind get() = Kind.TRANSFER_OFFER
        override val transferID get() = offer.transferID
    }
    data class Accept(override val transferID: UUID, val chunkBytes: Int) : ControlMessage { override val kind get() = Kind.TRANSFER_ACCEPT }
    data class Reject(override val transferID: UUID, val reason: BridgeErrorCode, val message: String? = null) : ControlMessage {
        override val kind get() = Kind.TRANSFER_REJECT
    }
    data class Progress(override val transferID: UUID, val acknowledgedOffset: Long) : ControlMessage { override val kind get() = Kind.PROGRESS }
    data class Complete(override val transferID: UUID, val sha256Hex: String, val byteCount: Long) : ControlMessage {
        override val kind get() = Kind.COMPLETE
    }
    data class Committed(override val transferID: UUID, val savedFilename: String, val byteCount: Long) : ControlMessage {
        override val kind get() = Kind.COMMITTED
    }
    data class Error(override val transferID: UUID?, val code: BridgeErrorCode, val message: String? = null) : ControlMessage {
        override val kind get() = Kind.ERROR
    }
    data class Cancel(override val transferID: UUID, val reason: BridgeErrorCode = BridgeErrorCode.TRANSFER_CANCELED) : ControlMessage {
        override val kind get() = Kind.CANCEL
    }
    /** `sequence` is a UInt32 on the wire. */
    data class Ping(val sequence: Long, val sentAtMillis: Long = System.currentTimeMillis()) : ControlMessage { override val kind get() = Kind.PING }
    data class Pong(val sequence: Long, val sentAtMillis: Long) : ControlMessage { override val kind get() = Kind.PONG }
}

/** Canonical encoding and strict decoding of control messages (CONFORMANCE.md §1). */
object ControlMessageCoder {
    fun encode(message: ControlMessage): ByteArray = CanonicalJson.encode(toJson(message))

    /** Throws [BridgeException] E012 for anything Swift's decoder would refuse. */
    fun decode(bytes: ByteArray): ControlMessage = try {
        val root = CanonicalJson.parse(bytes) as? JsonObject ?: throw IllegalArgumentException("not an object")
        val kindName = root.string("kind")
        val kind = ControlMessage.Kind.entries.firstOrNull { it.wire == kindName } ?: throw IllegalArgumentException("unknown kind")
        fromJson(kind, root.obj("body"))
    } catch (e: BridgeException) {
        throw e
    } catch (e: Exception) {
        throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "undecodable control message", e)
    }

    fun uuidString(id: UUID): String = id.toString().uppercase()

    private val UUID_PATTERN = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

    fun parseUuid(text: String): UUID {
        require(UUID_PATTERN.matches(text)) { "bad UUID" }
        return UUID.fromString(text)
    }

    fun toJson(message: ControlMessage): Map<String, Any?> = mapOf("kind" to message.kind.wire, "body" to body(message))

    private fun body(message: ControlMessage): Map<String, Any?> = when (message) {
        is ControlMessage.HelloMsg -> message.hello.let {
            mapOf(
                "protocolVersion" to it.protocolVersion,
                "device" to deviceJson(it.device),
                "capabilities" to it.capabilities,
                "sessionNonce" to it.sessionNonce,
            )
        }
        is ControlMessage.PairRequestMsg -> message.request.let {
            mapOf("ephemeralPublicKey" to it.ephemeralPublicKey, "signingPublicKey" to it.signingPublicKey, "displayName" to it.displayName, "challenge" to it.challenge)
        }
        is ControlMessage.PairResponseMsg -> message.response.let {
            mapOf(
                "ephemeralPublicKey" to it.ephemeralPublicKey, "signingPublicKey" to it.signingPublicKey, "displayName" to it.displayName,
                "challenge" to it.challenge, "transcriptSignature" to it.transcriptSignature,
            )
        }
        is ControlMessage.PairConfirmMsg -> message.confirm.let {
            mapOf("challengeResponse" to it.challengeResponse, "approvedPeerID" to it.approvedPeerID, "transcriptSignature" to it.transcriptSignature)
        }
        is ControlMessage.PairReject -> mapOf("reason" to message.reason.wire)
        is ControlMessage.SessionAuth -> mapOf("signature" to message.signature)
        is ControlMessage.Offer -> message.offer.let {
            mapOf(
                "protocolVersion" to it.protocolVersion,
                "transferID" to uuidString(it.transferID),
                "sourcePeerID" to it.sourcePeerID,
                "targetPeerID" to it.targetPeerID,
                "filename" to it.filename,
                "contentType" to it.contentType,
                "byteCount" to it.byteCount,
                "sha256Hex" to it.sha256Hex,
                "gesture" to it.gesture?.let(::gestureJson),
                "createdAt" to it.createdAtMillis,
            )
        }
        is ControlMessage.Accept -> mapOf("transferID" to uuidString(message.transferID), "chunkBytes" to message.chunkBytes)
        is ControlMessage.Reject -> mapOf("transferID" to uuidString(message.transferID), "reason" to message.reason.wire, "message" to message.message)
        is ControlMessage.Progress -> mapOf("transferID" to uuidString(message.transferID), "acknowledgedOffset" to message.acknowledgedOffset)
        is ControlMessage.Complete -> mapOf("transferID" to uuidString(message.transferID), "sha256Hex" to message.sha256Hex, "byteCount" to message.byteCount)
        is ControlMessage.Committed -> mapOf("transferID" to uuidString(message.transferID), "savedFilename" to message.savedFilename, "byteCount" to message.byteCount)
        is ControlMessage.Error -> mapOf("transferID" to message.transferID?.let(::uuidString), "code" to message.code.wire, "message" to message.message)
        is ControlMessage.Cancel -> mapOf("transferID" to uuidString(message.transferID), "reason" to message.reason.wire)
        is ControlMessage.Ping -> mapOf("sequence" to message.sequence, "sentAt" to message.sentAtMillis)
        is ControlMessage.Pong -> mapOf("sequence" to message.sequence, "sentAt" to message.sentAtMillis)
    }

    private fun deviceJson(device: DeviceInfo) = mapOf(
        "peerID" to device.peerID,
        "displayName" to device.displayName,
        "platform" to device.platform.raw,
        "model" to device.model,
    )

    private fun gestureJson(gesture: ExitGesture) = mapOf(
        "edge" to gesture.edge.wire,
        "normalizedPosition" to gesture.normalizedPosition,
        "outwardVelocity" to gesture.outwardVelocity,
        "travelDistance" to gesture.travelDistance,
        "firedAt" to gesture.firedAtMillis,
    )

    private fun fromJson(kind: ControlMessage.Kind, b: JsonObject): ControlMessage = when (kind) {
        ControlMessage.Kind.HELLO -> ControlMessage.HelloMsg(
            Hello(
                protocolVersion = b.int("protocolVersion"),
                device = b.obj("device").let {
                    DeviceInfo(it.string("peerID"), it.string("displayName"), DevicePlatform(it.string("platform")), it.string("model"))
                },
                capabilities = b.array("capabilities").map { it.asString() },
                sessionNonce = b.bytes("sessionNonce"),
            ),
        )
        ControlMessage.Kind.PAIR_REQUEST -> ControlMessage.PairRequestMsg(
            PairRequest(b.bytes("ephemeralPublicKey"), b.bytes("signingPublicKey"), b.string("displayName"), b.bytes("challenge")),
        )
        ControlMessage.Kind.PAIR_RESPONSE -> ControlMessage.PairResponseMsg(
            PairResponse(b.bytes("ephemeralPublicKey"), b.bytes("signingPublicKey"), b.string("displayName"), b.bytes("challenge"), b.bytes("transcriptSignature")),
        )
        ControlMessage.Kind.PAIR_CONFIRM -> ControlMessage.PairConfirmMsg(
            PairConfirm(b.bytes("challengeResponse"), b.string("approvedPeerID"), b.bytes("transcriptSignature")),
        )
        ControlMessage.Kind.PAIR_REJECT -> ControlMessage.PairReject(b.code("reason"))
        ControlMessage.Kind.SESSION_AUTH -> ControlMessage.SessionAuth(b.bytes("signature"))
        ControlMessage.Kind.TRANSFER_OFFER -> ControlMessage.Offer(
            TransferOffer(
                protocolVersion = b.int("protocolVersion"),
                transferID = b.uuid("transferID"),
                sourcePeerID = b.string("sourcePeerID"),
                targetPeerID = b.string("targetPeerID"),
                filename = b.string("filename"),
                contentType = b.string("contentType"),
                byteCount = b.long("byteCount"),
                sha256Hex = b.string("sha256Hex"),
                gesture = b.optObj("gesture")?.let {
                    ExitGesture(
                        edge = edgeOf(it.string("edge")) ?: throw IllegalArgumentException("bad edge"),
                        normalizedPosition = it.double("normalizedPosition"),
                        outwardVelocity = it.double("outwardVelocity"),
                        travelDistance = it.double("travelDistance"),
                        firedAtMillis = it.long("firedAt"),
                    )
                },
                createdAtMillis = b.long("createdAt"),
            ),
        )
        ControlMessage.Kind.TRANSFER_ACCEPT -> ControlMessage.Accept(b.uuid("transferID"), b.int("chunkBytes"))
        ControlMessage.Kind.TRANSFER_REJECT -> ControlMessage.Reject(b.uuid("transferID"), b.code("reason"), b.optString("message"))
        ControlMessage.Kind.PROGRESS -> ControlMessage.Progress(b.uuid("transferID"), b.long("acknowledgedOffset"))
        ControlMessage.Kind.COMPLETE -> ControlMessage.Complete(b.uuid("transferID"), b.string("sha256Hex"), b.long("byteCount"))
        ControlMessage.Kind.COMMITTED -> ControlMessage.Committed(b.uuid("transferID"), b.string("savedFilename"), b.long("byteCount"))
        ControlMessage.Kind.ERROR -> ControlMessage.Error(b.optString("transferID")?.let(::parseUuid), b.code("code"), b.optString("message"))
        ControlMessage.Kind.CANCEL -> ControlMessage.Cancel(b.uuid("transferID"), b.code("reason"))
        ControlMessage.Kind.PING -> ControlMessage.Ping(b.uint32("sequence"), b.long("sentAt"))
        ControlMessage.Kind.PONG -> ControlMessage.Pong(b.uint32("sequence"), b.long("sentAt"))
    }

    // Strict field access: a missing key or wrong type fails the whole message, like Swift's Decodable.

    private fun JsonObject.field(key: String): JsonElement = this[key] ?: throw IllegalArgumentException("missing $key")
    private fun JsonObject.present(key: String): JsonElement? = this[key]?.takeUnless { it is JsonPrimitive && it.content == "null" && !it.isString }

    private fun JsonElement.asString(): String {
        val p = this as? JsonPrimitive ?: throw IllegalArgumentException("expected string")
        require(p.isString) { "expected string" }
        return p.content
    }

    private fun JsonElement.asInteger(): Long {
        val p = this as? JsonPrimitive ?: throw IllegalArgumentException("expected number")
        require(!p.isString) { "expected number" }
        return p.content.toLongOrNull() ?: p.content.toBigDecimal().longValueExact()
    }

    private fun JsonObject.obj(key: String) = field(key) as? JsonObject ?: throw IllegalArgumentException("expected object")
    private fun JsonObject.optObj(key: String) = present(key)?.let { it as? JsonObject ?: throw IllegalArgumentException("expected object") }
    private fun JsonObject.array(key: String) = field(key) as? JsonArray ?: throw IllegalArgumentException("expected array")
    private fun JsonObject.string(key: String) = field(key).asString()
    private fun JsonObject.optString(key: String) = present(key)?.asString()
    private fun JsonObject.long(key: String) = field(key).asInteger()
    private fun JsonObject.int(key: String): Int = Math.toIntExact(long(key))
    private fun JsonObject.uint32(key: String): Long = long(key).also { require(it in 0..0xFFFF_FFFFL) { "out of range" } }
    private fun JsonObject.uuid(key: String) = parseUuid(string(key))
    private fun JsonObject.bytes(key: String): ByteArray = Base64.getDecoder().decode(string(key))
    private fun JsonObject.code(key: String) = bridgeErrorCodeOf(string(key)) ?: throw IllegalArgumentException("unknown code")
    private fun JsonObject.double(key: String): Double {
        val p = field(key) as? JsonPrimitive ?: throw IllegalArgumentException("expected number")
        require(!p.isString) { "expected number" }
        // Like Swift's JSONDecoder: a number that overflows Double (1e309) is undecodable, not infinity.
        return p.content.toDouble().also { require(it.isFinite()) { "number out of range" } }
    }
}
