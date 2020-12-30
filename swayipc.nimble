version = "3.1.8"
author = "disruptek"
description = "IPC interface to sway (or i3) compositors"
license = "MIT"
requires "nesm >= 0.4.5 & < 1.0.0"
requires "cligen >= 0.9.40 & < 2.0.0"

bin = @["swayipc"]

task test, "run unit testes":
  exec "swayipc --help"
