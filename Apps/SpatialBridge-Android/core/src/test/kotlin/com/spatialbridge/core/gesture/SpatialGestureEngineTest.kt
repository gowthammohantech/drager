package com.spatialbridge.core.gesture

import com.spatialbridge.core.Edge
import com.spatialbridge.core.model.edgeOf
import com.spatialbridge.core.model.outwardNormal
import com.spatialbridge.core.vectors.Vectors
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.EnumSource
import java.io.File
import kotlin.math.abs

/** Same cases and expectations as Swift's `SpatialGestureEngineTests`. */
class SpatialGestureEngineTest {
    private val bounds = Bounds(0.0, 0.0, 390.0, 600.0)

    @Test
    fun `fast upward flick fires exactly once`() {
        val result = GestureTrace.linear("fast-up", bounds, Edge.TOP, 195.0, 400.0, 160.0, 10.0, 0.25, expectedToFire = true).run()
        val gesture = assertNotNull(result.gesture).let { result.gesture!! }
        assertEquals(Edge.TOP, gesture.edge)
        assertTrue(gesture.outwardVelocity > 1000)
        assertTrue(abs(gesture.normalizedPosition - 160.0 / 390.0) < 0.01)
        assertTrue(gesture.travelDistance > 380)
        assertEquals(GesturePhase.Fired, result.finalPhase)
        assertEquals(1, result.armedCount)
    }

    @Test
    fun `slow drag does not fire`() {
        val result = GestureTrace.linear("slow-up", bounds, Edge.TOP, 195.0, 300.0, 195.0, 10.0, 2.0, expectedToFire = false).run()
        assertNull(result.gesture)
        assertEquals(GesturePhase.Rejected(GestureRejection.TOO_SLOW), result.finalPhase)
    }

    @Test
    fun `fast flick far from the edge does not fire`() {
        val result = GestureTrace.linear("mid-flick", bounds, Edge.TOP, 195.0, 500.0, 195.0, 300.0, 0.15, expectedToFire = false).run()
        assertNull(result.gesture)
        assertEquals(GesturePhase.Rejected(GestureRejection.NOT_IN_EDGE_ZONE), result.finalPhase)
    }

    @Test
    fun `short travel is rejected`() {
        val result = GestureTrace.linear("short", bounds, Edge.TOP, 195.0, 40.0, 195.0, 5.0, 0.05, expectedToFire = false).run()
        assertNull(result.gesture)
        assertEquals(GesturePhase.Rejected(GestureRejection.TOO_SHORT), result.finalPhase)
    }

    @Test
    fun `wrong direction is rejected`() {
        val result = GestureTrace.linear("down", bounds, Edge.TOP, 195.0, 100.0, 195.0, 590.0, 0.2, expectedToFire = false).run()
        assertEquals(GesturePhase.Rejected(GestureRejection.WRONG_DIRECTION), result.finalPhase)
    }

    @ParameterizedTest
    @EnumSource(Edge::class)
    fun `each edge uses its own axis`(edge: Edge) {
        val (tx, ty) = when (edge) {
            Edge.TOP -> 100.0 to 5.0
            Edge.BOTTOM -> 100.0 to 595.0
            Edge.LEFT -> 5.0 to 150.0
            Edge.RIGHT -> 385.0 to 150.0
        }
        val gesture = GestureTrace.linear("edge", bounds, edge, 195.0, 300.0, tx, ty, 0.2, expectedToFire = true).run().gesture!!
        assertEquals(edge, gesture.edge)
        val expected = if (edge == Edge.TOP || edge == Edge.BOTTOM) 100.0 / 390.0 else 150.0 / 600.0
        assertTrue(abs(gesture.normalizedPosition - expected) < 0.01)
    }

    @Test
    fun `ending twice never fires twice`() {
        val engine = SpatialGestureEngine(bounds = bounds, targetEdge = Edge.TOP)
        engine.begin(GestureSample(195.0, 400.0, 1.0))
        for (i in 1..20) engine.update(GestureSample(195.0, 400.0 - i * 20, 1.0 + i * 0.01))
        assertNotNull(engine.end(GestureSample(195.0, 2.0, 1.21)))
        assertNull(engine.end(GestureSample(195.0, 2.0, 1.22)))
        assertEquals(GesturePhase.Fired, engine.phase)
    }

    @Test
    fun `cancel resets state`() {
        val engine = SpatialGestureEngine(bounds = bounds, targetEdge = Edge.TOP)
        engine.begin(GestureSample(195.0, 400.0, 0.0))
        engine.update(GestureSample(195.0, 20.0, 0.1))
        assertEquals(GesturePhase.Armed, engine.phase)
        engine.cancel()
        assertEquals(GesturePhase.Cancelled, engine.phase)
        assertNull(engine.end(GestureSample(195.0, 2.0, 0.15)))
    }

    @Test
    fun `arming and disarming`() {
        val engine = SpatialGestureEngine(bounds = bounds, targetEdge = Edge.TOP)
        engine.begin(GestureSample(195.0, 200.0, 0.0))
        val a = engine.update(GestureSample(195.0, 100.0, 0.05))
        assertTrue(a.phase == GesturePhase.Tracking && !a.didArm)
        val b = engine.update(GestureSample(195.0, 20.0, 0.10))
        assertTrue(b.phase == GesturePhase.Armed && b.didArm)
        val c = engine.update(GestureSample(195.0, 15.0, 0.12))
        assertTrue(c.phase == GesturePhase.Armed && !c.didArm)
        val d = engine.update(GestureSample(195.0, 80.0, 0.20))
        assertEquals(GesturePhase.Tracking, d.phase)
    }

    @Test
    fun `sensitivity lowers the threshold`() {
        val borderline = GestureTrace.linear("borderline", bounds, Edge.TOP, 195.0, 200.0, 195.0, 10.0, 0.5, expectedToFire = false)
        assertNull(borderline.run(GestureConfiguration(sensitivity = 1.0)).gesture)
        assertNotNull(borderline.run(GestureConfiguration(sensitivity = 2.0)).gesture)
        assertEquals(2.0, GestureConfiguration(sensitivity = 5.0).effectiveSensitivity)
    }

    @TestFactory
    fun `fixture traces behave as recorded`(): List<DynamicTest> {
        val file = File(Vectors.repoRoot, "Packages/SpatialBridgeKit/Tests/Unit/BridgeGestureTests/Fixtures/traces.json")
        val traces = Json.parseToJsonElement(file.readText()).jsonArray.map { element ->
            val o = element.jsonObject
            val (origin, size) = o.getValue("bounds").jsonArray.map { p -> p.jsonArray.map { it.jsonPrimitive.double } }
            GestureTrace(
                name = o.getValue("name").jsonPrimitive.content,
                bounds = Bounds(origin[0], origin[1], size[0], size[1]),
                targetEdge = edgeOf(o.getValue("targetEdge").jsonPrimitive.content)!!,
                samples = o.getValue("samples").jsonArray.map {
                    val s = it.jsonObject
                    GestureSample(s.getValue("x").jsonPrimitive.double, s.getValue("y").jsonPrimitive.double, s.getValue("timestamp").jsonPrimitive.double)
                },
                expectedToFire = o.getValue("expectedToFire").jsonPrimitive.boolean,
            )
        }
        assertTrue(traces.size >= 3)
        return traces.map { trace -> DynamicTest.dynamicTest(trace.name) { assertEquals(trace.expectedToFire, trace.run().gesture != null) } }
    }

    @Test
    fun `least squares recovers constant velocity`() {
        val estimator = VelocityEstimator(0.1, 3)
        for (i in 0 until 10) {
            val t = i * 0.01
            estimator.add(GestureSample(10 + 300 * t, 50 - 900 * t, t))
        }
        val v = estimator.velocity
        assertTrue(abs(v.dx - 300) < 1e-6)
        assertTrue(abs(v.dy + 900) < 1e-6)
        assertTrue(abs(v.component(Edge.TOP.outwardNormal) - 900) < 1e-6)
    }

    @Test
    fun `window drops stale samples and keeps two`() {
        val estimator = VelocityEstimator(0.05, 3)
        estimator.add(GestureSample(0.0, 0.0, 0.0))
        estimator.add(GestureSample(0.0, 0.0, 0.01))
        estimator.add(GestureSample(100.0, 0.0, 1.0))
        estimator.add(GestureSample(200.0, 0.0, 1.01))
        assertEquals(2, estimator.sampleCount)
        assertTrue(abs(estimator.velocity.dx - 10_000) < 1e-6)
    }

    @Test
    fun `degenerate inputs give zero velocity`() {
        val estimator = VelocityEstimator(0.1, 3)
        assertEquals(Velocity.ZERO, estimator.velocity)
        estimator.add(GestureSample(1.0, 1.0, 5.0))
        assertEquals(Velocity.ZERO, estimator.velocity)
        estimator.add(GestureSample(9.0, 9.0, 4.0))
        assertEquals(1, estimator.sampleCount)
        assertFalse(estimator.sampleCount > 1)
    }
}
