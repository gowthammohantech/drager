package com.spatialbridge.android

import com.spatialbridge.android.platform.PeerMerger
import com.spatialbridge.android.platform.ServiceInstance
import com.spatialbridge.android.platform.ServiceRole
import com.spatialbridge.android.platform.TxtRecordParser
import com.spatialbridge.core.DevicePlatform
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TxtRecordsTest {
    private val pid = "0123456789abcdef0123456789abcdef"

    private fun attrs(vararg pairs: Pair<String, String?>): Map<String, ByteArray?> =
        pairs.associate { (k, v) -> k to v?.encodeToByteArray() }

    @Test fun parsesAllKeys() {
        val txt = TxtRecordParser.parse(attrs("pid" to pid, "name" to "Studio Mac", "plat" to "macOS", "pv" to "1", "role" to "pairing"))
        assertEquals(pid, txt.peerID)
        assertEquals("Studio Mac", txt.displayName)
        assertEquals(DevicePlatform.MACOS, txt.platform)
        assertEquals(1, txt.protocolVersion)
        assertEquals(ServiceRole.PAIRING, txt.role)
    }

    @Test fun rejectsInvalidPeerIDs() {
        listOf(
            pid.uppercase(), pid.dropLast(1), pid + "0", "g" + pid.drop(1), " $pid", "", "../../etc",
        ).forEach { bad -> assertNull(bad, TxtRecordParser.parse(attrs("pid" to bad)).peerID) }
        assertNull(TxtRecordParser.parse(attrs("pid" to null)).peerID)
        assertNull(TxtRecordParser.parse(mapOf("pid" to byteArrayOf(0xC3.toByte(), 0x28))).peerID)
    }

    @Test fun roleDefaultsToSession() {
        assertEquals(ServiceRole.SESSION, TxtRecordParser.parse(attrs("pid" to pid)).role)
        assertEquals(ServiceRole.SESSION, TxtRecordParser.parse(attrs("pid" to pid, "role" to "admin")).role)
        assertEquals(ServiceRole.SESSION, TxtRecordParser.parse(attrs("pid" to pid, "role" to "session")).role)
    }

    @Test fun keepsUnknownPlatformsAndDropsEmpty() {
        assertEquals(DevicePlatform("linux"), TxtRecordParser.parse(attrs("plat" to "linux")).platform)
        assertEquals(DevicePlatform.WINDOWS, TxtRecordParser.parse(attrs("plat" to "windows")).platform)
        assertNull(TxtRecordParser.parse(attrs("plat" to "")).platform)
    }

    @Test fun cleansDisplayNamesAndVersions() {
        val long = "x".repeat(100)
        assertEquals(64, TxtRecordParser.parse(attrs("name" to long)).displayName!!.length)
        assertEquals("AB", TxtRecordParser.parse(attrs("name" to "A\u0000B\n")).displayName)
        assertNull(TxtRecordParser.parse(attrs("name" to "   ")).displayName)
        assertNull(TxtRecordParser.parse(attrs("pv" to "one")).protocolVersion)
    }

    private fun instance(name: String, role: String, peer: String? = pid, display: String? = "Studio", port: Int = 5000) =
        ServiceInstance(name, "192.168.1.5", port, TxtRecordParser.parse(attrs("pid" to peer, "name" to display, "plat" to "windows", "pv" to "1", "role" to role)))

    @Test fun mergesSessionAndPairingByPid() {
        val merged = PeerMerger.merge(listOf(instance("Studio-pair", "pairing", port = 5001), instance("Studio", "session", port = 5000)), trusted = emptySet())
        assertEquals(1, merged.size)
        val peer = merged.single()
        assertEquals(pid, peer.peer.peerID)
        assertEquals("Studio", peer.peer.displayName)
        assertEquals(DevicePlatform.WINDOWS, peer.peer.platform)
        assertTrue(peer.peer.pairingAvailable)
        assertFalse(peer.peer.isTrusted)
        assertEquals(5000, peer.endpoints[ServiceRole.SESSION]!!.port)
        assertEquals(5001, peer.endpoints[ServiceRole.PAIRING]!!.port)
    }

    @Test fun trustComesFromStoreNotTxt() {
        val merged = PeerMerger.merge(listOf(instance("Studio", "session")), trusted = setOf(pid))
        assertTrue(merged.single().peer.isTrusted)
        assertFalse(merged.single().peer.pairingAvailable)
    }

    @Test fun dropsInstancesWithoutValidPidAndOwnAdvertisement() {
        val other = "fedcba9876543210fedcba9876543210"
        val merged = PeerMerger.merge(
            listOf(instance("Bad", "session", peer = "nope"), instance("Me", "session", peer = other), instance("Studio", "session")),
            trusted = emptySet(), excludePeerID = other,
        )
        assertEquals(listOf(pid), merged.map { it.peer.peerID })
    }

    @Test fun separatePeersStaySeparateAndSorted() {
        val other = "fedcba9876543210fedcba9876543210"
        val merged = PeerMerger.merge(listOf(instance("Z", "session", display = "zeta"), instance("A", "session", peer = other, display = "Alpha")), emptySet())
        assertEquals(listOf("Alpha", "zeta"), merged.map { it.peer.displayName })
    }

    @Test fun fallsBackToServiceNameAndIgnoresBadPorts() {
        val merged = PeerMerger.merge(listOf(instance("Office PC", "session", display = null, port = 0)), emptySet())
        assertEquals("Office PC", merged.single().peer.displayName)
        assertTrue(merged.single().endpoints.isEmpty())
    }
}
