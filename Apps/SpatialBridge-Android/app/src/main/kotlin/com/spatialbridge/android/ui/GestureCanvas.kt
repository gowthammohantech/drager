package com.spatialbridge.android.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.VectorConverter
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.gesture.GestureEngineFactory
import com.spatialbridge.core.gesture.GestureConfiguration
import com.spatialbridge.core.gesture.GesturePhase
import com.spatialbridge.core.gesture.GestureRejection
import com.spatialbridge.core.gesture.GestureSample
import com.spatialbridge.android.model.displayName
import com.spatialbridge.android.model.isHorizontal
import com.spatialbridge.core.Edge
import com.spatialbridge.core.ExitGesture
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Drives core's `SpatialGestureEngine` from Compose `pointerInput` (FR-103, FR-104). Positions are converted to dp
 * and passed as points with a top-left origin. The card follows the finger; entering the edge zone
 * while moving outward arms the gesture (glow + haptic); a qualifying release fires exactly once per
 * drag (FR-108). Everything else springs back.
 */
@Composable
fun ThrowSurface(
    edge: Edge,
    configuration: GestureConfiguration,
    engines: GestureEngineFactory,
    enabled: Boolean,
    onFire: (ExitGesture) -> Unit,
    modifier: Modifier = Modifier,
    card: @Composable () -> Unit,
) {
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val offset = remember { Animatable(Offset.Zero, Offset.VectorConverter) }
    var armed by remember { mutableStateOf(false) }
    var flying by remember { mutableStateOf(false) }
    var rejection by remember { mutableStateOf<GestureRejection?>(null) }
    val currentOnFire by rememberUpdatedState(onFire)
    val currentEnabled by rememberUpdatedState(enabled)

    BoxWithConstraints(modifier.clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.surfaceContainer)) {
        val widthPx = constraints.maxWidth.toFloat()
        val heightPx = constraints.maxHeight.toFloat()
        EdgeGlow(edge, armed)
        Box(
            Modifier
                .fillMaxSize()
                .testTag("throw.canvas")
                .pointerInput(edge, configuration, widthPx, heightPx) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        if (!currentEnabled) return@awaitEachGesture
                        fun sample(p: Offset, t: Long) = with(density) { GestureSample.fromDp(p.x.toDp().value, p.y.toDp().value, t) }
                        val engine = engines.create(
                            configuration,
                            with(density) { widthPx.toDp().value.toDouble() },
                            with(density) { heightPx.toDp().value.toDouble() },
                            edge,
                        )
                        engine.begin(sample(down.position, down.uptimeMillis))
                        flying = false
                        rejection = null
                        var drag = Offset.Zero
                        var last = down
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            last = change
                            if (!change.pressed) break
                            drag += change.positionChange()
                            change.consume()
                            scope.launch { offset.snapTo(drag) }
                            val update = engine.update(sample(change.position, change.uptimeMillis))
                            if (update.didArm) haptics.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
                            armed = update.phase == GesturePhase.Armed
                        }
                        armed = false
                        val gesture = if (last.pressed) {
                            engine.cancel(); null
                        } else {
                            engine.end(sample(last.position, last.uptimeMillis))
                        }
                        if (gesture != null) {
                            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                            flying = true
                            currentOnFire(gesture)
                            scope.launch {
                                val outward = when (edge) {
                                    Edge.TOP -> Offset(drag.x, -heightPx)
                                    Edge.BOTTOM -> Offset(drag.x, heightPx)
                                    Edge.LEFT -> Offset(-widthPx, drag.y)
                                    Edge.RIGHT -> Offset(widthPx, drag.y)
                                }
                                offset.animateTo(outward, tween(320))
                                delay(380)
                                offset.snapTo(Offset.Zero)
                                flying = false
                            }
                        } else {
                            val phase = engine.phase
                            if (phase is GesturePhase.Rejected && phase.reason != GestureRejection.NOT_IN_EDGE_ZONE) {
                                rejection = phase.reason
                                haptics.performHapticFeedback(HapticFeedbackType.Reject)
                            }
                            scope.launch { offset.animateTo(Offset.Zero, spring()) }
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            val scale by animateFloatAsState(if (flying) 0.6f else if (armed) 0.92f else 1f, label = "scale")
            val alpha by animateFloatAsState(if (flying) 0f else 1f, tween(320), label = "alpha")
            Box(
                Modifier.graphicsLayer {
                    translationX = offset.value.x
                    translationY = offset.value.y
                    scaleX = scale
                    scaleY = scale
                    this.alpha = alpha
                    shadowElevation = if (armed) 18f else 6f
                },
            ) { card() }
        }
        rejection?.let { reason ->
            LaunchedEffect(reason) { delay(2500); rejection = null }
            Text(
                hint(reason, edge),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(8.dp)
                    .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(50))
                    .padding(horizontal = 12.dp, vertical = 4.dp)
                    .testTag("throw.hint"),
            )
        }
    }
}

private fun hint(reason: GestureRejection, edge: Edge) = when (reason) {
    GestureRejection.TOO_SLOW -> "Flick a little faster"
    GestureRejection.TOO_SHORT -> "Drag a little further"
    GestureRejection.WRONG_DIRECTION -> "Flick toward the ${edge.displayName.lowercase()} edge"
    GestureRejection.NOT_IN_EDGE_ZONE, GestureRejection.NOT_TRACKING -> "Throw toward the glowing edge"
}

/** Glowing band on the exit edge; brighter and wider when armed. */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.EdgeGlow(edge: Edge, armed: Boolean) {
    val thickness by animateDpAsState(if (armed) 64.dp else 28.dp, tween(200), label = "glow")
    val color = MaterialTheme.colorScheme.primary.copy(alpha = if (armed) 0.55f else 0.18f)
    val brush = when (edge) {
        Edge.TOP -> Brush.verticalGradient(listOf(color, Color.Transparent))
        Edge.BOTTOM -> Brush.verticalGradient(listOf(Color.Transparent, color))
        Edge.LEFT -> Brush.horizontalGradient(listOf(color, Color.Transparent))
        Edge.RIGHT -> Brush.horizontalGradient(listOf(Color.Transparent, color))
    }
    val align = when (edge) {
        Edge.TOP -> Alignment.TopCenter
        Edge.BOTTOM -> Alignment.BottomCenter
        Edge.LEFT -> Alignment.CenterStart
        Edge.RIGHT -> Alignment.CenterEnd
    }
    val size = if (edge.isHorizontal) Modifier.fillMaxWidth().height(thickness) else Modifier.fillMaxHeight().width(thickness)
    Box(Modifier.align(align).then(size).background(brush).testTag(if (armed) "throw.glow.armed" else "throw.glow"))
}

/** Onboarding practice: same engine, nothing is sent. */
@Composable
fun PracticeCanvas(model: AppModel, throws: Int, modifier: Modifier = Modifier, onFire: () -> Unit) {
    val settings by model.settings.collectAsStateWithLifecycle()
    ThrowSurface(
        edge = settings.layout.exitEdge,
        configuration = model.gestureConfiguration,
        engines = model.gestureEngines,
        enabled = true,
        onFire = { onFire() },
        modifier = modifier.semantics {
            contentDescription = "Practice card"
            customActions = listOf(CustomAccessibilityAction("Practice throw") { onFire(); true })
        }.testTag("practice.canvas"),
    ) {
        Box(
            Modifier.size(width = 150.dp, height = 190.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(20.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Filled.Photo, null, tint = MaterialTheme.colorScheme.onPrimary, modifier = Modifier.size(40.dp))
                Text(if (throws == 0) "Throw me" else "Thrown $throws×", color = MaterialTheme.colorScheme.onPrimary, style = MaterialTheme.typography.titleMedium)
            }
        }
    }
}
