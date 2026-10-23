namespace SpatialBridge.Core.Tests;

/// <summary>A TimeProvider whose clock moves only when told (timers are not simulated).</summary>
internal sealed class ManualTime(DateTimeOffset start) : TimeProvider
{
    private DateTimeOffset _now = start;

    public override DateTimeOffset GetUtcNow() => _now;

    public void Advance(TimeSpan by) => _now += by;
}
