it's like swaymsg or i3ipc but, y'know, in nim

this is where we are right now:
```nim
import asyncdispatch
import i3ipc

let
  compositor = RunCommand.send("opacity 0.5")
  receipt = waitFor compositor.recv()
assert receipt.data == "[ { \"success\": true } ]"
```
