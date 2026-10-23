using System.Net;
using System.Security.Cryptography;
using SpatialBridge.Core;
using SpatialBridge.Core.Services;
using SpatialBridge.Core.Transfer;
using SpatialBridge.Platform.Windows.Security;
using SpatialBridge.Platform.Windows.Storage;

namespace SpatialBridge.Platform.Windows.Tests;

/// <summary>
/// Core's <see cref="ReceiverService"/> composed like the app (file trusted-peer store, a platform committer),
/// receiving from Core's <see cref="SenderClient"/> over loopback: pairing, TLS-PSK, session auth and a real commit.
/// The portable variant runs on every host; the Windows variant adds DPAPI, MoveFileEx, MotW and the hidden staging folder.
/// </summary>
public sealed class ReceiverIntegrationTests
{
    [Fact]
    public async Task PortableCommitOverLoopback()
    {
        await using var rig = new ReceiverRig(new PortableFileCommitter(), secrets: null);
        await rig.RunCommonScenarioAsync();
    }

    [WindowsFact]
    public async Task WindowsCommitOverLoopbackWithMotwAndHiddenStaging()
    {
        await using var rig = new ReceiverRig(new WindowsFileCommitter(), secrets: dir => new DpapiSecretStore(dir));
        var saved = await rig.RunCommonScenarioAsync();

        foreach (var path in saved)
        {
            Assert.True(MarkOfTheWeb.IsApplied(path), "Mark-of-the-Web missing");
        }
        Assert.True(File.GetAttributes(rig.StagingFolder).HasFlag(FileAttributes.Hidden), "staging folder is not hidden");

        // The identity seed survived in DPAPI: a second store over the same folder reads it back.
        Assert.NotNull(new DpapiSecretStore(rig.SecretsFolder).Read(BridgeProtocol.SecretKey.IdentitySeed));
    }

    private sealed class ReceiverRig : IAsyncDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "sb-win-it-" + Guid.NewGuid().ToString("N"));
        private readonly InMemorySecretStore _senderSecrets = new();
        private readonly InMemoryTrustedPeerStore _senderTrust = new();
        private readonly List<ReceiverEvent> _events = [];
        private readonly ReceiverService _receiver;
        private readonly SenderClient _sender;

        public ReceiverRig(IFileCommitter committer, Func<string, ISecretStore>? secrets)
        {
            Directory.CreateDirectory(Destination);
            var timeouts = new ProtocolTimeouts { Handshake = TimeSpan.FromSeconds(10), UserDecision = TimeSpan.FromSeconds(10) };
            _receiver = new ReceiverService(
                new ReceiverOptions
                {
                    DisplayName = "Integration PC",
                    ListenAddress = IPAddress.Loopback,
                    DestinationFolder = Destination,
                    Timeouts = timeouts,
                },
                secrets?.Invoke(SecretsFolder) ?? new InMemorySecretStore(),
                new FileTrustedPeerStore(Path.Combine(_root, "data", "trusted-peers.json")),
                new NullServiceAdvertiser(),
                committer);
            _receiver.PairingApprover = (prompt, _) => Task.FromResult(prompt.Code.Length == 6 && prompt.Code.All(char.IsAsciiDigit));
            _receiver.EventRaised += (_, e) =>
            {
                lock (_events)
                {
                    _events.Add(e);
                }
            };
            _sender = new SenderClient(_senderSecrets, _senderTrust, "Pixel", DevicePlatform.Android, "Pixel 9") { Timeouts = timeouts };
        }

        public string Destination => Path.Combine(_root, "Downloads");

        public string SecretsFolder => Path.Combine(_root, "data", "Secrets");

        public string StagingFolder => Path.Combine(Destination, StagingArea.DefaultFolderName);

        /// <summary>Pair, send a photo and a reserved-name file, and check what every host can check. Returns the saved paths.</summary>
        public async Task<string[]> RunCommonScenarioAsync()
        {
            await _receiver.SetAllowPairingAsync(true);
            await _receiver.SetAvailableAsync(true);
            await _sender.PairAsync("127.0.0.1", _receiver.PairingPort!.Value, (_, _) => Task.FromResult(true));
            // The initiator can finish a moment before the responder has stored trust.
            for (var i = 0; i < 100 && _receiver.TrustedPeers.Count == 0; i++)
            {
                await Task.Delay(20);
            }
            Assert.Single(_receiver.TrustedPeers);
            var peer = _senderTrust.All().Single();

            var photo = WriteSource("photo.jpeg", 300_000, out var photoSha);
            var photoResult = await _sender.SendFileAsync("127.0.0.1", _receiver.SessionPort!.Value, peer, new OutgoingFile(photo, "photo.jpeg", "public.jpeg"));
            Assert.Equal("photo.jpeg", photoResult.SavedFilename);

            var device = WriteSource("device.txt", 64, out var deviceSha);
            var reserved = await _sender.SendFileAsync("127.0.0.1", _receiver.SessionPort!.Value, peer, new OutgoingFile(device, "CON.txt", "public.plain-text"));
            Assert.Equal("CON_.txt", reserved.SavedFilename);

            var savedPhoto = Path.Combine(Destination, "photo.jpeg");
            var savedDevice = Path.Combine(Destination, "CON_.txt");
            Assert.Equal(photoSha, Sha(savedPhoto));
            Assert.Equal(deviceSha, Sha(savedDevice));
            Assert.Equal(["CON_.txt", "photo.jpeg"], Directory.GetFiles(Destination).Select(Path.GetFileName).Order(StringComparer.Ordinal));

            // Staging sits inside the destination (one volume) and is empty once both transfers committed.
            Assert.True(Directory.Exists(StagingFolder));
            Assert.Empty(Directory.EnumerateFileSystemEntries(StagingFolder));

            lock (_events)
            {
                var incoming = _events.OfType<ReceiverEvent.TransferIncoming>().First();
                Assert.Equal("photo.jpeg", incoming.Filename);
                Assert.Equal("public.jpeg", incoming.ContentType);
                var verifying = _events.FindIndex(e => e is ReceiverEvent.TransferVerifying v && v.TransferID == incoming.TransferID);
                var committed = _events.FindIndex(e => e is ReceiverEvent.TransferCommitted c && c.TransferID == incoming.TransferID && c.SavedPath == savedPhoto);
                Assert.InRange(verifying, 0, committed - 1); // verifying is never success; committed comes after it
                Assert.DoesNotContain(_events, e => e is ReceiverEvent.TransferFailed);
            }
            return [savedPhoto, savedDevice];
        }

        public async ValueTask DisposeAsync()
        {
            await _receiver.DisposeAsync();
            try
            {
                Directory.Delete(_root, recursive: true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        private string WriteSource(string name, int bytes, out string sha)
        {
            var path = Path.Combine(_root, "source-" + name);
            var data = RandomNumberGenerator.GetBytes(bytes);
            File.WriteAllBytes(path, data);
            sha = Convert.ToHexStringLower(SHA256.HashData(data));
            return path;
        }

        private static string Sha(string path) => Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
    }
}
