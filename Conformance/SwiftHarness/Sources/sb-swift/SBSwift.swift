import Foundation

@main
struct SBSwift {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        let args: Args
        do {
            args = try Args(argv)
        } catch let usage as UsageError {
            Out.log("\(usage.message)\n\(usageText)")
            exit(64)
        } catch {
            exit(64)
        }
        let code: Int32
        switch args.command {
        case "tls-echo": code = await TLSEcho.run(args)
        case "pair-initiate": code = await PairCommands.initiate(args)
        case "pair-respond": code = await PairCommands.respond(args)
        case "serve": code = await ServeCommand.run(args)
        case "send": code = await SendCommand.run(args)
        case "-h", "--help", "help":
            print(usageText)
            code = 0
        default:
            Out.log("unknown command\n\(usageText)")
            code = 64
        }
        exit(code)
    }

    static let usageText = """
    usage:
      sb-swift tls-echo --role server --listen HOST:PORT --identity ID --psk-hex HEX
      sb-swift tls-echo --role client --connect HOST:PORT --identity ID --psk-hex HEX
      sb-swift serve --state DIR --listen 127.0.0.1:0 --dest DIR --decision approve|reject [--session-port N] [--test-mode]
      sb-swift pair-initiate --state DIR --connect HOST:PORT --decision approve|reject [--test-mode]
      sb-swift pair-respond --state DIR --listen 127.0.0.1:0 --decision approve|reject [--test-mode]
      sb-swift send --state DIR --connect HOST:PORT --file PATH [--content-type UTI] [--transfer-id UUID]
                    [--peer PEERID] [--fault corrupt-chunk|out-of-order|cancel-mid|oversize-offer|unsafe-name|stall] [--test-mode]
    """
}
