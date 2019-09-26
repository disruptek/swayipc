import os
import json
import tables
import asyncdispatch
import asyncnet
import net
import cligen
import nesm
import streams
import logging
import strutils
import bitops

export asyncdispatch

##
## documentation for the i3 ipc interface:
##
## https://i3wm.org/docs/ipc.html
##

## a special prefix for messages to/from the server
const magic = ['i', '3', '-', 'i', 'p', 'c']

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

  ## all messages fall into one of two categories
  ReceiptKind* = enum MessageReceipt, EventReceipt

  ## all messages may thus be represented by their category and content
  Receipt* = object
    data*: string
    case kind*: ReceiptKind
    of MessageReceipt:
      mkind*: Operation
    of EventReceipt:
      event*: Event

  WorkspaceEvent* = ref object
    change*: string
    old*: TreeResult
    current*: TreeResult

  WindowEvent* = ref object
    change*: string
    container*: TreeResult

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

  WorkspaceResult = object
    num: int
    name: string
    visible: bool
    focused: bool
    urgent: bool
    rect: Rect
    output: string

  RunCommandResult = object
    error: string
    success: bool
    parse_error: bool

  OutputResult = object
    name: string
    active: bool
    primary: bool
    current_workspace: string
    rect: Rect

  WindowProperties* = ref object
    title*: string
    instance*: string
    class*: string
    window_role*: string
    transient_or*: string

  TreeResult* = ref object
    id*: int
    name*: string
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
    focus*: seq[int]
    nodes*: seq[TreeResult]
    floating_nodes*: seq[TreeResult]

  ## a reply arrives as a result of a query sent to the server
  Reply = object of RootObj

  RunCommandReply* = object of Reply
    results: seq[RunCommandResult]
  GetVersionReply* = object of Reply
    major: int
    minor: int
    patch: int
    #variant: string
    human_readable: string
    loaded_config_file_name: string
  GetBarConfigReply* = object of Reply
    colors: Table[string, string]
    id: string
    mode: string
    position: string
    status_command: string
    font: string
  GetOutputsReply* = object of Reply
    results: seq[OutputResult]
  GetWorkspacesReply* = object of Reply
    results: seq[WorkspaceResult]
  SubscribeReply* = object of Reply
    success: bool
  GetConfigReply* = object of Reply
    config: string
  GetMarksReply* = object of Reply
    results: seq[string]
  GetTreeReply* = object of Reply
    tree*: TreeResult
  BarConfigReplyKind = enum AllBars, OneBar
  BarConfigReply* = object of Reply
    case kind: BarConfigReplyKind
    of AllBars:
      results: seq[string]
    of OneBar:
      id: string
      mode: string
      position: string
      status_command: string
      font: string
      workspace_buttons: bool
      binding_mode_indicator: bool
      verbose: bool
      colors: Table[string, string]
  TickReply* = object of Reply
    success: bool

  BindingInfo = object
    command: string
    input_code: int
    symbol: string
    input_type: string
    # input_codes: seq[...?] on sway
    event_state_mask: seq[string]

  Rect* = object
    x*: int
    y*: int
    height*: int
    width*: int

  Compositor* = object
    socket: AsyncSocket

proc newEvent*(kind: EventKind; payload: string): Event

## nesm does the packing and unpacking of our messages and replies.
## we separate out the header so that we can deserialize it alone,
## in order to read the length of the subsequent envelope body...
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
type ReceiptType = BitsRange[Header.mtype]

proc `$`*(event: Event): string =
  result = event.repr

proc newEnvelope(kind: Operation; data: string): Envelope =
  ## create a new envelope for sending over the socket
  result = Envelope(body: data)
  result.header = Header(magic: magic,
    length: cast[Header.length](data.len),
    mtype: cast[Header.mtype](kind))

proc newCompositor*(path=""): Future[Compositor] {.async.} =
  ## connect to a compositor on the given path, defaulting to sway
  var
    addy: string
    sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  if path == "":
    addy = os.getEnv("SWAYSOCK")
  else:
    addy = path
  assert addy.len > 0, "unable to guess path to compositor socket"
  asyncCheck sock.connectUnix(addy)
  result = Compositor(socket: sock)

proc send*(kind: Operation; compositor: Compositor; payload=""): Future[Compositor] {.async.} =
  ## given an operation, send a payload to a compositor; yield the compositor
  let
    msg = kind.newEnvelope($payload)
  var
    ss = newStringStream()

  debug "sending ", $payload

  # serialize the whole message into the stream and send it
  serialize(msg, ss)

  asyncCheck compositor.socket.send(ss.data)
  result = compositor

proc send*(kind: Operation; payload=""; socket=""): Future[Compositor] {.async.} =
  ## given an operation, send a payload to a socket; yield the compositor
  let compositor = await newCompositor(socket)
  result = await kind.send(compositor, payload=payload)

proc recv*(comp: Compositor): Future[Receipt] {.async.} =
  ## receive a  message from the compositor
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
  assert data.len == headsize, "short read on header data"

  # record the header we received to the stream
  ss.write(data)
  ss.setPosition(0)

  # deserialize it back out so we unpack the length/type
  let header = Header.deserialize(ss)
  debug "len of reply string:  ", header.length
  debug "            of type:  ", header.mtype

  # read the message body and write it into the stream
  data = await comp.socket.recv(header.length)
  assert data.len == header.length, "short read on message data"
  if data.len == 0:
    debug "exiting due to empty read..."
    quit(1)
  ss.write(data)

  # now we are ready to rewind and deserialize the whole message
  ss.setPosition(0)
  var # we may need to clear a bit
    msg = Envelope.deserialize(ss)
  debug "received ", msg.body

  # if the high bit is set, it's an event
  if testBit[Header.mtype](msg.header.mtype, ReceiptType.high):
    clearBit[Header.mtype](msg.header.mtype, ReceiptType.high)
    result = Receipt(kind: EventReceipt, data: msg.body,
      event: newEvent(cast[EventKind](msg.header.mtype), msg.body))
  # otherwise, it's a normal message
  else:
    result = Receipt(kind: MessageReceipt, data: msg.body,
      mkind: cast[Operation](msg.header.mtype))

converter toWindowProperties(js: JsonNode): WindowProperties =
  new result
  result.title = js["title"].getStr
  result.instance = js["instance"].getStr
  result.class = js["class"].getStr
  result.window_role = js{"window_role"}.getStr
  result.transient_or = js{"transient_or"}.getStr

converter toRect(js: JsonNode): Rect =
  result.x = js["x"].getInt
  result.y = js["y"].getInt
  result.height = js["height"].getInt
  result.width = js["width"].getInt

converter toTreeResult(js: JsonNode): TreeResult =
  new result
  result.id = js["id"].getInt
  result.name = js["name"].getStr
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
  result.focus = @[]
  for j in js["focus"]:
    result.focus.add j.getInt
  if "nodes" in js:
    for j in js["nodes"]:
      result.nodes.add j.toTreeResult
  if "floating_nodes" in js:
    for j in js["floating_nodes"]:
      result.floating_nodes.add j.toTreeResult

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

proc getTree*(compositor: Compositor): Future[GetTreeReply] {.async.} =
  ## fetch the client tree
  asyncCheck GetTree.send(compositor)
  let
    receipt = await compositor.recv()
    js = receipt.data.parseJson
  result = GetTreeReply(tree: js.toTreeResult)

proc getTree*(socket=""): Future[GetTreeReply] {.async.} =
  ## fetch the client tree without a compositor
  let compositor = await newCompositor(socket)
  result = await compositor.getTree()

proc newEvent*(kind: EventKind; payload: string): Event =
  ## instantiate a new event of the given kind,
  ## parsing the json input payload from a string
  let js = payload.parseJson
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

proc toPayload(kind: Operation; args: seq[string]): string =
  ## reformat operation arguments according to spec
  result = case kind:
  of RunCommand: args[0]
  of Subscribe: $(%* args)
  of GetVersion: ""
  of GetTree: ""
  else:
    raise newException(Defect, "not implemented")

proc i3ipc(socket=""; `type`=""; args: seq[string]) =
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
    of MessageReceipt:
      if not receipt.toJson["success"].getBool:
        error receipt.data
        break
    of EventReceipt:
      echo $receipt.event

when isMainModule:
  when defined(release):
    let level = lvlWarn
  else:
    let level = lvlAll
  let logger = newConsoleLogger(useStderr=true, levelThreshold=level)
  addHandler(logger)

  dispatch i3ipc
