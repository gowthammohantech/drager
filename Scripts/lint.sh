#!/usr/bin/env bash
# Formatting/lint gate. Tools are optional locally; CI installs them.
source "$(dirname "$0")/_common.sh"
cd "$REPO_ROOT"
status=0
if command -v swiftformat >/dev/null; then swiftformat --lint . || status=1; else echo "swiftformat not installed; skipping"; fi
if command -v swiftlint >/dev/null; then swiftlint lint --quiet || status=1; else echo "swiftlint not installed; skipping"; fi
# Platform-neutral packages must not import UI frameworks.
if grep -rnE '^\s*(public )?import (UIKit|AppKit|SwiftUI)' Packages/SpatialBridgeKit/Sources; then
  echo "error: UI framework imported in a platform-neutral package" >&2; status=1
fi
# Kotlin (Android) and C# (Windows) must not log filenames or secrets (AGENTS.md). Pragmatic,
# single-line check: a logging call whose line mentions filename/psk/seed/secret/preSharedKey.
# Allowed: the Redaction helpers themselves, values passed through `Redaction.`, `pskFingerprint`,
# and any line marked with a `lint:allow-log` comment (say why next to it).
LOG_CALLS='(\bLog\.(v|d|i|w|e|wtf)\(|\bprintln\(|\bprint\(|\bBridgeLog\.[a-z]+\(|\bTimber\.|\b[lL]ogger\.[a-zA-Z]+\(|\bOut\.[lL]og\(|Console\.(Error\.|Out\.)?Write(Line)?\(|\bDebug\.Write(Line)?\(|\bTrace\.(Write|TraceInformation|TraceWarning|TraceError)|(^|[^.A-Za-z])Log\(|\bLog\?\.Invoke\(|\.Log(Information|Warning|Error|Debug|Trace|Critical)\(|DiagnosticsLog[A-Za-z.]*\.Write\(|_diagnostics\.Write\()'
SENSITIVE='(file_?name|psk([^f]|$)|seed|secret|presharedkey)'
log_hits="$(grep -rnE "$LOG_CALLS" \
    --include='*.kt' --include='*.cs' \
    --exclude-dir=build --exclude-dir=bin --exclude-dir=obj --exclude-dir=test --exclude-dir=androidTest --exclude-dir=tests \
    --exclude='Redaction.kt' --exclude='Redaction.cs' \
    Apps/SpatialBridge-Android Apps/SpatialBridge-Windows 2>/dev/null \
  | grep -iE "^[^:]+:[0-9]+:.*$SENSITIVE" | grep -vE 'lint:allow-log|Redaction\.' || true)"
if [[ -n "$log_hits" ]]; then
  echo "$log_hits"
  echo "error: Kotlin/C# logging call mentions a filename or secret; redact it or mark it 'lint:allow-log'" >&2; status=1
fi
# Never commit signing material.
if git ls-files | grep -E '\.(p12|cer|mobileprovision|provisionprofile|p8)$'; then
  echo "error: signing material is tracked by git" >&2; status=1
fi
exit $status
