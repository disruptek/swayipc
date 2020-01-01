version = "3.1.4"
author = "disruptek"
description = "IPC interface to sway (or i3) compositors"
license = "MIT"
requires "nim >= 0.20.0"
requires "nesm >= 0.4.5"
requires "cligen >= 0.9.40"

bin = @["swayipc"]

proc execCmd(cmd: string) =
  echo "execCmd:" & cmd
  exec cmd

proc execTest(test: string) =
  execCmd "nim c           -f -r " & test
  execCmd "nim c   -d:release -r " & test
  execCmd "nim c   -d:danger  -r " & test
  execCmd "nim cpp            -r " & test
  execCmd "nim cpp -d:danger  -r " & test
  when NimMajor >= 1 and NimMinor >= 1:
    execCmd "nim c   --gc:arc -r " & test
    execCmd "nim cpp --gc:arc -r " & test

task test, "run tests for travis":
  execTest("swayipc.nim --help")
