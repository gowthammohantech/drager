using SpatialBridge.Cli;
using SpatialBridge.Core;

try
{
    var parsed = new Args(args);
    return parsed.Command switch
    {
        "tls-echo" => await TlsEcho.RunAsync(parsed),
        "serve" => await ServeCommand.RunAsync(parsed),
        "pair-initiate" => await PairCommands.InitiateAsync(parsed),
        "pair-respond" => await PairCommands.RespondAsync(parsed),
        "send" => await SendCommand.RunAsync(parsed),
        "unpair" => UnpairCommand.Run(parsed),
        _ => throw new UsageException($"unknown command {parsed.Command}"),
    };
}
catch (UsageException usage)
{
    Out.Log(usage.Message);
    return 64;
}
catch (BridgeException ex)
{
    Out.Error(ex.Code);
    return ex.Code.ExitCode();
}
