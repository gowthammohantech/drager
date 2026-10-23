using System.Diagnostics;
using System.Globalization;

namespace SpatialBridge.Core.Tests.Fuzz;

/// <summary>
/// Deterministic, seeded fuzz loop that runs in the normal test suite (no extra tooling).
/// <list type="bullet">
/// <item><c>SB_FUZZ_ITERATIONS</c> sets the iterations per target (default <see cref="DefaultIterations"/>, sized for CI;
/// run locally with <c>SB_FUZZ_ITERATIONS=20000</c>).</item>
/// <item><c>SB_FUZZ_SEED</c> changes the base seed. Each iteration has its own <see cref="Random"/>, so a failure names the
/// exact input to replay.</item>
/// <item>Every input must finish within <see cref="MaxCaseMilliseconds"/> (bounded time).</item>
/// </list>
/// </summary>
internal static class FuzzRunner
{
    public const int DefaultIterations = 2_000;
    public const long MaxCaseMilliseconds = 2_000;

    public static int Iterations { get; } =
        int.TryParse(Environment.GetEnvironmentVariable("SB_FUZZ_ITERATIONS"), NumberStyles.None, CultureInfo.InvariantCulture, out var n) && n > 0
            ? n
            : DefaultIterations;

    public static int Seed { get; } =
        int.TryParse(Environment.GetEnvironmentVariable("SB_FUZZ_SEED"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var s) ? s : 0x5BF022;

    public static int Run(string target, Action<Random, int> body, int? count = null, Action<string>? log = null)
    {
        var iterations = count ?? Iterations;
        var baseSeed = Seed ^ StableHash(target);
        long slowest = 0;
        for (var i = 0; i < iterations; i++)
        {
#pragma warning disable CA5394 // Deterministic test input, not security.
            var rng = new Random(unchecked(baseSeed + (i * 0x2545F491)));
#pragma warning restore CA5394
            var watch = Stopwatch.StartNew();
            try
            {
                body(rng, i);
            }
            catch (Exception ex)
            {
                throw new Xunit.Sdk.XunitException($"fuzz {target} failed at iteration {i} (SB_FUZZ_SEED={Seed}): {ex}");
            }
            var ms = watch.ElapsedMilliseconds;
            slowest = Math.Max(slowest, ms);
            if (ms > MaxCaseMilliseconds) throw new Xunit.Sdk.XunitException($"fuzz {target} iteration {i} took {ms} ms (> {MaxCaseMilliseconds})");
        }
        var line = $"fuzz {target}: {iterations} iterations, slowest case {slowest} ms";
        log?.Invoke(line);
        Console.WriteLine(line);
        return iterations;
    }

    public static byte[] Bytes(Random rng, int max)
    {
#pragma warning disable CA5394
        var b = new byte[rng.Next(max + 1)];
        rng.NextBytes(b);
#pragma warning restore CA5394
        return b;
    }

#pragma warning disable CA5394
    public static T Pick<T>(Random rng, IReadOnlyList<T> items) => items[rng.Next(items.Count)];
#pragma warning restore CA5394

    private static int StableHash(string s)
    {
        unchecked
        {
            var h = (int)2166136261;
            foreach (var c in s) h = (h ^ c) * 16777619;
            return h;
        }
    }
}
