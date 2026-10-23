package com.spatialbridge.cli

import kotlin.system.exitProcess

fun main(args: Array<String>) {
    System.err.println("sb-jvm: not implemented yet (${args.firstOrNull() ?: "no command"})")
    exitProcess(12)
}
