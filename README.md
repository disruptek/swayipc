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

or

```nim
import asyncdispatch
from strutils import spaces

import i3ipc

proc dump(tree: TreeResult; indent=0) =
  echo indent.spaces, tree.id, " ", tree.`type`
  for n in tree.nodes:
    n.dump(indent + 2)
  for n in tree.floating_nodes:
    n.dump(indent + 2)

let reply = waitFor getTree()
reply.tree.dump
```
yielding something like
```
1 root
  2147483647 output
    2147483646 workspace
  15 output
    26 workspace
      28 con
      39 con
      49 floating_con
    37 workspace
      36 con
    38 workspace
      34 con
    50 workspace
      6 floating_con
    7 workspace
      5 con
```
