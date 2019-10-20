# swayipc

It's like swaymsg (in sway) or i3ipc (in i3) but in native Nim.

You might find these docs for i3ipc useful: https://i3wm.org/docs/ipc.html

Also, here's [a useful example that repositions and resizes floating windows](https://github.com/disruptek/xs/blob/master/geometry.nim).

## Documentation
See [the documentation for the swayipc module](https://disruptek.github.io/swayipc/) as generated directly from the source.

## Usage
```nim
import asyncdispatch
from strutils import spaces

import swayipc

proc dump(tree: TreeReply; indent=0) =
  echo indent.spaces, tree.id, " ", tree.`type`
  for n in tree.nodes:
    n.dump(indent + 2)
  for n in tree.floating_nodes:
    n.dump(indent + 2)

var
  # connect to a compositor at an optional socket path
  compositor = waitFor newCompositor("../some/path")
  # synchronous tree retrieval
  reply = compositor.invoke(GetTree)

dump(reply.tree)
#1 root
#  2147483647 output
#    2147483646 workspace
#  15 output
#    26 workspace
#      28 con
#      39 con
#      49 floating_con
#    37 workspace
#      36 con
#    38 workspace
#      34 con
#    50 workspace
#      6 floating_con
#    7 workspace
#      5 con

# you can pass extra arguments for a command (as strings)
reply = waitFor GetBarConfig.invoke("status")
assert reply.bar.config.mode == "hide"

# you can invoke `send` to instantiate the compositor
block:
  var
    compositor = waitFor RunCommand.send("opacity 0.5")

    # receive the reply
    receipt = waitFor compositor.recv()

    # maybe you want to twiddle your own json?
    js = receipt.data

    # or, nah, that's silly...
    reply = receipt.reply

  # multiple command results are returned as a sequence
  assert reply.ran[0].success

# an example subscription iterator:
iterator focusChanges(): WindowEvent =
  let compositor = waitFor Subscribe.send("[\"window\"]")
  while true:
    let receipt = waitFor compositor.recv()
    if receipt.kind != EventReceipt:
      continue
    if receipt.event.kind != Window:
      continue
    if receipt.event.change != "focus":
      continue
    yield receipt.event.window

for window in focusChanges():
  echo window.name, " now has focus"
```

## License
MIT
