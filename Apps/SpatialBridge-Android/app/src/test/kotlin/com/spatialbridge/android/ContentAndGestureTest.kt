package com.spatialbridge.android

import com.spatialbridge.android.content.PlaceholderFilenameRules
import com.spatialbridge.android.content.PlaceholderUtiResolver
import com.spatialbridge.android.diagnostics.Redaction
import com.spatialbridge.android.gesture.GestureConfiguration
import com.spatialbridge.android.gesture.GesturePhase
import com.spatialbridge.android.gesture.GestureRejection
import com.spatialbridge.android.gesture.GestureSample
import com.spatialbridge.android.gesture.PlaceholderGestureEngine
import com.spatialbridge.android.model.SpatialLayout
import com.spatialbridge.android.platform.ManualEndpoint
import com.spatialbridge.core.Edge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ContentAndGestureTest {
    @Test fun utiResolutionPrefersExtensionThenMime() {
        val r = PlaceholderUtiResolver
        assertEquals("public.jpeg", r.resolve("IMG.JPG", "application/octet-stream"))
        assertEquals("public.png", r.resolve("noext", "image/png"))
        assertEquals("public.image", r.resolve("noext", "image/x-weird"))
        assertEquals("public.data", r.resolve("archive.xyz", null))
        listOf("a.exe", "b", "c.sh").forEach { assertFalse(r.resolve(it, null).startsWith("dyn.")) }
    }

    @Test fun filenameRulesMatchSwiftBehaviour() {
        val rules = PlaceholderFilenameRules(PlaceholderUtiResolver)
        assertEquals("passwd", rules.sanitize("../../etc/passwd"))
        assertEquals("hidden.txt", rules.sanitize(".hidden.txt"))
        assertEquals("ab.txt", rules.sanitize("a:b.txt"))
        assertEquals("Received file", rules.sanitize(""))
        assertEquals("photo.jpeg", rules.sanitize("photo", "public.jpeg"))
        assertEquals("café.txt", rules.sanitize("café.txt"))
        val long = rules.sanitize("é".repeat(200) + ".jpg")
        assertTrue(long.encodeToByteArray().size <= 255)
        assertTrue(long.endsWith(".jpg"))
    }

    @Test fun redactionHidesNames() {
        val redacted = Redaction.filename("Secret Plans.pdf")
        assertFalse(redacted.contains("Secret"))
        assertTrue(redacted.startsWith("***.pdf ("))
        assertEquals(redacted, Redaction.filename("Secret Plans.pdf"))
    }

    @Test fun manualEndpointParsing() {
        assertEquals(52000, ManualEndpoint.parse("10.0.2.2:52000")!!.port)
        assertNull(ManualEndpoint.parse("10.0.2.2"))
        assertNull(ManualEndpoint.parse("host:0"))
        assertNull(ManualEndpoint.parse("bad host:80"))
    }

    @Test fun calibrationMapping() {
        assertEquals(0.3, SpatialLayout(alignmentOffset = 0.1).mapNormalizedPosition(0.2), 1e-9)
        assertEquals(0.8, SpatialLayout(mirrored = true).mapNormalizedPosition(0.2), 1e-9)
        assertEquals(1.0, SpatialLayout(alignmentOffset = 0.5).mapNormalizedPosition(0.9), 1e-9)
    }

    private fun engine(edge: Edge = Edge.TOP) = PlaceholderGestureEngine(GestureConfiguration(), 400.0, 800.0, edge)

    @Test fun fastFlickTowardTopFiresOnce() {
        val e = engine()
        e.begin(GestureSample(200.0, 600.0, 0))
        var armed = false
        for (i in 1..10) armed = armed or e.update(GestureSample(200.0, 600.0 - i * 60.0, i * 10L)).didArm
        val gesture = e.end(GestureSample(100.0, 0.0, 110))
        assertTrue(armed)
        assertNotNull(gesture)
        assertEquals(Edge.TOP, gesture!!.edge)
        assertEquals(0.25, gesture.normalizedPosition, 1e-9)
        assertTrue(gesture.outwardVelocity > 500)
        assertNull(e.end(GestureSample(100.0, 0.0, 120)))
    }

    @Test fun slowDragIsRejected() {
        val e = engine()
        e.begin(GestureSample(200.0, 600.0, 0))
        for (i in 1..30) e.update(GestureSample(200.0, 600.0 - i * 20.0, i * 100L))
        assertNull(e.end(GestureSample(200.0, 0.0, 3100)))
        assertEquals(GesturePhase.Rejected(GestureRejection.TOO_SLOW), e.phase)
    }

    @Test fun wrongDirectionIsRejected() {
        val e = engine(Edge.RIGHT)
        e.begin(GestureSample(200.0, 400.0, 0))
        for (i in 1..5) e.update(GestureSample(200.0 - i * 40.0, 400.0, i * 10L))
        assertNull(e.end(GestureSample(0.0, 400.0, 60)))
        assertEquals(GesturePhase.Rejected(GestureRejection.WRONG_DIRECTION), e.phase)
    }
}
