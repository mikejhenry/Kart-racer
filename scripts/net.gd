extends Node
## Autoload. Talks to the game server: the leaderboard over HTTPS and private
## lobbies over a WebSocket. Works the same in the browser and natively.

const ServerConfig := preload("res://scripts/server_config.gd")
const PING_INTERVAL := 20.0

signal joined(id: String)
signal lobby_updated(info: Dictionary)
signal race_started(players: Array)
signal kart_state(id: String, data: Array)
signal item_event(id: String, data: Dictionary)
signal player_finished(id: String, player_name: String, time: float, place: int)
signal player_left(id: String)
signal error(message: String)
signal disconnected

var server_url := ""
var my_id := ""
var lobby := {}

var _ws: WebSocketPeer
var _opened := false
var _refused := false
var _ping_timer := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var override := OS.get_environment("KART_SERVER")
	server_url = override if override != "" else ServerConfig.URL
	server_url = server_url.strip_edges().trim_suffix("/")


func is_configured() -> bool:
	return server_url != ""


func in_lobby() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and my_id != ""


func is_host() -> bool:
	return my_id != "" and str(lobby.get("host", "")) == my_id


# --- Leaderboard ------------------------------------------------------------

func get_leaderboard(track: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/leaderboard?track=" + track.uri_encode())


func submit_time(track: String, player_name: String, time: float) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/leaderboard", {"track": track, "name": player_name, "time": time})


# --- Lobbies ----------------------------------------------------------------

## Creates a private lobby and joins it. Returns {"code": ...} or {"error": ...}.
func create_lobby(player_name: String) -> Dictionary:
	var res := await _request(HTTPClient.METHOD_POST, "/lobby", {})
	if res.has("code"):
		join(str(res.code), player_name)
	return res


func join(code: String, player_name: String) -> void:
	leave()
	code = code.strip_edges().to_upper()
	# Check first, so the player gets a clear reason if they can't join.
	var status := await _request(HTTPClient.METHOD_GET, "/lobby/" + code.uri_encode())
	if status.has("error"):
		error.emit(str(status.error))
		return
	if not status.get("exists", false):
		error.emit("Lobby not found. Check the code.")
		return
	if str(status.get("phase", "")) != "waiting":
		error.emit("A race is in progress. Try again when it ends.")
		return
	if int(status.get("players", 0)) >= int(status.get("max", 6)):
		error.emit("That lobby is full.")
		return
	var ws_url := server_url.replace("https://", "wss://").replace("http://", "ws://")
	ws_url += "/lobby/%s/ws?name=%s" % [code, player_name.uri_encode()]
	_ws = WebSocketPeer.new()
	_opened = false
	_refused = false
	_ping_timer = 0.0
	if _ws.connect_to_url(ws_url) != OK:
		_ws = null
		error.emit("Couldn't connect to the server.")


func leave() -> void:
	if _ws:
		_ws.close()
	_ws = null
	my_id = ""
	lobby = {}


func send(msg: Dictionary) -> void:
	if in_lobby():
		_ws.send_text(JSON.stringify(msg))


func _process(delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_opened = true
		_ping_timer += delta
		if _ping_timer >= PING_INTERVAL:
			_ping_timer = 0.0
			_ws.send_text('{"t":"ping"}')
	while _ws != null and _ws.get_available_packet_count() > 0:
		var parsed = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if parsed is Dictionary:
			_handle(parsed)
	if _ws != null and state == WebSocketPeer.STATE_CLOSED:
		var was_member := my_id != ""
		_ws = null
		my_id = ""
		lobby = {}
		if _refused:
			return
		if was_member:
			disconnected.emit()
		elif not _opened:
			error.emit("Couldn't connect to the server.")
		else:
			error.emit("The connection closed.")


func _handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"welcome":
			my_id = str(msg.get("id", ""))
			joined.emit(my_id)
		"lobby":
			lobby = msg
			lobby_updated.emit(msg)
		"start":
			race_started.emit(msg.get("players", []))
		"s":
			kart_state.emit(str(msg.get("id", "")), msg.get("d", []))
		"i":
			item_event.emit(str(msg.get("id", "")), msg)
		"f":
			player_finished.emit(str(msg.get("id", "")), str(msg.get("name", "")), float(msg.get("time", 0.0)), int(msg.get("place", 0)))
		"leave":
			player_left.emit(str(msg.get("id", "")))
		"error":
			_refused = true
			error.emit(str(msg.get("msg", "Server error.")))


func _request(method: int, path: String, body = null) -> Dictionary:
	if not is_configured():
		return {"error": "Online features aren't set up."}
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var data := "" if body == null else JSON.stringify(body)
	var err := http.request(server_url + path, PackedStringArray(["Content-Type: application/json"]), method, data)
	if err != OK:
		http.queue_free()
		return {"error": "Couldn't reach the server."}
	var result: Array = await http.request_completed
	http.queue_free()
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"error": "Couldn't reach the server."}
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if parsed is Dictionary:
		if int(result[1]) >= 400 and not parsed.has("error"):
			parsed["error"] = "Server error (%d)." % int(result[1])
		return parsed
	return {"error": "Unexpected reply from the server."}
