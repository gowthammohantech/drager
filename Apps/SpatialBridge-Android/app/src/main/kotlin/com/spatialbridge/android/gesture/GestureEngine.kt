package com.spatialbridge.android.gesture

import com.spatialbridge.android.model.isHorizontal
import com.spatialbridge.core.Edge
import com.spatialbridge.core.ExitGesture
import kotlin.math.hypot

/** One touch sample in canvas coordinates: dp used as points, top-left origin. */
data class GestureSample(val x: Double, val y: Double, val timeMillis: Long)

/** Same knobs as Swift `GestureConfiguration`. */
data class GestureConfiguration(
    val edgeZoneInset: Double = 24.0,
    val minimumOutwardVelocity: Double = 500.0,
    val minimumTravel: Double = 60.0,
    val velocityWindowMillis: Long = 90,
    val minimumSamples: Int = 3,
    val sensitivity: Double = 1.0,
    val projectionMillis: Long = 80,
) {
    val effectiveVelocityThreshold: Double get() = minimumOutwardVelocity / sensitivity.coerceIn(0.5, 2.0)
}

enum class GestureRejection { NOT_IN_EDGE_ZONE, TOO_SLOW, TOO_SHORT, WRONG_DIRECTION, NOT_TRACKING }

sealed interface GesturePhase {
    data object Idle : GesturePhase
    data object Tracking : GesturePhase
    data object Armed : GesturePhase
    data object Fired : GesturePhase
    data object Cancelled : GesturePhase
    data class Rejected(val reason: GestureRejection) : GesturePhase
}

data class GestureUpdate(val phase: GesturePhase, val didArm: Boolean)

/**
 * Turns a drag into at most one [ExitGesture] (FR-103, FR-104, FR-108). The real implementation is
 * Lane K's port of `SpatialGestureEngine` (validated against `traces.json`); [PlaceholderGestureEngine]
 * is a simplified stand-in with the same contract.
 */
interface GestureEngine {
    val phase: GesturePhase
    fun begin(sample: GestureSample): GestureUpdate
    fun update(sample: GestureSample): GestureUpdate
    fun end(sample: GestureSample): ExitGesture?
    fun cancel()
}

fun interface GestureEngineFactory {
    fun create(configuration: GestureConfiguration, width: Double, height: Double, targetEdge: Edge): GestureEngine
}

class PlaceholderGestureEngine(
    private val configuration: GestureConfiguration,
    private val width: Double,
    private val height: Double,
    private val targetEdge: Edge,
) : GestureEngine {
    override var phase: GesturePhase = GesturePhase.Idle
        private set
    private val samples = ArrayDeque<GestureSample>()
    private var latest: GestureSample? = null
    private var travel = 0.0
    private var fired = false

    override fun begin(sample: GestureSample): GestureUpdate {
        samples.clear(); travel = 0.0; fired = false
        phase = GesturePhase.Tracking
        add(sample)
        return GestureUpdate(phase, false)
    }

    override fun update(sample: GestureSample): GestureUpdate {
        if (phase != GesturePhase.Tracking && phase != GesturePhase.Armed) return GestureUpdate(phase, false)
        add(sample)
        val inZone = distanceToEdge(sample) <= configuration.edgeZoneInset
        var didArm = false
        if (inZone && outwardVelocity() > 0) {
            if (phase == GesturePhase.Tracking) didArm = true
            phase = GesturePhase.Armed
        } else if (phase == GesturePhase.Armed && !inZone) {
            phase = GesturePhase.Tracking
        }
        return GestureUpdate(phase, didArm)
    }

    override fun end(sample: GestureSample): ExitGesture? {
        if ((phase != GesturePhase.Tracking && phase != GesturePhase.Armed) || fired) {
            if (phase == GesturePhase.Idle || phase == GesturePhase.Cancelled) {
                phase = GesturePhase.Rejected(GestureRejection.NOT_TRACKING)
            }
            return null
        }
        add(sample)
        val (vx, vy) = velocity()
        val outward = outward(vx, vy)
        val t = configuration.projectionMillis / 1000.0
        val projected = GestureSample(sample.x + vx * t, sample.y + vy * t, sample.timeMillis)
        val crosses = distanceToEdge(sample) <= configuration.edgeZoneInset || isBeyondEdge(projected)
        val rejection = when {
            outward <= 0 -> GestureRejection.WRONG_DIRECTION
            !crosses -> GestureRejection.NOT_IN_EDGE_ZONE
            travel < configuration.minimumTravel -> GestureRejection.TOO_SHORT
            outward < configuration.effectiveVelocityThreshold -> GestureRejection.TOO_SLOW
            else -> null
        }
        if (rejection != null) {
            phase = GesturePhase.Rejected(rejection)
            return null
        }
        fired = true
        phase = GesturePhase.Fired
        return ExitGesture(targetEdge, normalizedPosition(sample), outward, travel, sample.timeMillis)
    }

    override fun cancel() {
        samples.clear(); travel = 0.0; latest = null
        phase = GesturePhase.Cancelled
    }

    private fun add(sample: GestureSample) {
        latest?.let { travel += hypot(sample.x - it.x, sample.y - it.y) }
        latest = sample
        samples.addLast(sample)
        while (samples.size > configuration.minimumSamples &&
            sample.timeMillis - samples.first().timeMillis > configuration.velocityWindowMillis
        ) samples.removeFirst()
    }

    /** Points per second over the window; zero until enough samples arrived. */
    private fun velocity(): Pair<Double, Double> {
        if (samples.size < 2) return 0.0 to 0.0
        val first = samples.first()
        val last = samples.last()
        val dt = (last.timeMillis - first.timeMillis) / 1000.0
        if (dt <= 0) return 0.0 to 0.0
        return (last.x - first.x) / dt to (last.y - first.y) / dt
    }

    private fun outwardVelocity(): Double = velocity().let { (vx, vy) -> outward(vx, vy) }

    private fun outward(vx: Double, vy: Double): Double = when (targetEdge) {
        Edge.TOP -> -vy
        Edge.BOTTOM -> vy
        Edge.LEFT -> -vx
        Edge.RIGHT -> vx
    }

    private fun distanceToEdge(s: GestureSample): Double = when (targetEdge) {
        Edge.TOP -> maxOf(0.0, s.y)
        Edge.BOTTOM -> maxOf(0.0, height - s.y)
        Edge.LEFT -> maxOf(0.0, s.x)
        Edge.RIGHT -> maxOf(0.0, width - s.x)
    }

    private fun isBeyondEdge(s: GestureSample): Boolean = when (targetEdge) {
        Edge.TOP -> s.y < 0
        Edge.BOTTOM -> s.y > height
        Edge.LEFT -> s.x < 0
        Edge.RIGHT -> s.x > width
    }

    /** Along-edge position 0…1 from the top-left origin. */
    private fun normalizedPosition(s: GestureSample): Double {
        val v = if (targetEdge.isHorizontal) {
            if (width > 0) s.x / width else 0.5
        } else {
            if (height > 0) s.y / height else 0.5
        }
        return v.coerceIn(0.0, 1.0)
    }

    companion object {
        val factory = GestureEngineFactory { c, w, h, e -> PlaceholderGestureEngine(c, w, h, e) }
    }
}
