using System.Globalization;

namespace SpatialBridge.Cli;

internal sealed class UsageException(string message) : Exception(message);

/// <summary><c>--key value</c> / <c>--flag</c> parser matching sb-swift's.</summary>
internal sealed class Args
{
    private static readonly HashSet<string> BooleanFlags = ["test-mode"];
    private readonly Dictionary<string, string> _values = [];
    private readonly HashSet<string> _flags = [];

    public Args(string[] argv)
    {
        if (argv.Length == 0) throw new UsageException("missing command");
        Command = argv[0];
        for (var i = 1; i < argv.Length;)
        {
            var arg = argv[i];
            if (!arg.StartsWith("--", StringComparison.Ordinal)) throw new UsageException("unexpected argument");
            var name = arg[2..];
            if (BooleanFlags.Contains(name))
            {
                _flags.Add(name);
                i++;
                continue;
            }
            if (i + 1 >= argv.Length) throw new UsageException($"missing value for --{name}");
            _values[name] = argv[i + 1];
            i += 2;
        }
    }

    public string Command { get; }

    public string? Optional(string name) => _values.GetValueOrDefault(name);

    public bool Flag(string name) => _flags.Contains(name);

    public string Required(string name) => _values.TryGetValue(name, out var v) ? v : throw new UsageException($"missing --{name}");

    public (string Host, int Port) HostPort(string name)
    {
        var raw = Required(name);
        var colon = raw.LastIndexOf(':');
        if (colon < 0 || !ushort.TryParse(raw.AsSpan(colon + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var port))
        {
            throw new UsageException($"--{name} must be HOST:PORT");
        }
        var host = raw[..colon];
        if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
        return (host, port);
    }
}
