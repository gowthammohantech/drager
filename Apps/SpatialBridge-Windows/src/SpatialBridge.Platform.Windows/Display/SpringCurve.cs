namespace SpatialBridge.Platform.Windows.Display;

/// <summary>
/// A damped spring from 0 to 1, parameterised like SwiftUI's <c>.spring(response:dampingFraction:)</c>
/// so the Windows card moves like the Mac's. The Mac uses
/// <c>response = 0.42 − 0.12 × intensity</c>, <c>dampingFraction = 0.72</c>.
/// </summary>
public readonly record struct SpringCurve(double Response, double DampingFraction)
{
    public static SpringCurve ForIntensity(double intensity) =>
        new(0.42 - (0.12 * Math.Clamp(intensity, 0, 1)), 0.72);

    /// <summary>The Mac's "saved" pop.</summary>
    public static SpringCurve Settle => new(0.3, 0.8);

    private double Omega => 2 * Math.PI / Math.Max(Response, 0.01);

    /// <summary>Progress at <paramref name="seconds"/>; may overshoot 1 slightly when underdamped.</summary>
    public double Value(double seconds)
    {
        if (seconds <= 0)
        {
            return 0;
        }
        var omega = Omega;
        var zeta = Math.Max(DampingFraction, 0);
        if (zeta >= 1)
        {
            return 1 - (Math.Exp(-omega * seconds) * (1 + (omega * seconds)));
        }
        var damped = omega * Math.Sqrt(1 - (zeta * zeta));
        var decay = Math.Exp(-zeta * omega * seconds);
        return 1 - (decay * (Math.Cos(damped * seconds) + (zeta * omega / damped * Math.Sin(damped * seconds))));
    }

    /// <summary>Time after which the curve stays within <paramref name="epsilon"/> of 1.</summary>
    public double SettleTime(double epsilon = 0.001)
    {
        var omega = Omega;
        var zeta = Math.Clamp(DampingFraction, 0.05, 1);
        if (zeta >= 1)
        {
            return 10 / omega;
        }
        var damped = omega * Math.Sqrt(1 - (zeta * zeta));
        var amplitude = Math.Sqrt(1 + Math.Pow(zeta * omega / damped, 2));
        return Math.Log(amplitude / epsilon) / (zeta * omega);
    }
}
