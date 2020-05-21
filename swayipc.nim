import os
import json
import tables
import asyncdispatch
import asyncnet
import net
import streams
import logging
import strutils
import bitops

import cligen

when not defined(nimdoc):
  import nesm

export asyncdispatch

##
## Documentation for the i3 IPC interface:
##
## https://i3wm.org/docs/ipc.html
##

const
  magic = ['i', '3', '-', 'i', 'p', 'c'] ## prefix for msgs to/from server

# sway basically sends us complete containers sometimes...  parse them!
  SWAY = true

type
  ## these are the types of queries you may issue to the server
  ## (the integer values are significant!)
  Operation* = enum
    RunCommand = 0
    GetWorkspaces = 1
    Subscribe = 2
    GetOutputs = 3
    GetTree = 4
    GetMarks = 5
    GetBarConfig = 6
    GetVersion = 7
    GetBindingModes = 8
    GetConfig = 9
    SendTick = 10
    Sync = 11

  ## when you subscribe to events, these are the kinds of replies you get
  ## (the integer values are significant!)
  EventKind* = enum
    Workspace = 0
    Output = 1
    Mode = 2
    Window = 3
    BarConfigUpdate = 4
    Binding = 5
    Shutdown = 6
    Tick = 7

  WorkspaceEvent* = ref object
    change*: string
    old*: TreeReply
    current*: TreeReply

  WindowEvent* = ref object
    change*: string
    container*: TreeReply

  BarConfigUpdateEvent* = ref object
    id*: string
    hidden_state*: string
    mode*: string

  BindingEvent* = ref object
    change*: string
    binding*: BindingInfo

  OutputEvent* = ref object
    change*: string

  ModeEvent* = ref object
    change*: string
    pango_markup*: bool

  ShutdownEvent* = ref object
    change*: string

  TickEvent* = ref object
    first*: string
    payload*: JsonNode

  ## events arrive as a result of a subscription
  Event* = ref object
    case kind*: EventKind
    of Workspace:
      workspace*: WorkspaceEvent
    of Output:
      output*: OutputEvent
    of Mode:
      mode*: ModeEvent
    of Window:
      window*: WindowEvent
    of BarConfigUpdate:
      bar*: BarConfigUpdateEvent
    of Binding:
      binding*: BindingEvent
    of Shutdown:
      shutdown*: ShutdownEvent
    of Tick:
      tick*: TickEvent

  RunCommandReply* = object
    error*: string
    success*: bool
    parse_error*: bool

  WindowProperties* = ref object
    title*: string
    instance*: string
    class*: string
    window_role*: string
    transient_or*: string

  TreeReply* = ref object
    id*: int
    name*: string
    pid*: int
    app_id*: string # for sway
    `type`*: string
    border*: string
    current_border_width*: int
    layout*: string
    orientation*: string
    percent*: float
    rect*: Rect
    window_rect*: Rect
    deco_rect*: Rect
    geometry*: Rect
    window*: int
    window_properties*: WindowProperties
    urgent*: bool
    focused*: bool
    sticky*: bool
    fullscreen_mode*: int
    focus*: seq[int]
    nodes*: seq[TreeReply]
    floating_nodes*: seq[TreeReply]

  VersionReply = object
    major*: int
    minor*: int
    patch*: int
    human_readable*: string
    loaded_config_file_name*: string
    variant*: string # sway

  OneBarConfig = object
    id*: string
    mode*: string
    position*: string
    status_command*: string
    font*: string
    workspace_buttons*: bool
    binding_mode_indicator*: bool
    verbose*: bool
    colors*: Table[string, string]

  BarConfigReplyKind* = enum BarNames, OneBar
  BarConfigReply* = object
    case kind*: BarConfigReplyKind
    of BarNames:
      names*: seq[string]
    of OneBar:
      config*: OneBarConfig

  BindingInfo* = object
    command*: string
    input_code*: int
    symbol*: string
    input_type*: string
    # input_codes*: seq[...?] on sway
    event_state_mask*: seq[string]

  Rect* = object
    x*: int
    y*: int
    height*: int
    width*: int

  Compositor* = object
    socket*: AsyncSocket

when SWAY:
  type
    WorkspaceReply = TreeReply
    OutputsReply = TreeReply
else:
  type
    WorkspaceReply = object
      num: int
      name: string
      visible: bool
      focused: bool
      urgent: bool
      rect: Rect
      output: string

    OutputsReply = object
      name: string
      active: bool
      primary: bool
      current_workspace: string
      rect: Rect

type
  ## all messages fall into one of two categories
  ReceiptKind* = enum ReplyReceipt, EventReceipt

  ## all messages may thus be represented by their category and content
  Receipt* = object
    data*: string
    case kind*: ReceiptKind
    of ReplyReceipt:
      reply*: Reply
    of EventReceipt:
      event*: Event

  ## a reply arrives as a result of a query sent to the server
  Reply = ref object
    case kind*: Operation
    of RunCommand:
      ran*: seq[RunCommandReply]
    of GetVersion:
      version*: VersionReply
    of GetBarConfig:
      bar*: BarConfigReply
    of GetOutputs:
      outputs*: seq[OutputsReply]
    of GetWorkspaces:
      workspaces*: seq[WorkspaceReply]
    of Subscribe:
      subscribe*: bool
    of GetConfig:
      config*: string
    of GetMarks:
      marks*: seq[string]
    of GetTree:
      tree*: TreeReply
    of GetBindingModes:
      modes*: seq[string]
    of SendTick:
      tick*: bool
    of Sync:
      sync*: bool

template isFullscreen*(tree: TreeReply): bool =
  tree.fullscreen_mode == 1

proc newEvent*(kind: EventKind; payload: string): Event
proc newReply*(kind: Operation; payload: string): Reply

when defined(nimdoc):
  type
    Header = object
      magic*: array[magic.len, char]
      length*: int32
      mtype*: int32

    Envelope = object
      header: Header
      body: string
else:
  # nesm does the packing and unpacking of our messages and replies.
  # we separate out the header so that we can deserialize it alone,
  # in order to read the length of the subsequent envelope body...
  serializable:
    type
      Header = object
        magic*: array[magic.len, char]
        length*: int32
        mtype*: int32

      Envelope = object
        header: Header
        body: string as {size: {}.header.length}

# we'll use this to discriminate between message and event replies
type ReceiptType* = BitsRange[Header.mtype]

proc `$`*(event: Event): string =
  ## render an event
  result = "{" & $event.kind & " event}"

proc `$`*(reply: Reply): string =
  ## render a reply
  result = "{" & $reply.kind & " reply}"

proc newEnvelope(kind: Operation; data: string): Envelope =
  ## create a new envelope for sending over the socket
  result = Envelope(body: data)
  result.header = Header(magic: magic,
    length: cast[Header.length](data.len),
    mtype: cast[Header.mtype](kind))

proc newCompositor*(path = ""): Future[Compositor] {.async.} =
  ## connect to a compositor on the given path, defaulting to sway
  var
    addy: string
    sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  if path == "":
    addy = os.getEnv("SWAYSOCK")
  else:
    addy = path
  if addy.len == 0:
    raise newException(ValueError, "empty path to compositor socket")
  asyncCheck sock.connectUnix(addy)
  result = Compositor(socket: sock)

proc send*(kind: Operation; compositor: Compositor; payload = ""):
  Future[Compositor] {.async.} =
  ## given an operation, send a payload to a compositor; yield the compositor
  let
    msg = kind.newEnvelope($payload)
  var
    ss = newStringStream()

  when defined(nimdoc):
    ss.write(msg.body) # noqa 😞
  else:
    # serialize the whole message into the stream and send it
    serialize(msg, ss)

  debug "sending ", $payload

  asyncCheck compositor.socket.send(ss.data)
  result = compositor

proc send*(kind: Operation; payload = ""; socket = ""):
  Future[Compositor] {.async.} =
  ## given an operation, send a payload to a socket; yield the compositor
  let compositor = await newCompositor(socket)
  result = await kind.send(compositor, payload = payload)

proc recv*(comp: Compositor): Future[Receipt] {.async.} =
  ## receive a  message from the compositor asynchronously
  let
    # sadly, Header.sizeof will not match the following, and
    # i'm uncertain we can simply alter it by a constant
    headsize = magic.len + Header.length.sizeof + Header.mtype.sizeof
  var
    ss = newStringStream()
    data: string = ""

  # read the message header to find out how big the message is
  data = await comp.socket.recv(headsize)
  if data.len == 0:
    debug "exiting due to empty read..."
    quit(1)
  if data.len != headsize:
    raise newException(IOError, "short read on header data")

  # record the header we received to the stream
  ss.write(data)
  ss.setPosition(0)

  when not defined(nimdoc):
    # deserialize it back out so we unpack the length/type
    let header = Header.deserialize(ss)
  else:
    let header = Header()

  # read the message body and write it into the stream
  data = await comp.socket.recv(header.length)
  if data.len != header.length:
    raise newException(IOError, "short read on message data")
  if data.len == 0:
    debug "exiting due to empty read..."
    quit(1)
  ss.write(data)

  # now we are ready to rewind and deserialize the whole message
  ss.setPosition(0)
  when not defined(nimdoc):
    var # we may need to clear a bit
      msg = Envelope.deserialize(ss)
  else:
    var msg = Envelope()

  debug "received ", msg.body

  # if the high bit is set, it's an event
  if testBit[Header.mtype](msg.header.mtype, ReceiptType.high):
    clearBit[Header.mtype](msg.header.mtype, ReceiptType.high)
    result = Receipt(kind: EventReceipt, data: msg.body,
      event: newEvent(cast[EventKind](msg.header.mtype), msg.body))
  # otherwise, it's a normal message
  else:
    result = Receipt(kind: ReplyReceipt, data: msg.body,
      reply: newReply(cast[Operation](msg.header.mtype), msg.body))

converter toWindowProperties(js: JsonNode): WindowProperties =
  ## conveniently convert a JsonNode to WindowProperties
  new result
  result.title = js.getOrDefault("title").getStr
  result.instance = js.getOrDefault("instance").getStr
  result.class = js.getOrDefault("class").getStr
  result.window_role = js.getOrDefault("window_role").getStr
  result.transient_or = js.getOrDefault("transient_or").getStr

converter toRect(js: JsonNode): Rect =
  ## conveniently convert a JsonNode to a Rect
  result.x = js["x"].getInt
  result.y = js["y"].getInt
  result.height = js["height"].getInt
  result.width = js["width"].getInt

converter toTreeReply(js: JsonNode): TreeReply =
  ## conveniently convert a JsonNode to a TreeReply
  new result
  result.id = js["id"].getInt
  result.name = js["name"].getStr
  result.app_id = js.getOrDefault("app_id").getStr
  result.pid = js.getOrDefault("pid").getInt
  result.`type` = js["type"].getStr
  result.border = js["border"].getStr
  result.currentBorderWidth = js["current_border_width"].getInt
  result.layout = js["layout"].getStr
  result.orientation = js["orientation"].getStr
  result.percent = js["percent"].getFloat
  result.rect = js["rect"].toRect
  result.window_rect = js["window_rect"].toRect
  result.deco_rect = js["deco_rect"].toRect
  result.geometry = js["geometry"].toRect
  result.window = js["window"].getInt
  if "window_properties" in js:
    result.window_properties = js["window_properties"].toWindowProperties
  result.urgent = js["urgent"].getBool
  result.focused = js["focused"].getBool
  result.sticky = js["sticky"].getBool
  result.fullscreen_mode = js["fullscreen_mode"].getInt
  result.focus = @[]
  for j in js["focus"]:
    result.focus.add j.getInt
  if "nodes" in js:
    for j in js["nodes"]:
      result.nodes.add j.toTreeReply
  if "floating_nodes" in js:
    for j in js["floating_nodes"]:
      result.floating_nodes.add j.toTreeReply

converter toJson*(receipt: Receipt): JsonNode =
  ## natural conversion of receipt payloads into json
  var data = receipt.data

  case data[0]:
  of '{':
    result = data.parseJson()
  of '[':
    data = ("{ \"results\": " & data & "}")
    result = data.parseJson()["results"]
  else:
    raise newException(ValueError, "malformed reply: " & data)

proc newReply*(kind: Operation; js: JsonNode): Reply =
  ## parse a reply for the given operation using a JsonNode
  result = case kind:
  of RunCommand:
    var
      ran: seq[RunCommandReply]
    for n in js.items:
      var run = RunCommandReply()
      run.success = n.getOrDefault("success").getBool
      run.parse_error = n.getOrDefault("parse_error").getBool
      run.error = n.getOrDefault("error").getStr
      ran.add run
    Reply(kind: RunCommand, ran: ran)
  of GetVersion:
    Reply(kind: GetVersion, version: js.to(VersionReply))
  of GetBarConfig:
    if js.kind == JArray:
      var bar = BarConfigReply(kind: BarNames)
      for n in js.items:
        bar.names.add n.getStr
      Reply(kind: GetBarConfig, bar: bar)
    else:
      var bar = BarConfigReply(kind: OneBar, config: js.to(OneBarConfig))
      Reply(kind: GetBarConfig, bar: bar)
  of GetOutputs:
    var outputs: seq[OutputsReply]
    for n in js.items:
      when OutputsReply is TreeReply:
        outputs.add n.toTreeReply
      else:
        outputs.add n.to(OutputsReply)
    Reply(kind: GetOutputs, outputs: outputs)
  of GetWorkspaces:
    var workspaces: seq[WorkspaceReply]
    for n in js.items:
      when WorkspaceReply is TreeReply:
        workspaces.add n.toTreeReply
      else:
        workspaces.add n.to(WorkspaceReply)
    Reply(kind: GetWorkspaces, workspaces: workspaces)
  of Subscribe:
    Reply(kind: Subscribe, subscribe: js["success"].getBool)
  of GetConfig:
    Reply(kind: GetConfig, config: js.getStr)
  of GetMarks:
    var marks: seq[string]
    for n in js.items:
      marks.add n.getStr
    Reply(kind: GetMarks, marks: marks)
  of GetTree:
    Reply(kind: GetTree, tree: js.toTreeReply)
  of GetBindingModes:
    var modes: seq[string]
    for n in js.items:
      modes.add n.getStr
    Reply(kind: GetBindingModes, modes: modes)
  of SendTick:
    Reply(kind: SendTick, tick: js["success"].getBool)
  of Sync:
    Reply(kind: Sync, sync: js["success"].getBool)

proc newReply(kind: Operation; payload: string): Reply =
  ## parse a reply for the given operation using json in a string
  result = newReply(kind, payload.parseJson)

proc newEvent*(kind: EventKind; js: JsonNode): Event =
  ## instantiate a new event of the given kind,
  ## parsing the json input payload from a string
  case kind:
  of Workspace:
    var workspace = WorkspaceEvent(change: js.getOrDefault("change").getStr,
                                   current: js.getOrDefault("current"),
                                   old: js.getOrDefault("old"))
    Event(kind: Workspace, workspace: workspace)
  of Output:
    Event(kind: Output, output: js.to(OutputEvent))
  of Mode:
    Event(kind: Mode, mode: js.to(ModeEvent))
  of Window:
    var window = WindowEvent(change: js.getOrDefault("change").getStr,
                             container: js.getOrDefault("container"))
    Event(kind: Window, window: window)
  of BarConfigUpdate:
    Event(kind: BarconfigUpdate, bar: js.to(BarConfigUpdateEvent))
  of Binding:
    Event(kind: Binding, binding: js.to(BindingEvent))
  of Shutdown:
    Event(kind: Shutdown, shutdown: js.to(ShutdownEvent))
  of Tick:
    Event(kind: Tick, tick: js.to(TickEvent))

proc newEvent(kind: EventKind; payload: string): Event =
  ## parse an event of the given kind using json in a string
  result = newEvent(kind, payload.parseJson)

proc toPayload(kind: Operation; args: openarray[string]): string =
  ## reformat operation arguments according to spec
  result = case kind:
  of RunCommand: args.join("; ")
  of Subscribe: $(%* args)
  of GetVersion: ""
  of GetTree: ""
  of GetConfig: ""
  of GetBindingModes: ""
  of GetOutputs: ""
  of GetMarks: ""
  of GetBarConfig:
    if args.len == 0:
      ""
    else:
      args[0]
  of GetWorkspaces: ""
  else:
    raise newException(Defect, "not implemented")

proc invoke*(compositor: Compositor; operation: Operation; args: seq[string]): Future[Reply] {.async.} =
  ## perform an invocation of the given operation asynchronously
  asyncCheck operation.send(compositor, payload = operation.toPayload(args))
  let receipt = await compositor.recv()
  result = receipt.reply

proc invoke*(compositor: Compositor; operation: Operation; args: varargs[string, `$`]): Reply =
  ## perform an invocation of the given operation synchronously
  var arguments: seq[string]
  for arg in args.items:
    arguments.add arg
  result = waitFor compositor.invoke(operation, arguments)

proc swayipc(socket=""; `type`=""; args: seq[string]) =
  ## cli tool to demonstrate basic usage
  let
    kind = parseEnum[Operation](`type`)
    payload = kind.toPayload(args)
  var
    receipt: Receipt
    compositor: Compositor

  compositor = waitFor kind.send(payload=payload, socket=socket)

  while true:
    receipt = waitFor compositor.recv()
    if kind != Subscribe:
      echo receipt.data
      break
    # subscription receipts could indicate failure to subscribe,
    # or they could be events from successful subscription --
    # swallow success messages (only) and echo event data
    case receipt.kind:
    of ReplyReceipt:
      if not receipt.toJson["success"].getBool:
        error receipt.data
        break
    of EventReceipt:
      echo $receipt.event

proc hasChildren*(container: TreeReply): bool =
  ## true if the container has children, floating or otherwise
  result = container.floatingNodes.len > 0
  result = result or container.nodes.len > 0

iterator children*(container: TreeReply): TreeReply =
  ## yields all child containers of this container, omitting the input
  for node in container.floatingNodes:
    yield node
  for node in container.nodes:
    yield node

iterator clientWalk*(container: TreeReply): TreeReply =
  ## yields children of this container if they exist, otherwise yields itself
  if container.hasChildren:
    for child in container.children:
      yield child
  else:
    yield container

proc everyClient*(container: TreeReply): seq[TreeReply] =
  ## produces a sequence of all leaves (child-free containers) in the given tree
  if container.hasChildren:
    for client in clientWalk(container):
      result &= client.everyClient
  else:
    result.add container

when isMainModule:
  when defined(release) or defined(danger):
    let level = lvlWarn
  else:
    let level = lvlAll
  let logger = newConsoleLogger(useStderr=true, levelThreshold=level)
  addHandler(logger)

  dispatch swayipc
