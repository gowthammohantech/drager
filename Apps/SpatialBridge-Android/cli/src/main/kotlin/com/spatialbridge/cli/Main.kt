package com.spatialbridge.cli

import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.exitCode
import kotlin.system.exitProcess

fun main(argv: Array<String>) {
    val code = try {
        val args = Args(argv.toList())
        when (args.command) {
            "tls-echo" -> TlsEcho.run(args)
            "pair-initiate" -> Pairing.initiate(args)
            "pair-respond" -> Pairing.respond(args)
            "serve" -> Serve.run(args)
            "send" -> Send.run(args)
            "unpair" -> Unpair.run(args)
            else -> throw UsageError("usage: sb-jvm tls-echo|serve|pair-initiate|pair-respond|send|unpair ...")
        }
    } catch (e: UsageError) {
        Out.log(e.message ?: "usage error")
        64
    } catch (e: BridgeException) {
        Out.error(e.code)
        e.code.exitCode
    }
    System.out.flush()
    exitProcess(code)
}
