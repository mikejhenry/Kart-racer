extends Node
## Autoload. Talks to the game server: the leaderboard and ghosts over
## HTTPS, and lobbies over a WebSocket. If the connection drops, it keeps
## trying to get back into the same lobby (and race) for a while.

const ServerConfig := preload("res://scripts/server_config.gd")
const PING_INTERVAL := 20.0
const RETRY_EVERY := 2.0
const RETRY_FOR := 40.0

signal joined(id: String)
signal lobby_updated(info: Dictionary)
signal race_started(info: Dictionary)
signal kart_state(id: String, data: Array, sent_at: float)
signal item_event(id: String, data: Dictionary)
signal player_finished(id: String, player_name: String, time: float, place: int)
signal player_left(id: String)
signal player_dropped(id: String)
signal player_back(id: String)
signal error(message: String)
signal connection_lost          ## Dropped; trying to reconnect
signal reconnected              ## Back in after connection_lost
signal disconnected             ## Gave up, or the lobby is gone
signal left_lobby               ## We left (or were dropped for good)
signal voice_signal(from: String, data: Dictionary)

var server_url := ""
var my_id := ""
var lobby := {}

var _ws: WebSocketPeer
var _opened := false
var _refused := false
var _leaving := false
var _ping_timer := 0.0
var _code := ""
var _token := ""
var _name := ""
var _retrying := false
var _retry_left := 0.0
var _retry_timer := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var override := OS.get_environment("KART_SERVER")
	server_url = override if override != "" else ServerConfig.URL
	server_url = server_url.strip_edges().trim_suffix("/")


func is_configured() -> bool:
	return server_url != ""


func in_lobby() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and my_id != "" and not _retrying


func is_reconnecting() -> bool:
	return _retrying


func is_host() -> bool:
	return my_id != "" and str(lobby.get("host", "")) == my_id


func lobby_code() -> String:
	return _code


# --- Leaderboard and ghosts -------------------------------------------------

func get_leaderboard(track: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/leaderboard?track=" + track.uri_encode())


func get_record_ghost(track: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/ghost?track=" + track.uri_encode())


func submit_time(track: String, player_name: String, time: float, frames: Array) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/leaderboard", {"track": track, "name": player_name, "time": time, "frames": frames})


# --- Lobbies ----------------------------------------------------------------

## Creates a private lobby and joins it. Returns {"code": ...} or {"error": ...}.
func create_lobby(player_name: String) -> Dictionary:
	var res := await _request(HTTPClient.METHOD_POST, "/lobby", {})
	if res.has("code"):
		join(str(res.code), player_name)
	return res


## Finds an open public lobby (or starts one) and joins it.
func quick_match(player_name: String) -> Dictionary:
	var res := await _request(HTTPClient.METHOD_POST, "/quickmatch", {})
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
	_code = code
	_name = player_name
	_token = ""
	my_id = ""
	_connect()


## Rejoins a lobby from an earlier session (e.g. after the page reloaded).
func resume(session: Dictionary, player_name: String) -> void:
	leave()
	_code = str(session.get("code", ""))
	_name = player_name
	my_id = str(session.get("id", ""))
	_token = str(session.get("token", ""))
	_connect()


func leave() -> void:
	left_lobby.emit()
	_leaving = true
	if _ws:
		_ws.close()
	_ws = null
	_retrying = false
	my_id = ""
	lobby = {}
	_code = ""
	_token = ""
	Game.clear_session()


func send(msg: Dictionary) -> void:
	if in_lobby():
		_ws.send_text(JSON.stringify(msg))


func _connect() -> void:
	_leaving = false
	var ws_url := server_url.replace("https://", "wss://").replace("http://", "ws://")
	ws_url += "/lobby/%s/ws?name=%s&color=%s&style=%s" % [_code, _name.uri_encode(), Game.color().to_html(false), Game.kart_style]
	if my_id != "" and _token != "":
		ws_url += "&rejoin=%s&token=%s" % [my_id, _token]
	_ws = WebSocketPeer.new()
	_opened = false
	_refused = false
	_ping_timer = 0.0
	if _ws.connect_to_url(ws_url) != OK:
		_ws = null
		if not _retrying:
			error.emit("Couldn't connect to the server.")


func _process(delta: float) -> void:
	if _retrying:
		_retry_left -= delta
		_retry_timer -= delta
		if _retry_left <= 0.0:
			_give_up()
			return
		if _ws == null and _retry_timer <= 0.0:
			_retry_timer = RETRY_EVERY
			_connect()
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
		_ws = null
		if _leaving:
			return
		if _refused:
			_retrying = false
			if my_id != "":
				_give_up()
			return
		if my_id != "" and _token != "":
			# Dropped from a lobby we were in: keep trying to get back.
			if not _retrying:
				_retrying = true
				_retry_left = RETRY_FOR
				_retry_timer = 0.5
				connection_lost.emit()
		elif not _opened:
			error.emit("Couldn't connect to the server.")
		else:
			error.emit("The connection closed.")


func _give_up() -> void:
	_retrying = false
	if _ws:
		_ws.close()
	_ws = null
	my_id = ""
	lobby = {}
	_token = ""
	Game.clear_session()
	left_lobby.emit()
	disconnected.emit()


func _handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"welcome":
			var was_retrying := _retrying
			_retrying = false
			my_id = str(msg.get("id", ""))
			_token = str(msg.get("token", ""))
			_code = str(msg.get("code", _code))
			Game.save_session(_code, my_id, _token)
			if was_retrying:
				reconnected.emit()
			elif msg.has("race"):
				# Rejoined a race in progress (e.g. after reloading the page)
				var info: Dictionary = msg.race
				info["resume"] = true
				race_started.emit(info)
			joined.emit(my_id)
		"lobby":
			lobby = msg
			lobby_updated.emit(msg)
		"start":
			race_started.emit(msg)
		"s":
			kart_state.emit(str(msg.get("id", "")), msg.get("d", []), float(msg.get("at", 0.0)))
		"i":
			item_event.emit(str(msg.get("id", "")), msg)
		"f":
			player_finished.emit(str(msg.get("id", "")), str(msg.get("name", "")), float(msg.get("time", 0.0)), int(msg.get("place", 0)))
		"leave":
			player_left.emit(str(msg.get("id", "")))
		"drop":
			player_dropped.emit(str(msg.get("id", "")))
		"back":
			player_back.emit(str(msg.get("id", "")))
		"v":
			if msg.get("d") is Dictionary:
				voice_signal.emit(str(msg.get("from", "")), msg.d)
		"error":
			_refused = true
			error.emit(str(msg.get("msg", "Server error.")))


func _request(method: int, path: String, body = null) -> Dictionary:
	if not is_configured():
		return {"error": "Online features aren't set up."}
	var http := HTTPRequest.new()
	http.timeout = 12.0
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
