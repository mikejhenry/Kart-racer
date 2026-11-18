extends Node
## Autoload. Voice chat for private lobbies, in the browser version.
##
## The browser does the audio with WebRTC: every player in voice connects
## directly to every other player (fine for up to 6), with echo cancellation
## and noise suppression. The game server only passes along the short
## messages needed to set those connections up ("v" messages in the lobby).
## The connections live in the page, so voice keeps going between the lobby
## and races.

signal changed

const VOICE_JS := """
(function () {
  if (window.kartVoice) return;
  const ICE = [{urls: 'stun:stun.cloudflare.com:3478'}, {urls: 'stun:stun.l.google.com:19302'}];
  const v = window.kartVoice = {me: '', stream: null, muted: false, joined: false, error: '',
    outbox: [], peers: new Map(), ctx: null, selfAnalyser: null};

  const send = (to, d) => v.outbox.push({to, d});
  v.drain = () => { if (!v.outbox.length) return ''; const s = JSON.stringify(v.outbox); v.outbox = []; return s; };

  function level(an) {
    if (!an) return 0;
    const b = new Uint8Array(an.fftSize); an.getByteTimeDomainData(b);
    let m = 0; for (const x of b) m = Math.max(m, Math.abs(x - 128));
    return m / 128;
  }
  v.state = () => {
    const peers = {};
    for (const [id, p] of v.peers) peers[id] = {state: p.pc.connectionState, level: level(p.analyser)};
    return JSON.stringify({joined: v.joined, ready: !!v.stream, muted: v.muted, error: v.error,
      self: v.muted ? 0 : level(v.selfAnalyser), peers});
  };

  v.join = async (me) => {
    v.me = me; v.joined = true; v.error = '';
    try {
      v.stream = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true}, video: false});
    } catch (e) {
      v.error = 'Microphone blocked. Allow it for this site in your browser settings.';
      v.joined = false; return;
    }
    if (!v.joined) { v.stream.getTracks().forEach(t => t.stop()); v.stream = null; return; }
    v.ctx = new (window.AudioContext || window.webkitAudioContext)();
    v.selfAnalyser = v.ctx.createAnalyser();
    v.ctx.createMediaStreamSource(v.stream).connect(v.selfAnalyser);
    v.setMuted(v.muted);
    send('*', {k: 'hello'});
  };

  v.leave = () => {
    if (v.stream) send('*', {k: 'bye'});
    v.joined = false;
    for (const id of [...v.peers.keys()]) drop(id);
    if (v.stream) v.stream.getTracks().forEach(t => t.stop());
    v.stream = null;
    if (v.ctx) v.ctx.close();
    v.ctx = null; v.selfAnalyser = null;
  };

  v.setMuted = (m) => { v.muted = m; if (v.stream) v.stream.getAudioTracks().forEach(t => t.enabled = !m); };

  function drop(id) {
    const p = v.peers.get(id); if (!p) return;
    try { p.pc.close(); } catch (e) {}
    if (p.audio) { p.audio.srcObject = null; p.audio.remove(); }
    v.peers.delete(id);
  }

  function peer(id) {
    let p = v.peers.get(id);
    if (p) return p;
    const pc = new RTCPeerConnection({iceServers: ICE});
    p = {pc, audio: null, analyser: null, pending: []};
    v.peers.set(id, p);
    v.stream.getTracks().forEach(t => pc.addTrack(t, v.stream));
    pc.onicecandidate = (e) => { if (e.candidate) send(id, {k: 'ice', c: e.candidate.toJSON()}); };
    pc.ontrack = (e) => {
      const s = e.streams[0] || new MediaStream([e.track]);
      if (!p.audio) {
        p.audio = document.createElement('audio');
        p.audio.autoplay = true; p.audio.playsInline = true;
        document.body.appendChild(p.audio);
      }
      p.audio.srcObject = s;
      p.audio.play().catch(() => {});
      if (v.ctx) { p.analyser = v.ctx.createAnalyser(); v.ctx.createMediaStreamSource(s).connect(p.analyser); }
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed') { drop(id); if (v.joined && v.me < id) offer(id); }
    };
    return p;
  }

  async function offer(id) {
    const p = peer(id);
    await p.pc.setLocalDescription(await p.pc.createOffer());
    send(id, {k: 'offer', sdp: p.pc.localDescription.toJSON()});
  }

  async function remote(p, sdp) {
    await p.pc.setRemoteDescription(sdp);
    for (const c of p.pending) await p.pc.addIceCandidate(c);
    p.pending = [];
  }

  // Each pair connects once: whoever has the smaller id makes the offer.
  v.receive = async (from, raw) => {
    if (!v.joined || !v.stream || from === v.me) return;
    let d; try { d = JSON.parse(raw); } catch (e) { return; }
    try {
      if (d.k === 'hello') { drop(from); send(from, {k: 'here'}); if (v.me < from) await offer(from); }
      else if (d.k === 'here') { if (v.me < from && !v.peers.has(from)) await offer(from); }
      else if (d.k === 'offer') {
        drop(from); const p = peer(from); await remote(p, d.sdp);
        await p.pc.setLocalDescription(await p.pc.createAnswer());
        send(from, {k: 'answer', sdp: p.pc.localDescription.toJSON()});
      }
      else if (d.k === 'answer') { const p = v.peers.get(from); if (p) await remote(p, d.sdp); }
      else if (d.k === 'ice') {
        const p = v.peers.get(from); if (!p) return;
        if (p.pc.remoteDescription) await p.pc.addIceCandidate(d.c); else p.pending.push(d.c);
      }
      else if (d.k === 'bye') drop(from);
    } catch (e) { console.warn('voice chat:', e); }
  };
})();
"""

const TALKING_LEVEL := 0.06

var available := false     ## Voice needs the browser version
var joined := false
var mic_ready := false     ## Microphone is on and we have announced ourselves
var muted := false
var error := ""
var self_level := 0.0
var peers := {}            ## player id -> {"state": String, "level": float}
var _poll := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	available = OS.has_feature("web")
	if available:
		JavaScriptBridge.eval(VOICE_JS, true)
	Net.voice_signal.connect(_on_signal)
	Net.left_lobby.connect(leave)


## Voice is offered in private lobbies of the browser version.
func can_use() -> bool:
	return available and Net.in_lobby() and not bool(Net.lobby.get("public", false))


func join() -> void:
	if joined or not can_use():
		return
	joined = true
	error = ""
	JavaScriptBridge.eval("kartVoice.join(%s)" % JSON.stringify(Net.my_id), true)
	changed.emit()


func leave() -> void:
	if not joined:
		return
	joined = false
	mic_ready = false
	peers = {}
	JavaScriptBridge.eval("kartVoice.leave()", true)
	changed.emit()


func set_muted(on: bool) -> void:
	muted = on
	if available:
		JavaScriptBridge.eval("kartVoice.setMuted(%s)" % ("true" if on else "false"), true)
	changed.emit()


func connected_count() -> int:
	var n := 0
	for id in peers:
		if str(peers[id].get("state", "")) == "connected":
			n += 1
	return n


func is_talking(id: String) -> bool:
	if id == Net.my_id:
		return joined and not muted and self_level > TALKING_LEVEL
	return float(peers.get(id, {}).get("level", 0.0)) > TALKING_LEVEL


func in_voice(id: String) -> bool:
	if id == Net.my_id:
		return mic_ready
	return str(peers.get(id, {}).get("state", "")) == "connected"


func _process(delta: float) -> void:
	if not joined:
		return
	# Pass the browser's connection setup messages to the other players.
	var out = JavaScriptBridge.eval("kartVoice.drain()", true)
	if out is String and out != "":
		var list = JSON.parse_string(out)
		if list is Array:
			for m in list:
				Net.send({"t": "v", "to": str(m.get("to", "*")), "d": m.get("d", {})})
	_poll += delta
	if _poll >= 0.15:
		_poll = 0.0
		var state = JSON.parse_string(str(JavaScriptBridge.eval("kartVoice.state()", true)))
		if state is Dictionary:
			mic_ready = bool(state.get("ready", false))
			error = str(state.get("error", ""))
			self_level = float(state.get("self", 0.0))
			peers = state.get("peers", {})
			if not bool(state.get("joined", false)):
				joined = false
				mic_ready = false
		changed.emit()


func _on_signal(from: String, data: Dictionary) -> void:
	if joined:
		# Passed as a string and parsed in the page, never run as code.
		JavaScriptBridge.eval("kartVoice.receive(%s, %s)" % [JSON.stringify(from), JSON.stringify(JSON.stringify(data))], true)
