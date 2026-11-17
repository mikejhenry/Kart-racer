// Kart Racer game server: a Cloudflare Worker with two Durable Objects.
//
//   GET  /leaderboard?track=circuit_1   -> top 10 time trial records
//   POST /leaderboard                   -> submit {track, name, time}
//   POST /lobby                         -> create a private lobby, returns {code}
//   GET  /lobby/<CODE>/ws?name=<name>   -> WebSocket into that lobby
//
// Each lobby is its own Durable Object, so every player in a lobby talks to
// the same instance. The leaderboard is one Durable Object with a SQLite table.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};
const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I
const CODE_LENGTH = 5;
const MAX_PLAYERS = 6;
const LAPS = 3;
const MIN_RACE_TIME = 30; // seconds; anything faster is rejected
const LOBBY_TTL_MS = 24 * 60 * 60 * 1000;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

function cleanName(raw) {
  const name = String(raw ?? "").replace(/[^\w .\-]/g, "").trim().slice(0, 16);
  return name || "Racer";
}

function cleanTrack(raw) {
  const track = String(raw ?? "");
  return /^[a-z0-9_]{1,32}$/.test(track) ? track : "circuit_1";
}

function randomCode() {
  const bytes = new Uint8Array(CODE_LENGTH);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => CODE_CHARS[b % CODE_CHARS.length]).join("");
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts.length === 0) return json({ ok: true, service: "kart-racer-server" });

    if (parts[0] === "leaderboard" && parts.length === 1) {
      const stub = env.LEADERBOARD.get(env.LEADERBOARD.idFromName("global"));
      return stub.fetch(request);
    }

    if (parts[0] === "lobby" && parts.length === 1 && request.method === "POST") {
      for (let attempt = 0; attempt < 5; attempt++) {
        const code = randomCode();
        const stub = env.LOBBY.get(env.LOBBY.idFromName(code));
        const res = await stub.fetch(`https://lobby/lobby/${code}/init`, { method: "POST" });
        if (res.ok) return json({ code });
      }
      return json({ error: "Could not create a lobby. Try again." }, 500);
    }

    if (parts[0] === "lobby" && parts.length === 2 && request.method === "GET") {
      const code = parts[1].toUpperCase();
      if (!new RegExp(`^[A-Z0-9]{${CODE_LENGTH}}$`).test(code)) return json({ exists: false });
      const stub = env.LOBBY.get(env.LOBBY.idFromName(code));
      return stub.fetch(`https://lobby/lobby/${code}/status`);
    }

    if (parts[0] === "lobby" && parts.length === 3 && parts[2] === "ws") {
      const code = parts[1].toUpperCase();
      if (!new RegExp(`^[A-Z0-9]{${CODE_LENGTH}}$`).test(code)) {
        return json({ error: "That isn't a valid lobby code." }, 400);
      }
      const stub = env.LOBBY.get(env.LOBBY.idFromName(code));
      return stub.fetch(request);
    }

    return json({ error: "Not found" }, 404);
  },
};

// ---------------------------------------------------------------------------
// Lobby: one per private lobby code. Uses the WebSocket Hibernation API, so
// player info lives in socket attachments and lobby state in storage, never
// only in memory.
// ---------------------------------------------------------------------------
export class Lobby {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    // Keep-alive pings are answered without waking the object up.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'));
  }

  async fetch(request) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const code = (parts[1] ?? "").toUpperCase();

    if (parts[2] === "init") {
      if (await this.ctx.storage.get("created")) return new Response("taken", { status: 409 });
      await this.ctx.storage.put({ created: true, code, phase: "waiting", hostId: "", results: [] });
      await this.ctx.storage.setAlarm(Date.now() + LOBBY_TTL_MS);
      return new Response("ok");
    }

    if (parts[2] === "status") {
      const s = await this.ctx.storage.get(["created", "phase"]);
      return json({
        exists: Boolean(s.get("created")),
        phase: s.get("phase") ?? "",
        players: this.players().length,
        max: MAX_PLAYERS,
      });
    }

    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426, headers: CORS });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const state = await this.ctx.storage.get(["created", "phase"]);
    const players = this.players();
    let error = null;
    if (!state.get("created")) error = "Lobby not found. Check the code.";
    else if (state.get("phase") !== "waiting") error = "A race is in progress. Try again when it ends.";
    else if (players.length >= MAX_PLAYERS) error = "That lobby is full.";

    if (error) {
      // Accept, explain, close: browsers can't read the reason of a refused upgrade.
      server.accept();
      server.send(JSON.stringify({ t: "error", msg: error }));
      server.close(4000, "refused");
      return new Response(null, { status: 101, webSocket: client });
    }

    const id = crypto.randomUUID().slice(0, 8);
    const name = cleanName(url.searchParams.get("name"));
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ id, name });

    let hostId = await this.ctx.storage.get("hostId");
    if (!players.some((p) => p.id === hostId)) {
      hostId = id;
      await this.ctx.storage.put("hostId", hostId);
    }
    server.send(JSON.stringify({ t: "welcome", id, code }));
    await this.broadcastLobby();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const me = ws.deserializeAttachment();
    if (!me || typeof message !== "string" || message.length > 2048) return;
    let msg;
    try {
      msg = JSON.parse(message);
    } catch {
      return;
    }

    switch (msg.t) {
      case "s": // kart state
      case "i": // item used
        msg.id = me.id;
        this.broadcast(msg, ws);
        break;

      case "start": {
        if (me.id !== (await this.ctx.storage.get("hostId"))) return;
        await this.ctx.storage.put({ phase: "racing", results: [] });
        this.broadcast({ t: "start", players: this.players(), laps: LAPS });
        break;
      }

      case "f": {
        if ((await this.ctx.storage.get("phase")) !== "racing") return;
        const results = (await this.ctx.storage.get("results")) ?? [];
        const time = Number(msg.time);
        if (results.some((r) => r.id === me.id) || !Number.isFinite(time)) return;
        results.push({ id: me.id, name: me.name, time });
        await this.ctx.storage.put("results", results);
        this.broadcast({ t: "f", id: me.id, name: me.name, time, place: results.length });
        await this.maybeEndRace(results);
        break;
      }

      case "end": // host sends everyone back to the lobby
        if (me.id === (await this.ctx.storage.get("hostId"))) await this.endRace();
        break;
    }
  }

  async webSocketClose(ws) {
    await this.handleLeave(ws);
  }

  async webSocketError(ws) {
    await this.handleLeave(ws);
  }

  async handleLeave(ws) {
    const me = ws.deserializeAttachment();
    if (!me) return;
    ws.serializeAttachment(null);
    try {
      ws.close(1000, "left");
    } catch {}
    const players = this.players();
    if ((await this.ctx.storage.get("hostId")) === me.id) {
      await this.ctx.storage.put("hostId", players[0]?.id ?? "");
    }
    this.broadcast({ t: "leave", id: me.id });
    if ((await this.ctx.storage.get("phase")) === "racing") {
      await this.maybeEndRace((await this.ctx.storage.get("results")) ?? []);
    }
    await this.broadcastLobby();
  }

  async maybeEndRace(results) {
    const done = new Set(results.map((r) => r.id));
    if (this.players().every((p) => done.has(p.id))) await this.endRace();
  }

  async endRace() {
    await this.ctx.storage.put("phase", "waiting");
    await this.broadcastLobby();
  }

  async alarm() {
    if (this.players().length > 0) {
      await this.ctx.storage.setAlarm(Date.now() + LOBBY_TTL_MS);
    } else {
      await this.ctx.storage.deleteAll();
    }
  }

  players() {
    return this.ctx
      .getWebSockets()
      .map((ws) => ws.deserializeAttachment())
      .filter(Boolean);
  }

  async broadcastLobby() {
    const s = await this.ctx.storage.get(["code", "hostId", "phase"]);
    this.broadcast({
      t: "lobby",
      code: s.get("code"),
      host: s.get("hostId"),
      phase: s.get("phase"),
      players: this.players(),
      max: MAX_PLAYERS,
    });
  }

  broadcast(msg, except = null) {
    const text = JSON.stringify(msg);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === except || !ws.deserializeAttachment()) continue;
      try {
        ws.send(text);
      } catch {}
    }
  }
}

// ---------------------------------------------------------------------------
// Leaderboard: best time trial time per player name, per track.
// ---------------------------------------------------------------------------
export class Leaderboard {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS times (track TEXT NOT NULL, name TEXT NOT NULL, time REAL NOT NULL, created INTEGER NOT NULL)"
    );
    this.sql.exec("CREATE INDEX IF NOT EXISTS times_by_track ON times (track, time)");
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "GET") {
      const track = cleanTrack(url.searchParams.get("track"));
      return json({ track, entries: this.top(track) });
    }
    if (request.method === "POST") {
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "Bad request" }, 400);
      }
      const track = cleanTrack(body.track);
      const name = cleanName(body.name);
      const time = Math.round(Number(body.time) * 1000) / 1000;
      if (!Number.isFinite(time) || time < MIN_RACE_TIME || time > 3600) {
        return json({ error: "That time doesn't look right." }, 400);
      }
      this.sql.exec("INSERT INTO times (track, name, time, created) VALUES (?, ?, ?, ?)", track, name, time, Date.now());
      const faster = this.sql
        .exec(
          "SELECT COUNT(*) AS n FROM (SELECT name, MIN(time) AS best FROM times WHERE track = ? GROUP BY name) WHERE best < ? AND name != ?",
          track,
          time,
          name
        )
        .one().n;
      return json({ track, rank: faster + 1, entries: this.top(track) });
    }
    return json({ error: "Method not allowed" }, 405);
  }

  top(track) {
    return this.sql
      .exec(
        "SELECT name, MIN(time) AS time FROM times WHERE track = ? GROUP BY name ORDER BY time ASC LIMIT 10",
        track
      )
      .toArray();
  }
}
