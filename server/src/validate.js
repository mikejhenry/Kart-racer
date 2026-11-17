// Checks that an uploaded time trial run could really have happened.
//
// The game records its kart 10 times a second as [x, y, z, yaw]. A run is
// accepted when it:
//   - has about the right number of frames for its time,
//   - starts near the start line,
//   - never moves faster than any kart can,
//   - passes every checkpoint, in order, on all three laps,
//   - ends back at the start line,
//   - isn't faster than the track's minimum possible time.

const FRAMES_PER_SECOND = 10;
const MAX_STEP = 5.0; // metres per frame (50 m/s, above top speed + boost)
const CHECKPOINT_RADIUS = 20.0;
const START_RADIUS = 45.0;
const LAPS = 3;

export function checkRun(track, time, frames) {
  if (!track) return "Unknown track.";
  if (!Number.isFinite(time) || time < track.min_time) return "That time is faster than possible.";
  if (!Array.isArray(frames) || frames.length < 10) return "Missing run data.";
  const expected = time * FRAMES_PER_SECOND;
  if (Math.abs(frames.length - expected) > 4) return "Run data doesn't match the time.";

  const pts = [];
  for (const f of frames) {
    if (!Array.isArray(f) || f.length < 3) return "Bad run data.";
    // Accept [x, z, yaw] (older ghosts) or [x, y, z, yaw]
    const x = Number(f[0]);
    const z = Number(f.length >= 4 ? f[2] : f[1]);
    if (!Number.isFinite(x) || !Number.isFinite(z)) return "Bad run data.";
    pts.push([x, z]);
  }

  const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
  if (dist(pts[0], track.start) > START_RADIUS) return "Run doesn't start at the start line.";
  for (let i = 1; i < pts.length; i++) {
    if (dist(pts[i], pts[i - 1]) > MAX_STEP) return "Run moves faster than a kart can.";
  }

  let i = 0;
  for (let lap = 0; lap < LAPS; lap++) {
    for (const cp of track.checkpoints) {
      while (i < pts.length && dist(pts[i], cp) > CHECKPOINT_RADIUS) i++;
      if (i >= pts.length) return `Run misses checkpoints on lap ${lap + 1}.`;
    }
  }
  while (i < pts.length && dist(pts[i], track.start) > START_RADIUS) i++;
  if (i >= pts.length) return "Run doesn't finish at the line.";
  return null;
}

// --- Player names -----------------------------------------------------------

const BLOCKED = [
  "fuck", "shit", "bitch", "cunt", "nigg", "fag", "whore", "slut", "dick", "cock",
  "pussy", "rape", "nazi", "hitler", "penis", "vagina", "porn", "anal", "retard",
];
const LEET = { 0: "o", 1: "i", 3: "e", 4: "a", 5: "s", 7: "t", "@": "a", $: "s", "!": "i" };

export function cleanName(raw) {
  const name = String(raw ?? "").replace(/[^\w .\-]/g, "").trim().slice(0, 16);
  if (!name) return "Racer";
  const flat = name.toLowerCase().replace(/[013457@$!]/g, (c) => LEET[c]).replace(/[^a-z]/g, "");
  return BLOCKED.some((w) => flat.includes(w)) ? "Racer" : name;
}
