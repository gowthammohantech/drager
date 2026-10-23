# R8 rules for the release build.
#
# BouncyCastle: the app uses only the lightweight API (org.bouncycastle.tls with BcTlsCrypto, and
# org.bouncycastle.crypto). Nothing on that path is loaded by name: the only Class.forName /
# loadClass uses in bcprov 1.86 and bctls 1.86.2 are in the JCA/JSSE provider packages
# (jcajce, jce, jsse, pqc.jcajce, x509), which the app never registers or references. R8 removes
# those packages, including bctls' DummyX509TrustManager that lint flags as TrustAllX509TrustManager
# (checked in mapping.txt), and needs no -dontwarn for them. So no keep rules are required for
# correctness; the release TLS client is exercised by `app/e2e/emulator-e2e.sh --release`.

# Keep BouncyCastle TLS class names readable in crash reports (names only; shrinking still applies).
-keepnames class org.bouncycastle.tls.** { *; }
