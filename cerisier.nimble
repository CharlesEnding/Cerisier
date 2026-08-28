version       = "0.1.0"
author        = "Christian"
description   = "Extensible agent orchestrator for a local llama.cpp server"
license       = "MIT"
srcDir        = "src"
bin           = @["server/cerisier_server", "agentcli/cerisier_agent"]
binDir        = "bin"

requires "nim >= 2.0.0"
requires "prologue >= 0.6.0"
requires "websocketx >= 0.1.0"
requires "db_connector >= 0.1.0"
