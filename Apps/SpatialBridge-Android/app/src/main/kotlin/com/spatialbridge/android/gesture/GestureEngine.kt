package com.spatialbridge.android.gesture

import com.spatialbridge.core.Edge
import com.spatialbridge.core.gesture.Bounds
import com.spatialbridge.core.gesture.GestureConfiguration
import com.spatialbridge.core.gesture.SpatialGestureEngine

/**
 * Creates core's [SpatialGestureEngine] (the port of Swift's engine, validated against `traces.json`)
 * for a throw surface of [width] × [height] dp. Touch samples carry uptime, so the fired-at stamp
 * comes from [wallClockMillis] instead of the sample timestamp.
 */
fun interface GestureEngineFactory {
    fun create(configuration: GestureConfiguration, width: Double, height: Double, targetEdge: Edge): SpatialGestureEngine

    companion object {
        fun core(wallClockMillis: () -> Long = System::currentTimeMillis) = GestureEngineFactory { configuration, width, height, edge ->
            SpatialGestureEngine(configuration, Bounds(0.0, 0.0, width, height), edge) { wallClockMillis() }
        }
    }
}
