#? replace(sub = "\t", by = " ")
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


##
## documentation for the i3 ipc interface:
##
## https://i3wm.org/docs/ipc.html
##

## a special prefix for messages to/from the server
const magic = ['i', '3', '-', 'i', 'p', 'c']


type
	MessageKind = enum
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
	
	EventKind = enum
		Workspace = 0
		Output = 1
		Mode = 2
		Window = 3
		BarConfigUpdate = 4
		Binding = 5
		Shutdown = 6
		Tick = 7

	ReceiptKind = enum MessageReceipt, EventReceipt
	Receipt = object
		data: string
		case kind: ReceiptKind
		of MessageReceipt:
			mkind: MessageKind
		of EventReceipt:
			ekind: EventKind
		
	Event = object
		case kind: EventKind
		of Workspace:
			change: string
			old: TreeResult
			current: TreeResult
		of Output: discard
		of Mode: discard
		of Window:
			container: TreeResult
		of BarconfigUpdate:
			id: string
			hidden_state: string
			mode: string
		of Binding:
			binding: BindingInfo
		of Shutdown:
			discard
			#change: string
		of Tick:
			first: string
			payload: JsonNode

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

	WindowProperties = object
		title: string
		instance: string
		class: string
		window_role: string
		transient_or: string

	TreeResult = object
		id: int
		name: string
		`type`: string
		border: string
		current_border_width: int
		layout: string
		orientation: string
		percent: float
		rect: Rect
		window_rect: Rect
		deco_rect: Rect
		geometry: Rect
		window: int
		window_properties: WindowProperties
		urgent: bool
		focused: bool
		focus: seq[int]
		nodes: seq[TreeResult]
		floating_nodes: seq[TreeResult]

	Reply = object of RootObj

	RunCommandReply = object of Reply
		results: seq[RunCommandResult]
	GetVersionReply = object of Reply
		major: int
		minor: int
		patch: int
		#variant: string
		human_readable: string
		loaded_config_file_name: string
	GetBarConfigReply = object of Reply
		colors: Table[string, string]
		id: string
		mode: string
		position: string
		status_command: string
		font: string
	GetOutputsReply = object of Reply
		results: seq[OutputResult]
	GetWorkspacesReply = object of Reply
		results: seq[WorkspaceResult]
	SubscribeReply = object of Reply
		success: bool
	GetConfigReply = object of Reply
		config: string
	GetMarksReply = object of Reply
		results: seq[string]
	TreeReply = object of Reply
		tree: TreeResult
	BarConfigReplyKind = enum AllBars, OneBar
	BarConfigReply = object of Reply
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
	TickReply = object of Reply
		success: bool

	#[
		of SendTick: discard
		of GetConfig: discard
		of GetTree: discard
		of GetBindingModes: discard
		of Subscribe: discard
		of GetMarks: discard
		of Sync: discard
	]#

	BindingInfo = object
		command: string
		mods: string
		input_code: string
		symbol: string
		input_type: string
	Rect = object
		x: int
		y: int
		height: int
		width: int

	Compositor = object
		socket: AsyncSocket

serializable:
	type
		Header = object
			magic*: array[magic.len, char]
			length*: int32
			mtype*: int32

		Message = object
			header: Header
			data: string as {size: {}.header.length}

# we'll use this to discriminate between message and event replies
type ReceiptType = BitsRange[Header.mtype]

proc newMessage(kind: MessageKind; data: string): Message =
	result.header = Header(magic: magic,
								  length: cast[Header.length](data.len),
								  mtype: cast[Header.mtype](kind))
	result.data = data

proc sendMessage(comp: Compositor; kind: MessageKind; payload: JsonNode): Future[void] =
	## sends a message and receives a json reply
	let
		msg = kind.newMessage($payload)
	var
		ss = newStringStream()

	debug "sending ", $payload

	# serialize the whole message into the stream and send it
	serialize(msg, ss)
	result = comp.socket.send(ss.data)

proc recvMessage(comp: Compositor): Future[Receipt] {.async.} =
	let
		# sadly, Header.sizeof will not match the following, and
		# i'm uncertain we can simply alter it by a constant
		headsize = magic.len + Header.length.sizeof + Header.mtype.sizeof
	var
		ss = newStringStream()
		data: string = ""

	# read the message header to find out how big the message is
	data = waitFor comp.socket.recv(headsize)
	assert data.len == headsize, "short read on header data"

	# record the header we received to the stream
	ss.write(data)
	ss.setPosition(0)

	# deserialize it back out so we unpack the length/type
	let header = Header.deserialize(ss)
	debug "len of reply string:  ", header.length
	debug "            of type:  ", header.mtype

	# read the message body and write it into the stream
	data = waitFor comp.socket.recv(header.length)
	assert data.len == header.length, "short read on message data"
	ss.write(data)

	# now we are ready to rewind and deserialize the whole message
	ss.setPosition(0)
	var # we may need to clear a bit
		msg = Message.deserialize(ss)
	debug "received ", msg.data
	
	# if the high bit is set, it's an event
	if testBit[Header.mtype](msg.header.mtype, ReceiptType.high):
		clearBit[Header.mtype](msg.header.mtype, ReceiptType.high)
		result = Receipt(kind: EventReceipt, data: msg.data,
			ekind: cast[EventKind](msg.header.mtype))
	# otherwise, it's a normal message
	else:
		result = Receipt(kind: MessageReceipt, data: msg.data,
			mkind: cast[MessageKind](msg.header.mtype))

converter toJson(receipt: Receipt): JsonNode =
	var data = receipt.data

	case data[0]:
	of '{': discard
	of '[': data = ("{ \"results\": " & data & "}")
	else:
		raise newException(ValueError, "malformed reply: " & data)
	result = data.parseJson()

template query(comp: Compositor; kind: MessageKind; payload: JsonNode): untyped =
	waitFor comp.sendMessage(kind, payload)
	let receipt = waitFor comp.recvMessage()
	debug "received ", $receipt
	let js = receipt.toJson

	case receipt.mkind:
	of RunCommand: js.to(RunCommandReply)
	of GetVersion: js.to(GetVersionReply)
	of Subscribe: js.to(SubscribeReply)
	else:
		raise newException(Defect, "not implemented")

proc newCompositor(path=""): Future[Compositor] {.async.} =
	var
		addy: string
		sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
	if path == "":
		addy = os.getEnv("SWAYSOCK")
	else:
		addy = path
	assert addy.len > 0, "unable to guess path to compositor socket"
	waitFor sock.connectUnix(addy)
	result = Compositor(socket: sock)

proc toPayload(kind: MessageKind; args: seq[string]): JsonNode =
	result = case kind:
	of RunCommand: %* args
	of Subscribe: %* args
	of GetVersion: newJObject()
	else:
		raise newException(Defect, "not implemented")

proc i3ipc(socket=""; `type`=""; args: seq[string]) =
	var
		receipt: Receipt
		comp = waitFor newCompositor(socket)

	let
		kind = parseEnum[MessageKind](`type`)
		payload = kind.toPayload(args)
	
	waitFor comp.sendMessage(kind, payload)

	while true:
		receipt = waitFor comp.recvMessage()
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
			echo receipt.data

when isMainModule:
	when defined(release):
		let logger = newConsoleLogger(useStderr=true, levelThreshold=lvlWarn)
	else:
		let logger = newConsoleLogger(useStderr=true, levelThreshold=lvlAll)
	addHandler(logger)

	dispatch i3ipc
