package com.spatialbridge.android

import com.spatialbridge.android.content.OfferNaming
import com.spatialbridge.android.diagnostics.Redaction
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.android.model.SpatialLayout
import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.core.Edge
import com.spatialbridge.core.gesture.GestureConfiguration
import com.spatialbridge.core.gesture.GesturePhase
import com.spatialbridge.core.gesture.GestureRejection
import com.spatialbridge.core.gesture.GestureSample
import com.spatialbridge.core.transfer.FilenameSanitizer
import com.spatialbridge.core.transfer.UtiMap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ContentAndGestureTest {
    @Test fun offerUsesCoreUtiMapExtensionThenMime() {
        assertEquals("public.jpeg", OfferNaming.offer("IMG.JPG", "application/octet-stream").contentType)
        assertEquals("public.png", OfferNaming.offer("noext", "image/png").contentType)
        assertEquals("public.data", OfferNaming.offer("archive.xyz", null).contentType)
        listOf("a.exe", "b", "c.sh").forEach { assertFalse(OfferNaming.offer(it, null).contentType.startsWith("dyn.")) }
    }

    @Test fun offeredNameIsExactlyTheSanitizerOutput() {
        // `a.JPG` offered as-is is rejected E006 by receivers; the sender lowercases the extension.
        val offer = OfferNaming.offer("Holiday Photo.JPG", "image/jpeg")
        assertEquals("Holiday Photo.jpg", offer.name)
        assertEquals(FilenameSanitizer.sanitize(offer.name), offer.name)
        assertTrue(FilenameSanitizer.isSafe(offer.name))
        assertFalse(FilenameSanitizer.isSafe("a.JPG"))
        listOf("../../etc/passwd", ".hidden.txt", "a:b.txt", "", "photo", "café.TXT", "é".repeat(200) + ".jpg", null).forEach { raw ->
            val o = OfferNaming.offer(raw, "image/jpeg")
            assertTrue("$raw", FilenameSanitizer.isSafe(o.name))
            assertTrue(o.name.encodeToByteArray().size <= 255)
        }
        assertEquals("passwd", OfferNaming.offer("../../etc/passwd", null).name)
        assertEquals("Item.jpeg", OfferNaming.offer(null, "image/jpeg").name)
        assertEquals("public.shell-script", OfferNaming.offer("run.SH", null).contentType)
        assertFalse(UtiMap.allowedOnMac("run.sh", "public.shell-script"))
    }

    @Test fun redactionHidesNames() {
        val redacted = Redaction.filename("Secret Plans.pdf")
        assertFalse(redacted.contains("Secret"))
        assertTrue(redacted.startsWith("***.pdf ("))
        assertEquals(redacted, Redaction.filename("Secret Plans.pdf"))
    }

    @Test fun manualEndpointParsing() {
        val both = ManualEndpoint.parse(" 10.0.2.2:52000/52001 ")!!
        assertEquals("10.0.2.2", both.host)
        assertEquals(52000, both.pairing!!.port)
        assertEquals(52001, both.session.port)
        val sessionOnly = ManualEndpoint.parse("10.0.2.2:52001")!!
        assertNull(sessionOnly.pairing)
        assertEquals(52001, sessionOnly.session.port)
        assertNull(ManualEndpoint.parse("10.0.2.2"))
        assertNull(ManualEndpoint.parse("host:0"))
        assertNull(ManualEndpoint.parse("host:1/2/3"))
        assertNull(ManualEndpoint.parse("host:1/"))
        assertNull(ManualEndpoint.parse("bad host:80"))
    }

    @Test fun calibrationMapping() {
        assertEquals(0.3, SpatialLayout(alignmentOffset = 0.1).mapNormalizedPosition(0.2), 1e-9)
        assertEquals(0.8, SpatialLayout(mirrored = true).mapNormalizedPosition(0.2), 1e-9)
        assertEquals(1.0, SpatialLayout(alignmentOffset = 0.5).mapNormalizedPosition(0.9), 1e-9)
    }

    private val wallClock = 1_700_000_000_000L
    private fun engine(edge: Edge = Edge.TOP) = GestureEngineFactory.core { wallClock }.create(GestureConfiguration(), 400.0, 800.0, edge)
    private fun s(x: Double, y: Double, uptimeMillis: Long) = GestureSample.fromDp(x.toFloat(), y.toFloat(), uptimeMillis)

    @Test fun fastFlickTowardTopFiresOnceWithWallClockStamp() {
        val e = engine()
        e.begin(s(200.0, 600.0, 5_000))
        var armed = false
        for (i in 1..10) armed = armed or e.update(s(200.0, 600.0 - i * 60.0, 5_000 + i * 10L)).didArm
        val gesture = e.end(s(100.0, 0.0, 5_110))
        assertTrue(armed)
        assertNotNull(gesture)
        assertEquals(Edge.TOP, gesture!!.edge)
        assertEquals(0.25, gesture.normalizedPosition, 1e-9)
        assertTrue(gesture.outwardVelocity > 500)
        assertEquals(wallClock, gesture.firedAtMillis)
        assertNull(e.end(s(100.0, 0.0, 5_120)))
    }

    @Test fun slowDragIsRejected() {
        val e = engine()
        e.begin(s(200.0, 600.0, 0))
        for (i in 1..29) e.update(s(200.0, 600.0 - i * 20.0, i * 100L))
        assertNull(e.end(s(200.0, 0.0, 3000)))
        assertEquals(GesturePhase.Rejected(GestureRejection.TOO_SLOW), e.phase)
    }

    @Test fun wrongDirectionIsRejected() {
        val e = engine(Edge.RIGHT)
        e.begin(s(200.0, 400.0, 0))
        for (i in 1..5) e.update(s(200.0 - i * 40.0, 400.0, i * 10L))
        assertNull(e.end(s(0.0, 400.0, 60)))
        assertEquals(GesturePhase.Rejected(GestureRejection.WRONG_DIRECTION), e.phase)
    }
}
