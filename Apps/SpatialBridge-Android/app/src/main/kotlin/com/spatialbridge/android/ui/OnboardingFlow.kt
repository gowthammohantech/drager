package com.spatialbridge.android.ui

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import androidx.core.content.ContextCompat
import com.spatialbridge.android.AppModel
import com.spatialbridge.android.model.displayName

private enum class Step { WELCOME, LOCAL_NETWORK, DISCOVER, CALIBRATION, TUTORIAL }

/** Welcome → Local network → Discover & pair → Calibration → Practice (PRD §3). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OnboardingFlow(model: AppModel) {
    var step by rememberSaveable { mutableStateOf(Step.WELCOME) }
    val back = { step = Step.entries[(step.ordinal - 1).coerceAtLeast(0)] }
    val advance = { step = Step.entries[(step.ordinal + 1).coerceAtMost(Step.entries.lastIndex)] }
    BackHandler(enabled = step != Step.WELCOME, onBack = back)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { StepIndicator(step.ordinal, Step.entries.size) },
                navigationIcon = {
                    if (step != Step.WELCOME) {
                        IconButton(onClick = back, modifier = Modifier.testTag("onboarding.back")) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (step) {
                Step.WELCOME -> WelcomeStep(advance)
                Step.LOCAL_NETWORK -> LocalNetworkStep(model) { advance() }
                Step.DISCOVER -> DiscoverStep(model, advance)
                Step.CALIBRATION -> Column(Modifier.fillMaxSize()) {
                    Text("Where is your phone?", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = Tokens.gutter))
                    Box(Modifier.weight(1f)) { CalibrationScreen(model) }
                    PrimaryButton("Continue", Modifier.padding(Tokens.gutter).testTag("onboarding.calibration.continue"), Icons.AutoMirrored.Filled.ArrowForward, onClick = advance)
                }
                Step.TUTORIAL -> TutorialStep(model) { model.completeOnboarding() }
            }
        }
    }
}

@Composable
private fun StepIndicator(current: Int, total: Int) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.semantics { contentDescription = "Step ${current + 1} of $total" },
    ) {
        repeat(total) { i ->
            Box(
                Modifier
                    .height(6.dp)
                    .width(if (i == current) 18.dp else 6.dp)
                    .background(
                        if (i <= current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                        RoundedCornerShape(3.dp),
                    ),
            )
        }
    }
}

@Composable
private fun WelcomeStep(onContinue: () -> Unit) {
    val transition = rememberInfiniteTransition(label = "float")
    val lift by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1600), RepeatMode.Reverse), label = "lift")
    Column(
        Modifier.fillMaxSize().padding(24.dp).testTag("onboarding.welcome"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Spacer(Modifier.weight(1f))
        Box(Modifier.height(240.dp).fillMaxWidth(), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Image, null, tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(56.dp).offset { IntOffset(0, ((-20 - 50 * lift) * density).roundToInt()) }.alpha(1f - 0.4f * lift))
            Icon(Icons.Filled.PhoneAndroid, null, modifier = Modifier.size(80.dp).offset(y = 70.dp))
        }
        Text("Throw files to your computer", style = MaterialTheme.typography.headlineMedium, textAlign = TextAlign.Center)
        Text(
            "Pick a photo or file, flick it toward your Mac or Windows PC, and watch it land. Everything stays on your local network.",
            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.weight(1f))
        PrimaryButton("Get Started", Modifier.testTag("onboarding.start"), Icons.AutoMirrored.Filled.ArrowForward, onClick = onContinue)
    }
}

/** Android 13+ gates local-network discovery behind Nearby devices (NEARBY_WIFI_DEVICES). */
object LocalNetworkPermission {
    val required: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
    const val NAME = "android.permission.NEARBY_WIFI_DEVICES"

    fun isGranted(context: Context): Boolean =
        !required || ContextCompat.checkSelfPermission(context, NAME) == PackageManager.PERMISSION_GRANTED
}

@Composable
private fun LocalNetworkStep(model: AppModel, onContinue: () -> Unit) {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        model.setLocalNetworkDenied(!granted)
        model.start()
        onContinue()
    }
    Column(Modifier.fillMaxSize().testTag("onboarding.localNetwork")) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Icon(Icons.Filled.Wifi, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(48.dp))
            Text("Find your computer on this network", style = MaterialTheme.typography.headlineSmall)
            ExplainerRow(Icons.Filled.WifiTethering, "Local network access",
                "Android will ask to let Drager find nearby devices on your Wi-Fi. It's needed to discover and connect to your computer. It is never used for location.")
            ExplainerRow(Icons.Filled.Lock, "Private and direct",
                "Files go straight to your computer over an encrypted connection. No account, no cloud, no upload.")
            ExplainerRow(Icons.Filled.Photo, "Only what you pick",
                "You choose each photo or file with the system picker. Drager never reads your whole library.")
            ExplainerRow(Icons.Filled.Check, "Pair once",
                "The first time, you'll compare a 6-digit code on both screens. After that your phone and computer recognise each other.")
        }
        PrimaryButton("Continue", Modifier.padding(24.dp).testTag("onboarding.localNetwork.continue"), Icons.AutoMirrored.Filled.ArrowForward) {
            if (LocalNetworkPermission.isGranted(context)) {
                model.setLocalNetworkDenied(false)
                model.start()
                onContinue()
            } else {
                launcher.launch(LocalNetworkPermission.NAME)
            }
        }
    }
}

@Composable
private fun DiscoverStep(model: AppModel, onContinue: () -> Unit) {
    val trusted by model.trustedPeers.collectAsState()
    Column(Modifier.fillMaxSize()) {
        Text("Pair with your computer", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = Tokens.gutter))
        Box(Modifier.weight(1f)) { DiscoveryScreen(model) }
        if (trusted.isNotEmpty()) {
            PrimaryButton("Continue", Modifier.padding(Tokens.gutter).testTag("onboarding.discover.continue"), Icons.AutoMirrored.Filled.ArrowForward, onClick = onContinue)
        }
    }
}

@Composable
private fun TutorialStep(model: AppModel, onFinish: () -> Unit) {
    var throws by remember { mutableIntStateOf(0) }
    val settings by model.settings.collectAsState()
    Column(Modifier.fillMaxSize().padding(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(if (throws > 0) "Nice throw!" else "Try a practice throw", style = MaterialTheme.typography.titleLarge)
        Text(
            "Drag the card and flick it toward the ${settings.layout.exitEdge.displayName.lowercase()} edge. Practice throws don't send anything.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
        PracticeCanvas(model, throws, Modifier.weight(1f).fillMaxWidth()) { throws++ }
        PrimaryButton(if (throws > 0) "Start Sending" else "Skip Practice", Modifier.testTag("onboarding.finish"), Icons.Filled.Check, onClick = onFinish)
    }
}
