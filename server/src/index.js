// Kart Racer game server: a Cloudflare Worker with three Durable Objects.
//
//   GET  /leaderboard?track=ID      -> top 10 time trial records
//   POST /leaderboard               -> submit {track, name, time, frames}
//   GET  /ghost?track=ID            -> the record holder's run, to race against
//   POST /lobby                     -> create a private lobby, returns {code}
//   POST /quickmatch                -> code of an open public lobby (or a new one)
//   GET  /lobby/CODE                -> does the lobby exist, its phase and size
//   GET  /lobby/CODE/ws?name=...    -> WebSocket into that lobby
//
// Each lobby is its own Durable Object, so every player in a lobby talks to
// the same instance. The leaderboard and the matchmaker are single objects
// backed by SQLite.

import TRACKS from "./tracks.js";
import { checkRun, cleanName } from "./validate.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};
const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I
const CODE_LENGTH = 5;
const CODE_RE = new RegExp(`^[A-Z0-9]{${CODE_LENGTH}}$`);
const MAX_PLAYERS = 6;
const LAPS = 3;
const LOBBY_TTL_MS = 24 * 60 * 60 * 1000;
const AUTOSTART_MS = 20 * 1000; // public lobbies start this long after 2+ players join
const BOT_GRACE_MS = 45 * 1000; // how long computer karts get to finish after the humans
const DIFFICULTIES = ["easy", "normal", "hard"];
const STYLES = ["classic", "speedster", "buggy"];
const BOT_COLORS = ["2a6bf2", "33bf4d", "f2bf1a", "994de6", "ff8019", "33ccd9", "f273bf"];
const SUBMITS_PER_WINDOW = 15;
const SUBMIT_WINDOW_MS = 10 * 60 * 1000;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

function trackId(raw) {
  const id = String(raw ?? "");
  return Object.hasOwn(TRACKS, id) ? id : "circuit_1";
}

function randomCode() {
  const bytes = new Uint8Array(CODE_LENGTH);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => CODE_CHARS[b % CODE_CHARS.length]).join("");
}

function randomToken() {
  return crypto.randomUUID().replaceAll("-", "");
}

function lobbyStub(env, code) {
  return env.LOBBY.get(env.LOBBY.idFromName(code));
}

async function createLobby(env, isPublic) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = randomCode();
    const res = await lobbyStub(env, code).fetch(`https://lobby/lobby/${code}/init`, {
      method: "POST",
      body: JSON.stringify({ public: isPublic }),
    });
    if (res.ok) return code;
  }
  return null;
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { headers: CORS });
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts.length === 0) return json({ ok: true, service: "kart-racer-server" });

    if ((parts[0] === "leaderboard" || parts[0] === "ghost") && parts.length === 1) {
      return env.LEADERBOARD.get(env.LEADERBOARD.idFromName("global")).fetch(request);
    }

    if (parts[0] === "quickmatch" && request.method === "POST") {
      return env.MATCHMAKER.get(env.MATCHMAKER.idFromName("global")).fetch("https://mm/quickmatch", { method: "POST" });
    }

    if (parts[0] === "lobby" && parts.length === 1 && request.method === "POST") {
      const code = await createLobby(env, false);
      return code ? json({ code }) : json({ error: "Could not create a lobby. Try again." }, 500);
    }

    if (parts[0] === "lobby" && parts.length >= 2) {
      const code = parts[1].toUpperCase();
      if (!CODE_RE.test(code)) {
        return parts.length === 2 ? json({ exists: false }) : json({ error: "That isn't a valid lobby code." }, 400);
      }
      if (parts.length === 2 && request.method === "GET") {
        return lobbyStub(env, code).fetch(`https://lobby/lobby/${code}/status`);
      }
      if (parts.length === 3 && parts[2] === "ws") {
        return lobbyStub(env, code).fetch(request);
      }
    }

    return json({ error: "Not found" }, 404);
  },
};

// ---------------------------------------------------------------------------
// Lobby: one per lobby code. Uses the WebSocket Hibernation API, so player
// info lives in socket attachments and lobby state in storage. Only the
// latest kart positions are kept in memory, for players who rejoin mid-race.
// ---------------------------------------------------------------------------
export class Lobby {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.lastState = new Map();
    // Keep-alive pings are answered without waking the object up.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"t":"ping"}', '{"t":"pong"}'));
  }

  async fetch(request) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const code = (parts[1] ?? "").toUpperCase();

    if (parts[2] === "init") {
      if (await this.ctx.storage.get("created")) return new Response("taken", { status: 409 });
      let body = {};
      try {
        body = await request.json();
      } catch {}
      await this.ctx.storage.put({
        created: true,
        code,
        public: Boolean(body.public),
        phase: "waiting",
        hostId: "",
        results: [],
        members: {},
        settings: { track: "circuit_1", bots: Boolean(body.public), difficulty: "normal" },
      });
      await this.scheduleAlarm(Date.now() + LOBBY_TTL_MS);
      return new Response("ok");
    }

    if (parts[2] === "status") {
      const s = await this.ctx.storage.get(["created", "phase", "public"]);
      return json({
        exists: Boolean(s.get("created")),
        phase: s.get("phase") ?? "",
        public: Boolean(s.get("public")),
        players: this.players().length,
        max: MAX_PLAYERS,
      });
    }

    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected a WebSocket", { status: 426, headers: CORS });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const s = await this.ctx.storage.get(["created", "phase", "members", "hostId"]);
    const members = s.get("members") ?? {};
    const players = this.players();

    // Rejoining with the id and token from an earlier connection keeps the
    // same identity, even in the middle of a race.
    const rejoinId = url.searchParams.get("rejoin") ?? "";
    const token = url.searchParams.get("token") ?? "";
    const rejoining =
      rejoinId && members[rejoinId] && members[rejoinId].token === token && !players.some((p) => p.id === rejoinId);

    let error = null;
    if (!s.get("created")) error = "Lobby not found. Check the code.";
    else if (s.get("phase") !== "waiting" && !rejoining) error = "A race is in progress. Try again when it ends.";
    else if (!rejoining && players.length >= MAX_PLAYERS) error = "That lobby is full.";
    if (error) {
      // Accept, explain, close: browsers can't read the reason of a refused upgrade.
      server.accept();
      server.send(JSON.stringify({ t: "error", msg: error }));
      server.close(4000, "refused");
      return new Response(null, { status: 101, webSocket: client });
    }

    let me;
    if (rejoining) {
      me = { id: rejoinId, name: members[rejoinId].name, color: members[rejoinId].color, style: members[rejoinId].style };
    } else {
      me = {
        id: crypto.randomUUID().slice(0, 8),
        name: cleanName(url.searchParams.get("name")),
        color: /^[0-9a-f]{6}$/i.test(url.searchParams.get("color") ?? "") ? url.searchParams.get("color").toLowerCase() : "e62633",
        style: STYLES.includes(url.searchParams.get("style")) ? url.searchParams.get("style") : "classic",
      };
    }
    const myToken = rejoining ? token : randomToken();
    members[me.id] = { ...me, token: myToken };
    await this.ctx.storage.put("members", members);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(me);

    let hostId = s.get("hostId");
    if (!players.some((p) => p.id === hostId)) {
      hostId = me.id;
      await this.ctx.storage.put("hostId", hostId);
    }

    const welcome = { t: "welcome", id: me.id, code, token: myToken, rejoined: Boolean(rejoining) };
    if (s.get("phase") === "racing") {
      const r = await this.ctx.storage.get(["roster", "settings", "startedAt", "results"]);
      welcome.race = {
        players: r.get("roster"),
        ...r.get("settings"),
        laps: LAPS,
        elapsed: (Date.now() - r.get("startedAt")) / 1000,
        results: r.get("results"),
        me: this.lastState.get(me.id) ?? null,
      };
      this.broadcast({ t: "back", id: me.id }, server);
    }
    server.send(JSON.stringify(welcome));
    await this.updateAutostart();
    await this.broadcastLobby();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const me = ws.deserializeAttachment();
    if (!me || typeof message !== "string" || message.length > 4096) return;
    let msg;
    try {
      msg = JSON.parse(message);
    } catch {
      return;
    }

    switch (msg.t) {
      case "s": // kart state
      case "i": {
        // item used
        const id = await this.senderId(me, msg);
        if (!id) return;
        delete msg.b;
        msg.id = id;
        if (msg.t === "s") this.lastState.set(id, msg);
        this.broadcast(msg, ws);
        break;
      }

      case "settings": {
        if (me.id !== (await this.ctx.storage.get("hostId"))) return;
        if ((await this.ctx.storage.get("phase")) !== "waiting") return;
        await this.ctx.storage.put("settings", {
          track: trackId(msg.track),
          bots: Boolean(msg.bots),
          difficulty: DIFFICULTIES.includes(msg.difficulty) ? msg.difficulty : "normal",
        });
        await this.broadcastLobby();
        break;
      }

      case "start":
        if (me.id !== (await this.ctx.storage.get("hostId"))) return;
        if ((await this.ctx.storage.get("phase")) !== "waiting") return;
        await this.startRace();
        break;

      case "f": {
        if ((await this.ctx.storage.get("phase")) !== "racing") return;
        const id = await this.senderId(me, msg);
        const roster = (await this.ctx.storage.get("roster")) ?? [];
        const racer = roster.find((p) => p.id === id);
        const time = Number(msg.time);
        if (!racer || !Number.isFinite(time)) return;
        const results = (await this.ctx.storage.get("results")) ?? [];
        if (results.some((r) => r.id === id)) return;
        results.push({ id, name: racer.name, time, bot: Boolean(racer.bot) });
        await this.ctx.storage.put("results", results);
        this.broadcast({ t: "f", id, name: racer.name, time, place: results.length });
        await this.maybeEndRace(results);
        break;
      }

      case "end": // host sends everyone back to the lobby
        if (me.id === (await this.ctx.storage.get("hostId"))) await this.endRace();
        break;
    }
  }

  // Bots belong to the host: the host's device drives them and reports for them.
  async senderId(me, msg) {
    if (!msg.b) return me.id;
    if (me.id !== (await this.ctx.storage.get("hostId"))) return null;
    const roster = (await this.ctx.storage.get("roster")) ?? [];
    return roster.some((p) => p.id === msg.b && p.bot) ? msg.b : null;
  }

  async startRace() {
    const settings = (await this.ctx.storage.get("settings")) ?? { track: "circuit_1", bots: false, difficulty: "normal" };
    const roster = this.players().map((p) => ({ ...p, bot: false }));
    if (settings.bots) {
      let n = 1;
      while (roster.length < MAX_PLAYERS) {
        roster.push({
          id: `bot${n}`,
          name: `CPU ${n}`,
          color: BOT_COLORS[(n - 1) % BOT_COLORS.length],
          style: STYLES[(n - 1) % STYLES.length],
          bot: true,
        });
        n++;
      }
    }
    this.lastState.clear();
    await this.ctx.storage.put({ phase: "racing", results: [], roster, startedAt: Date.now(), autostartAt: 0, endBy: 0 });
    this.broadcast({ t: "start", players: roster, ...settings, laps: LAPS });
    await this.reportToMatchmaker();
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
    if ((await this.ctx.storage.get("phase")) === "racing") {
      // They may come back: keep their kart and results.
      this.broadcast({ t: "drop", id: me.id });
      await this.maybeEndRace((await this.ctx.storage.get("results")) ?? []);
    } else {
      this.broadcast({ t: "leave", id: me.id });
    }
    await this.updateAutostart();
    await this.broadcastLobby();
  }

  // The race ends once every connected human has finished and the computer
  // karts have too (they get up to BOT_GRACE_MS to cross the line).
  async maybeEndRace(results) {
    const done = new Set(results.map((r) => r.id));
    const humans = this.players();
    if (!humans.every((p) => done.has(p.id))) return;
    const roster = (await this.ctx.storage.get("roster")) ?? [];
    const botsDone = roster.filter((p) => p.bot).every((p) => done.has(p.id));
    if (botsDone || humans.length === 0) {
      await this.endRace();
    } else if (!(await this.ctx.storage.get("endBy"))) {
      const at = Date.now() + BOT_GRACE_MS;
      await this.ctx.storage.put("endBy", at);
      await this.scheduleAlarm(at);
    }
  }

  async endRace() {
    await this.ctx.storage.put({ phase: "waiting", endBy: 0 });
    await this.updateAutostart();
    await this.broadcastLobby();
    await this.reportToMatchmaker();
  }

  // Public lobbies start by themselves a little while after 2+ players join.
  async updateAutostart() {
    const s = await this.ctx.storage.get(["public", "phase", "autostartAt"]);
    if (!s.get("public")) return;
    const ready = s.get("phase") === "waiting" && this.players().length >= 2;
    if (ready && !s.get("autostartAt")) {
      const at = Date.now() + AUTOSTART_MS;
      await this.ctx.storage.put("autostartAt", at);
      await this.scheduleAlarm(at);
    } else if (!ready && s.get("autostartAt")) {
      await this.ctx.storage.put("autostartAt", 0);
    }
    await this.reportToMatchmaker();
  }

  async scheduleAlarm(at) {
    const current = await this.ctx.storage.getAlarm();
    if (!current || at < current) await this.ctx.storage.setAlarm(at);
  }

  async alarm() {
    const s = await this.ctx.storage.get(["autostartAt", "phase", "created", "endBy"]);
    if (s.get("phase") === "racing" && s.get("endBy") && Date.now() >= s.get("endBy") - 50) {
      await this.endRace();
    }
    const autostartAt = s.get("autostartAt");
    if (autostartAt && Date.now() >= autostartAt - 50 && s.get("phase") === "waiting" && this.players().length >= 2) {
      await this.startRace();
    }
    if (this.players().length > 0 || !s.get("created")) {
      await this.ctx.storage.setAlarm(Date.now() + LOBBY_TTL_MS);
    } else {
      await this.reportToMatchmaker(true);
      await this.ctx.storage.deleteAll();
    }
  }

  async reportToMatchmaker(closed = false) {
    const s = await this.ctx.storage.get(["public", "code", "phase"]);
    if (!s.get("public") || !this.env.MATCHMAKER) return;
    const mm = this.env.MATCHMAKER.get(this.env.MATCHMAKER.idFromName("global"));
    await mm.fetch("https://mm/update", {
      method: "POST",
      body: JSON.stringify({ code: s.get("code"), players: this.players().length, phase: closed ? "closed" : s.get("phase") }),
    });
  }

  players() {
    return this.ctx
      .getWebSockets()
      .map((ws) => ws.deserializeAttachment())
      .filter(Boolean);
  }

  async broadcastLobby() {
    const s = await this.ctx.storage.get(["code", "hostId", "phase", "settings", "public", "autostartAt"]);
    const autostartAt = s.get("autostartAt");
    this.broadcast({
      t: "lobby",
      code: s.get("code"),
      host: s.get("hostId"),
      phase: s.get("phase"),
      players: this.players(),
      max: MAX_PLAYERS,
      settings: s.get("settings"),
      public: Boolean(s.get("public")),
      autostart_in: autostartAt ? Math.max(0, Math.round((autostartAt - Date.now()) / 1000)) : -1,
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
// Matchmaker: keeps track of public lobbies that have room.
// ---------------------------------------------------------------------------
export class Matchmaker {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.sql = ctx.storage.sql;
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS lobbies (code TEXT PRIMARY KEY, players INTEGER NOT NULL, phase TEXT NOT NULL, updated INTEGER NOT NULL)"
    );
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/update") {
      const b = await request.json();
      if (b.phase === "closed") this.sql.exec("DELETE FROM lobbies WHERE code = ?", b.code);
      else
        this.sql.exec(
          "INSERT INTO lobbies (code, players, phase, updated) VALUES (?, ?, ?, ?) ON CONFLICT(code) DO UPDATE SET players = excluded.players, phase = excluded.phase, updated = excluded.updated",
          b.code,
          b.players,
          b.phase,
          Date.now()
        );
      return new Response("ok");
    }
    if (url.pathname === "/quickmatch") {
      const now = Date.now();
      this.sql.exec("DELETE FROM lobbies WHERE updated < ?", now - 30 * 60 * 1000);
      const open = this.sql
        .exec(
          "SELECT code FROM lobbies WHERE phase = 'waiting' AND players < ? AND (players > 0 OR updated > ?) ORDER BY players DESC, updated DESC LIMIT 1",
          MAX_PLAYERS,
          now - 60 * 1000
        )
        .toArray();
      if (open.length) return json({ code: open[0].code, public: true });
      const code = await createLobby(this.env, true);
      if (!code) return json({ error: "Could not find a match. Try again." }, 500);
      this.sql.exec("INSERT OR REPLACE INTO lobbies (code, players, phase, updated) VALUES (?, 0, 'waiting', ?)", code, now);
      return json({ code, public: true });
    }
    return new Response("not found", { status: 404 });
  }
}

// ---------------------------------------------------------------------------
// Leaderboard: best time trial per player name, per track, with the run
// (ghost) that set it. Runs are checked before they count.
// ---------------------------------------------------------------------------
export class Leaderboard {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    this.submits = new Map(); // ip -> recent submit times
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS best (track TEXT NOT NULL, name TEXT NOT NULL, time REAL NOT NULL, ghost TEXT NOT NULL DEFAULT '', created INTEGER NOT NULL, PRIMARY KEY (track, name))"
    );
    // Bring over records from the first version of the server, if any.
    const old = this.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'times'").toArray();
    if (old.length) {
      this.sql.exec(
        "INSERT OR IGNORE INTO best (track, name, time, ghost, created) SELECT track, name, MIN(time), '', MAX(created) FROM times GROUP BY track, name"
      );
      this.sql.exec("DROP TABLE times");
    }
  }

  async fetch(request) {
    const url = new URL(request.url);
    const isGhost = url.pathname.startsWith("/ghost");

    if (request.method === "GET" && isGhost) {
      const track = trackId(url.searchParams.get("track"));
      const row = this.sql
        .exec("SELECT name, time, ghost FROM best WHERE track = ? AND ghost != '' ORDER BY time ASC LIMIT 1", track)
        .toArray()[0];
      if (!row) return json({ error: "No record run on this track yet." }, 404);
      return json({ track, name: row.name, time: row.time, frames: JSON.parse(row.ghost) });
    }

    if (request.method === "GET") {
      const track = trackId(url.searchParams.get("track"));
      return json({ track, entries: this.top(track) });
    }

    if (request.method === "POST") {
      const ip = request.headers.get("CF-Connecting-IP") ?? "local";
      if (!this.allowSubmit(ip)) return json({ error: "Too many submissions. Try again in a few minutes." }, 429);
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "Bad request" }, 400);
      }
      if (!Object.hasOwn(TRACKS, String(body.track))) return json({ error: "Unknown track." }, 400);
      const track = String(body.track);
      const name = cleanName(body.name);
      const time = Math.round(Number(body.time) * 1000) / 1000;
      const problem = checkRun(TRACKS[track], time, body.frames);
      if (problem) return json({ error: `Not counted: ${problem}` }, 400);

      const prev = this.sql.exec("SELECT time FROM best WHERE track = ? AND name = ?", track, name).toArray()[0];
      const improved = !prev || time < prev.time;
      if (improved) {
        this.sql.exec(
          "INSERT INTO best (track, name, time, ghost, created) VALUES (?, ?, ?, ?, ?) ON CONFLICT(track, name) DO UPDATE SET time = excluded.time, ghost = excluded.ghost, created = excluded.created",
          track,
          name,
          time,
          JSON.stringify(body.frames),
          Date.now()
        );
      }
      const faster = this.sql
        .exec("SELECT COUNT(*) AS n FROM best WHERE track = ? AND time < ? AND name != ?", track, time, name)
        .one().n;
      return json({ track, rank: faster + 1, improved, entries: this.top(track) });
    }
    return json({ error: "Method not allowed" }, 405);
  }

  allowSubmit(ip) {
    const now = Date.now();
    const recent = (this.submits.get(ip) ?? []).filter((t) => now - t < SUBMIT_WINDOW_MS);
    if (recent.length >= SUBMITS_PER_WINDOW) return false;
    recent.push(now);
    this.submits.set(ip, recent);
    return true;
  }

  top(track) {
    return this.sql
      .exec("SELECT name, time, ghost != '' AS has_ghost FROM best WHERE track = ? ORDER BY time ASC LIMIT 10", track)
      .toArray();
  }
}
