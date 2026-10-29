package com.spatialbridge.android.model

import com.spatialbridge.core.BridgeErrorCode

/** User-facing copy for wire error codes, mirroring `BridgeError.Code` in the Swift package. */
object ErrorCopy {
    fun message(code: BridgeErrorCode): String = when (code) {
        BridgeErrorCode.LOCAL_NETWORK_DENIED -> "Drager isn't allowed to use the local network."
        BridgeErrorCode.NO_PEER -> "No device was found nearby."
        BridgeErrorCode.PAIRING_REJECTED -> "Pairing was declined."
        BridgeErrorCode.AUTHENTICATION_FAILED -> "The device couldn't be verified."
        BridgeErrorCode.PEER_LOST -> "The connection to the other device was lost."
        BridgeErrorCode.UNSUPPORTED_FILE -> "This file type isn't supported."
        BridgeErrorCode.SIZE_LIMIT -> "This file is too large to send."
        BridgeErrorCode.INSUFFICIENT_STORAGE -> "There isn't enough free space on the receiving device."
        BridgeErrorCode.DESTINATION_PERMISSION_EXPIRED -> "Access to the destination folder has expired."
        BridgeErrorCode.HASH_MISMATCH -> "The file arrived damaged and was discarded."
        BridgeErrorCode.WRITE_FAILED -> "The receiving device couldn't save the file."
        BridgeErrorCode.PROTOCOL_MISMATCH -> "The other device is running an incompatible version."
        BridgeErrorCode.TRANSFER_CANCELED -> "The transfer was cancelled."
        BridgeErrorCode.TIMEOUT -> "The other device didn't respond in time."
    }

    fun recovery(code: BridgeErrorCode): String = when (code) {
        BridgeErrorCode.LOCAL_NETWORK_DENIED ->
            "Open Settings › Apps › Drager › Permissions and allow Nearby devices, then connect to Wi-Fi."
        BridgeErrorCode.NO_PEER ->
            "Make sure Drager is running on the computer, both devices are on the same Wi-Fi, and Availability is on."
        BridgeErrorCode.PAIRING_REJECTED -> "Try pairing again and confirm that the codes match on both devices."
        BridgeErrorCode.AUTHENTICATION_FAILED -> "Unpair the device on both sides and pair again."
        BridgeErrorCode.PEER_LOST -> "Check Wi-Fi on both devices and try again."
        BridgeErrorCode.UNSUPPORTED_FILE -> "Choose a different file."
        BridgeErrorCode.SIZE_LIMIT -> "Files up to 100 MB are supported in this version."
        BridgeErrorCode.INSUFFICIENT_STORAGE -> "Free up space on the computer or choose another destination folder."
        BridgeErrorCode.DESTINATION_PERMISSION_EXPIRED -> "Choose the destination folder again in Drager on the computer."
        BridgeErrorCode.HASH_MISMATCH -> "Try sending the file again."
        BridgeErrorCode.WRITE_FAILED -> "Check that the destination folder is writable and try again."
        BridgeErrorCode.PROTOCOL_MISMATCH -> "Update Drager on both devices."
        BridgeErrorCode.TRANSFER_CANCELED -> "Flick the file again to retry."
        BridgeErrorCode.TIMEOUT -> "Make sure the other device is awake and nearby, then try again."
    }

    /** Whether retrying the same operation can plausibly succeed without user action. */
    fun isRetryable(code: BridgeErrorCode): Boolean = when (code) {
        BridgeErrorCode.PEER_LOST, BridgeErrorCode.TIMEOUT, BridgeErrorCode.HASH_MISMATCH,
        BridgeErrorCode.WRITE_FAILED, BridgeErrorCode.NO_PEER -> true
        else -> false
    }
}
