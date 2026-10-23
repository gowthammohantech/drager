namespace SpatialBridge.Core.Tests;

/// <summary>Locates the repository root so tests can read Conformance/vectors in place.</summary>
internal static class RepoPaths
{
    public static string Root { get; } = Find();

    public static string Vectors(string file) => Path.Combine(Root, "Conformance", "vectors", file);

    private static string Find()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "Conformance")) && File.Exists(Path.Combine(dir.FullName, "AGENTS.md")))
            {
                return dir.FullName;
            }
        }
        throw new DirectoryNotFoundException("Repository root (with Conformance/ and AGENTS.md) not found.");
    }
}
