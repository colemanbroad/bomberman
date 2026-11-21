// Multiplayer Bomberman. The host runs the simulation and serves WebSocket clients on port 8080;
// clients send key bits and draw the snapshots they get back.
//   goose build bomberman.goose && ./bomberman host      (or: ./bomberman join HOST, ./bomberman)
//   Arrows/WASD move, Space drops a bomb. `-- --frames N` runs a bot for N frames, then prints.

import std;
import math;
import os;
import gfx;
import ui;
import audio;
import http from "github.com/kaitk/goose-http@v0.5.20";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import tls from "github.com/kaitk/goose-tls@v0.0.6";
import http.websocket;
import http.wsclient;

let W = 15;
let H = 13;
let TILE = 64;
let HB = 22;                 // half width of a player's box
let FUSE = 150;              // sim ticks (60 Hz)
let UP = 1;
let DOWN = 2;
let LEFT = 4;
let RIGHT = 8;
let BOMB = 16;
let HOLD = 32;               // stand your ground: you can't move, and others can't walk through you
let SLIDE = 5;               // ticks a kicked bomb takes per tile
let GHOST = 600;             // ghost power-up length in ticks

// Tile values: 0 empty, 1 wall, 2 brick, 3 range+, 4 bomb+, 5 speed+, 8 ghost, 9 kick, 6 steel crate (two hits), 7 gift crate (always drops),
// 16+ttl flame, 32+ttl flame over a brick (may drop), 48+ttl flame over a gift (drops).
let CHAR_GOOSE: u8 = 0;
let CHAR_SQUIRREL: u8 = 1;
let CHAR_BABY: u8 = 2;
let CHAR_COW: u8 = 3;
let CHAR_PIG: u8 = 4;
let CHAR_FARMER: u8 = 5;

fn default_kind(slot: i64) -> u8 {
    if slot == 0 { return CHAR_FARMER; }
    if slot == 1 { return CHAR_GOOSE; }
    if slot == 2 { return CHAR_COW; }
    return CHAR_PIG;
}

let MAP_ISLAND: u8 = 0;
let MAP_FOREST: u8 = 1;
let MAP_MOUNTAINS: u8 = 2;
let MAP_DESERT: u8 = 3;

fn map_name(m: u8) -> const u8[:] {
    if m == MAP_ISLAND { return "Island"; }
    if m == MAP_FOREST { return "Forest"; }
    if m == MAP_MOUNTAINS { return "Mountains"; }
    return "Desert";
}

let ROBOTO: const u8[:] = embed_file("Roboto-Regular.ttf");
struct Player { x: i64, y: i64, on: u8, alive: u8, bombs: u8, range: u8, speed: u8, wins: u8, streak: u8, bits: u8, held: u8, placed: u8, ghost: u16, kick: u8, kind: u8, name: u8[..12] }
// dir: 0 still, 1 up, 2 down, 3 left, 4 right (a kicked bomb slides); m: ticks since its last step.
struct Bomb { x: u8, y: u8, t: u8, range: u8, owner: u8, dir: u8, m: u8 }
// A sheep wanders at random and blocks the way like a movable block. dir: 0 up, 1 down, 2 left, 3 right, 4 grazing.
struct Sheep { x: i64, y: i64, alive: u8, dir: u8, t: u8 }
struct State { grid: u8[195], players: Player[4], bombs: Bomb[..16], sheep: Sheep[2], drops: u8, map: u8, over: i64, dance_who: u8, you: u8, ack: i64, tick: i64 }   // drops: percent of brick fires that leave a power-up

// UDP (udp.c): inputs and snapshots fly as datagrams when a client joins with `udp`; the WebSocket stays up for
// joining, leaving and a slow heartbeat. Each snapshot carries its tick, so stale or reordered ones are dropped.
extern fn udp_open(port: i64) -> i64;
extern fn udp_peer(host: const u8[:], port: i64) -> i64;
extern fn udp_send(fd: i64, b: const u8[:], peer: i64) -> i64;
extern fn udp_recv(fd: i64, b: u8[:], from: i64&) -> i64;

// Host: input or profile update from a connection (reply names it). Client: key bits or profile to send.
// seq numbers a client's input steps; the host echoes the latest one it has seen in State.ack.
struct Msg { reply: http::MailAddress, bits: u8, leave: bool, seq: i64, is_profile: bool, kind: u8, name: u8[..12] }
struct Pad { bits: u8, seq: i64 }
struct Profile { kind: u8, name: u8[..12] }
struct Lost { code: i64 }

fn player_name(s: State&, i: i64, out: u8[>..]&) {
    out.resize(0);
    if s.players[i].name.len > 0 { out.append(s.players[i].name[..]); }
    else { format(out, "P", i + 1); }
}

// ---- simulation -------------------------------------------------------------------------------

fn bomb_at(s: State&, tx: i64, ty: i64) -> i64 {
    for i in s.bombs.len { if s.bombs[i].x == tx && s.bombs[i].y == ty { return i; } }
    return -1;
}

fn hits(ax: i64, ay: i64, bx: i64, by: i64) -> bool { return abs(ax - bx) < 2 * HB && abs(ay - by) < 2 * HB; }

// Does a box centered at x y hit a wall, block, or a bomb that the box (now at ox oy) is not already standing on?
fn tiles_blocked(s: State&, ox: i64, oy: i64, x: i64, y: i64) -> bool {
    for ty in (y - HB) / TILE..(y + HB - 1) / TILE + 1 {
        for tx in (x - HB) / TILE..(x + HB - 1) / TILE + 1 {
            let g = s.grid[ty * W + tx];
            if g == 1 || g == 2 { return true; }
            let on_it = tx >= (ox - HB) / TILE && tx <= (ox + HB - 1) / TILE &&
                        ty >= (oy - HB) / TILE && ty <= (oy + HB - 1) / TILE;
            if bomb_at(s, tx, ty) >= 0 && !on_it { return true; }
        }
    }
    return false;
}

// Player i, moving to x y, is stopped by tiles, holding players, and sheep (unless already overlapping them).
fn blocked(s: State&, i: i64, x: i64, y: i64) -> bool {
    let p = s.players[i];
    for j in 4 {
        let q = s.players[j];
        guard j != i && q.on != 0 && q.alive != 0 && (q.bits & HOLD) != 0 else { continue; }
        if hits(x, y, q.x, q.y) && !hits(p.x, p.y, q.x, q.y) { return true; }
    }
    for k in 2 {
        let q = s.sheep[k];
        if q.alive != 0 && hits(x, y, q.x, q.y) && !hits(p.x, p.y, q.x, q.y) { return true; }
    }
    return tiles_blocked(s, p.x, p.y, x, y);
}

fn sheep_blocked(s: State&, k: i64, x: i64, y: i64) -> bool {
    let me = s.sheep[k];
    for j in 4 {
        let q = s.players[j];
        if q.on != 0 && q.alive != 0 && hits(x, y, q.x, q.y) && !hits(me.x, me.y, q.x, q.y) { return true; }
    }
    for j in 2 {
        let q = s.sheep[j];
        if j != k && q.alive != 0 && hits(x, y, q.x, q.y) && !hits(me.x, me.y, q.x, q.y) { return true; }
    }
    return tiles_blocked(s, me.x, me.y, x, y);
}

fn reset_round(s: State&, r: rng&) {
    for ty in H {
        for tx in W {
            var g: u8 = 0;
            let cx = min(tx, W - 1 - tx);
            let cy = min(ty, H - 1 - ty);
            let is_border = cx == 0 || cy == 0;
            var is_pillar = tx % 2 == 0 && ty % 2 == 0;
            // Subtle symmetric map layout flavor per biome
            if s.map == MAP_ISLAND && tx >= 6 && tx <= 8 && ty >= 5 && ty <= 7 { is_pillar = false; }
            else if s.map == MAP_DESERT && (tx == 4 || tx == 10) && (ty == 4 || ty == 8) { is_pillar = false; }
            else if s.map == MAP_MOUNTAINS && (tx == 4 || tx == 10) && ty == 6 { is_pillar = true; }
            let density = if s.map == MAP_FOREST { 8 } else if s.map == MAP_DESERT { 6 } else { 7 };
            if is_border || is_pillar { g = 1; }
            else if cx + cy > 3 && r.rand_int(10) < density {
                let k = r.rand_int(100);
                g = if k < 8 { 6 } else if k < 15 { 7 } else { 2 };
            }
            s.grid[ty * W + tx] = g;
        }
    }
    for i in 4 {
        let p = s.players[i];
        if p.on == 0 { continue; }
        s.players[i].x = (if i % 2 == 0 { 1 } else { W - 2 }) * TILE + TILE / 2;
        s.players[i].y = (if i < 2 { 1 } else { H - 2 }) * TILE + TILE / 2;
        s.players[i].alive = 1;
        s.players[i].bombs = 1;
        s.players[i].range = 2;
        s.players[i].speed = 0;
        s.players[i].placed = 0;
        s.players[i].held = 0;
        s.players[i].ghost = 0;
        s.players[i].kick = 0;
    }
    for k in 2 {
        let tx = if k == 0 { 5 } else { W - 6 };
        s.grid[(H / 2) * W + tx] = 0;
        s.sheep[k] = Sheep { tx * TILE + TILE / 2, (H / 2) * TILE + TILE / 2, 1, 4, 0 };
    }
    s.bombs.resize(0);
    s.over = 0;
    s.dance_who = 255;
}

fn flame(s: State&, i: i64) {
    let g = s.grid[i];
    s.grid[i] = if g == 6 { 2 } else if g == 7 || g >= 48 { 63 } else if g == 2 || g >= 32 { 47 } else { 31 };
}

// Bomb b burns: flames along four arms; blocks stop an arm, other bombs are set off.
fn explode(s: State&, b: Bomb) {
    flame(s, b.y * W + b.x);
    for d in 4 {
        let dx = if d == 0 { 1 } else if d == 1 { -1 } else { 0 };
        let dy = if d == 2 { 1 } else if d == 3 { -1 } else { 0 };
        for k in 1..b.range + 1 {
            let tx = b.x + dx * k;
            let ty = b.y + dy * k;
            let g = s.grid[ty * W + tx];
            if g == 1 { break; }
            flame(s, ty * W + tx);
            if g == 2 || g == 6 || g == 7 { break; }
            let o = bomb_at(s, tx, ty);
            if o >= 0 { s.bombs[o].t = 0; break; }
        }
    }
}

// Index of a bomb that player i's box would run into at x y (one it is not already standing on), or -1.
fn bomb_ahead(s: State&, i: i64, x: i64, y: i64) -> i64 {
    let p = s.players[i];
    for ty in (y - HB) / TILE..(y + HB - 1) / TILE + 1 {
        for tx in (x - HB) / TILE..(x + HB - 1) / TILE + 1 {
            let on_it = tx >= (p.x - HB) / TILE && tx <= (p.x + HB - 1) / TILE &&
                        ty >= (p.y - HB) / TILE && ty <= (p.y + HB - 1) / TILE;
            if !on_it && bomb_at(s, tx, ty) >= 0 { return bomb_at(s, tx, ty); }
        }
    }
    return -1;
}

// Can a sliding bomb not enter tile nx ny? Walls, crates, flames, bombs, sheep and holding players stop it.
fn bomb_stopped(s: State&, nx: i64, ny: i64) -> bool {
    let g = s.grid[ny * W + nx];
    if g == 1 || g == 2 || g == 6 || g == 7 || g >= 16 || bomb_at(s, nx, ny) >= 0 { return true; }
    let cx = nx * TILE + TILE / 2;
    let cy = ny * TILE + TILE / 2;
    for k in 2 {
        let q = s.sheep[k];
        if q.alive != 0 && abs(q.x - cx) < TILE / 2 + HB && abs(q.y - cy) < TILE / 2 + HB { return true; }
    }
    for j in 4 {
        let q = s.players[j];
        if q.on != 0 && q.alive != 0 && (q.bits & HOLD) != 0 && abs(q.x - cx) < TILE / 2 + HB && abs(q.y - cy) < TILE / 2 + HB { return true; }
    }
    return false;
}

fn step_player(s: State&, i: i64) {
    let sp = 5 + s.players[i].speed as i64;
    let bits = s.players[i].bits;
    var dx = 0;
    var dy = 0;
    if (bits & UP) != 0 { dy = -sp; }
    else if (bits & DOWN) != 0 { dy = sp; }
    else if (bits & LEFT) != 0 { dx = -sp; }
    else if (bits & RIGHT) != 0 { dx = sp; }
    if (bits & HOLD) != 0 { dx = 0; dy = 0; }
    if s.players[i].ghost > 0 { s.players[i].ghost -= 1; }
    let x = s.players[i].x;
    let y = s.players[i].y;
    if s.players[i].kick != 0 && (dx != 0 || dy != 0) {          // running into a bomb kicks it
        let b = bomb_ahead(s, i, x + dx, y + dy);
        if b >= 0 && s.bombs[b].dir == 0 {
            s.bombs[b].dir = if dy < 0 { 1 } else if dy > 0 { 2 } else if dx < 0 { 3 } else { 4 };
            s.bombs[b].m = 0;
        }
    }
    if dx == 0 && dy == 0 {
    } else if !blocked(s, i, x + dx, y + dy) {
        s.players[i].x = x + dx;
        s.players[i].y = y + dy;
    } else if dx != 0 {          // slide around a corner toward the row's center
        let off = (y / TILE) * TILE + TILE / 2 - y;
        let st = max(-sp, min(sp, off));
        if abs(off) <= 24 && !blocked(s, i, x, y + st) { s.players[i].y = y + st; }
    } else if dy != 0 {
        let off = (x / TILE) * TILE + TILE / 2 - x;
        let st = max(-sp, min(sp, off));
        if abs(off) <= 24 && !blocked(s, i, x + st, y) { s.players[i].x = x + st; }
    }
    let tx = s.players[i].x / TILE;
    let ty = s.players[i].y / TILE;
    let g = s.grid[ty * W + tx];
    if (g >= 3 && g <= 5) || g == 8 || g == 9 {
        if g == 3 { s.players[i].range += 1; }
        if g == 4 { s.players[i].bombs += 1; }
        if g == 5 && s.players[i].speed < 3 { s.players[i].speed += 1; }
        if g == 8 { s.players[i].ghost = GHOST; }
        if g == 9 { s.players[i].kick = 1; }
        s.grid[ty * W + tx] = 0;
    }
    let p = s.players[i];
    if (bits & BOMB) != 0 && p.held == 0 && p.placed < p.bombs && bomb_at(s, tx, ty) < 0 {
        s.bombs.push(Bomb { tx as u8, ty as u8, FUSE, p.range, i as u8, 0, 0 });
        s.players[i].placed += 1;
    }
    s.players[i].held = if (bits & BOMB) != 0 { 1 } else { 0 };
}

// One 60 Hz step: move, burn, age flames, kill, and decide when a round ends.
fn tick(s: State&, r: rng&, n: i64) {
    if s.over > 0 {
        s.over -= 1;
        if s.over == 0 { reset_round(s, r); }
        return;
    }
    for i in 4 { if s.players[i].on != 0 && s.players[i].alive != 0 { step_player(s, i); } }
    for k in 2 {
        guard s.sheep[k].alive != 0 else { continue; }
        if s.sheep[k].t == 0 {
            s.sheep[k].dir = r.rand_int(5) as u8;
            s.sheep[k].t = (40 + r.rand_int(80)) as u8;
        } else { s.sheep[k].t -= 1; }
        let d = s.sheep[k].dir;
        let dx = if d == 2 { -2 } else if d == 3 { 2 } else { 0 };
        let dy = if d == 0 { -2 } else if d == 1 { 2 } else { 0 };
        if d == 4 { continue; }
        if sheep_blocked(s, k, s.sheep[k].x + dx, s.sheep[k].y + dy) { s.sheep[k].t = 0; }
        else { s.sheep[k].x += dx; s.sheep[k].y += dy; }
    }
    for i in s.bombs.len { s.bombs[i].t -= 1; }
    for i in s.bombs.len {
        guard s.bombs[i].dir != 0 else { continue; }
        s.bombs[i].m += 1;
        guard s.bombs[i].m >= SLIDE else { continue; }
        s.bombs[i].m = 0;
        let b = s.bombs[i];
        let nx = b.x as i64 + (if b.dir == 3 { -1 } else if b.dir == 4 { 1 } else { 0 });
        let ny = b.y as i64 + (if b.dir == 1 { -1 } else if b.dir == 2 { 1 } else { 0 });
        if bomb_stopped(s, nx, ny) { s.bombs[i].dir = 0; }
        else { s.bombs[i].x = nx as u8; s.bombs[i].y = ny as u8; }
    }
    loop {
        var again = false;
        var i = 0;
        while i < s.bombs.len {
            if s.bombs[i].t == 0 {
                let b = s.bombs[i];
                remove_at(s.bombs, i);
                s.players[b.owner].placed -= 1;
                explode(s, b);
                again = true;
            } else { i += 1; }
        }
        if !again { break; }
    }
    if n % 2 == 0 {
        for i in W * H {
            let g = s.grid[i];
            if g < 16 { continue; }
            if g % 16 > 0 { s.grid[i] = g - 1; }
            else if g >= 48 || (g >= 32 && r.rand_int(100) < s.drops as i64) {
                let k = r.rand_int(5);
                s.grid[i] = if k == 3 { 8 } else if k == 4 { 9 } else { 3 + k as u8 };
            }
            else { s.grid[i] = 0; }
        }
    }
    for k in 2 {
        if s.sheep[k].alive != 0 && s.grid[(s.sheep[k].y / TILE) * W + s.sheep[k].x / TILE] >= 16 { s.sheep[k].alive = 0; }
    }
    var joined = 0;
    var alive = 0;
    var last = 0;
    for i in 4 {
        guard s.players[i].on != 0 else { continue; }
        joined += 1;
        if s.players[i].alive != 0 {
            if s.grid[(s.players[i].y / TILE) * W + s.players[i].x / TILE] >= 16 { s.players[i].alive = 0; }
            else { alive += 1; last = i; }
        }
    }
    if (joined > 1 && alive <= 1) || (joined == 1 && alive == 0) {
        s.over = 150;
        s.dance_who = 255;
        if joined > 1 && alive == 1 {
            s.players[last].wins += 1;
            s.players[last].streak += 1;
            for i in 4 { if i != last { s.players[i].streak = 0; } }
            if s.players[last].wins % 5 == 0 {
                s.over = 270;
                s.dance_who = last as u8;
            }
        } else {
            for i in 4 { s.players[i].streak = 0; }
        }
    }
}

// ---- network ----------------------------------------------------------------------------------

struct Conn { ws: http::WebSocket = http::WebSocket { limit: 8192, .. }, reply: http::MailAddress }

fn serve_event(ev: http::Event, st: Conn&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        http::ws_upgrade(ev.req, st.ws, out);
    } else if ev.kind == http::WAKE {
        http::ws_send(out, http::WS_BINARY, ev.data);       // a snapshot mailed by the game
        http::later(out, 5000);
    } else if ev.kind == http::TIMEOUT {
        http::later(out, 5000);
    } else {
        if ev.kind == http::CLOSED && st.reply.key != 0 { qput(Msg { st.reply, 0, true, 0, false, 0, [] }); }
        http::ws_read(ev, st.ws, out) { op, data, o =>
            if st.reply.key == 0 { st.reply = http::later(o, 5000); }
            if data.len >= 3 && data[0] == 255 {
                let kd = if data[1] <= 5 { data[1] } else { 0 as u8 };
                var nm: u8[..12] = [];
                let ln = min(data[2] as i64, min(12, data.len - 3));
                for k in ln { nm.push(data[3 + k]); }
                qput(Msg { st.reply, 0, false, 0, true, kd, nm });
            } else if data.len >= 3 {
                qput(Msg { st.reply, data[0], false, (data[1] as i64) | ((data[2] as i64) << 8), false, 0, [] });
            }
        };
    }
}

thread_fn server(cfg: http::Config) {
    http::report(http::serve(cfg, Conn { .. }) { ev, st, out => serve_event(ev, st, out); });
}

// Joins ws://url: sends the key bits and profile updates main queues, and queues each snapshot back to main.
thread_fn client(url: u8[..64]) {
    var session = http::session();
    var conn, err = http::ws_client_connect(session, url[..]);
    guard err.code == 0 else { write_stderr(str("connect: ", err.call, " ", err.code, "\n")); qput(Lost { 1 }); return; }
    var bits: u8 = 0;
    var seq = 0;
    loop {
        var prof_ok = false;
        var prof = Profile { .. };
        loop {
            let pr, ok = qpoll<Profile>();
            guard ok else { break; }
            prof = pr;
            prof_ok = true;
        }
        if prof_ok {
            var pkt: u8[>..] = [];
            pkt.push(255);
            pkt.push(prof.kind);
            pkt.push(prof.name.len as u8);
            for k in prof.name.len { pkt.push(prof.name[k]); }
            guard http::ws_client_binary(conn, pkt).code == 0 else { break; }
        }
        var one: u8[>..] = [];
        one.push(bits);
        one.push((seq & 255) as u8);
        one.push((seq >> 8) as u8);
        guard http::ws_client_binary(conn, one).code == 0 else { break; }
        let m, e = http::ws_client_recv(conn);
        guard e.code == 0 else { break; }
        var s = State { .. };
        if http::mail_value(m.data, s) { qput(s); }
        loop {
            let p, ok = qpoll<Pad>();
            guard ok else { break; }
            bits = p.bits;
            seq = p.seq;
        }
    }
    qput(Lost { 2 });
}

// ---- sound ------------------------------------------------------------------------------------

struct Sfx { place: audio::Sound, boom: audio::Sound, pickup: audio::Sound, die: audio::Sound, win: audio::Sound, clank: audio::Sound, dance: audio::Sound }
struct Fx { shake: f32, lost: bool, dust: float4[..64], last: float2[4] }

// A synthesized effect: a sine sweeping f0 to f1 mixed with low-passed noise, under a decaying envelope.
fn synth(r: rng&, secs: f64, f0: f64, f1: f64, noise: f64, decay: f64) -> audio::Sound {
    var pcm: f32[>..] = [];
    let n = (secs * 48000.0) as i64;
    var phase = 0.0;
    var lp = 0.0;
    for i in n {
        let u = (i as f64) / (n as f64);
        phase += TAU * (f0 + (f1 - f0) * u) / 48000.0;
        lp += 0.2 * (r.rand_flt() * 2.0 - 1.0 - lp);
        let env = exp(-decay * u) * min(1.0, (i as f64) / 150.0);
        pcm.push(max(-1.0, min(1.0, (sin(phase) * (1.0 - noise) + lp * 3.0 * noise) * 0.5 * env)) as f32);
    }
    return audio::create_sound(pcm);
}

// Upbeat celebratory fanfare for the every-5-wins victory dance.
fn make_dance_sfx() -> audio::Sound {
    let notes: i64[8] = [60, 64, 67, 72, 67, 72, 76, 84];
    let step = 6400;
    var pcm: f32[>..] = [];
    pcm.resize(8 * step + 16000, 0.0);
    for k in 8 {
        let at = k * step;
        let len = if k == 7 { step + 14000 } else { step };
        voice(pcm, at, len, notes[k], 0, 0.35);
        voice(pcm, at, len, notes[k] - 12, 2, 0.45);
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.6)); }
    return audio::create_sound(pcm);
}

fn make_sfx(r: rng&) -> Sfx {
    Sfx { synth(r, 0.12, 220.0, 110.0, 0.1, 6.0), synth(r, 0.7, 90.0, 35.0, 0.85, 4.5), synth(r, 0.25, 500.0, 1100.0, 0.0, 5.0),
          synth(r, 0.6, 400.0, 60.0, 0.1, 3.0), synth(r, 0.7, 523.0, 1318.0, 0.0, 2.0), synth(r, 0.1, 1200.0, 800.0, 0.5, 12.0),
          make_dance_sfx() }
}

// Adds midi note m at sample `at` for n samples: kind 0 is a 50% pulse, 1 a 25% pulse, 2 a triangle.
fn voice(pcm: f32[>..]&, at: i64, n: i64, m: i64, kind: i64, vol: f64) {
    let f = 440.0 * exp(((m - 69) as f64) / 12.0 * 0.6931471805599453);
    for i in n {
        let x = f * (i as f64) / 48000.0;
        let ph = x - floor(x);
        let w = if kind == 0 { if ph < 0.5 { 1.0 } else { -1.0 } }
                else if kind == 1 { if ph < 0.25 { 1.0 } else { -1.0 } }
                else { if ph < 0.5 { 4.0 * ph - 1.0 } else { 3.0 - 4.0 * ph } };
        pcm[at + i] += (w * vol * exp(-3.0 * (i as f64) / (n as f64)) * min(1.0, (i as f64) / 100.0)) as f32;
    }
}

// Adds a drum hit: noise (snare, hat) or a falling sine (kick).
fn drum(r: rng&, pcm: f32[>..]&, at: i64, n: i64, kick: bool, vol: f64) {
    var phase = 0.0;
    for i in n {
        let u = (i as f64) / (n as f64);
        phase += TAU * (150.0 - 105.0 * u) / 48000.0;
        let w = if kick { sin(phase) } else { r.rand_flt() * 2.0 - 1.0 };
        pcm[at + i] += (w * vol * exp(-5.0 * u)) as f32;
    }
}

// A looping chiptune in A minor (Am F C G): pulse-wave arpeggios, a triangle bass and a drum beat; 8 bars of 8 steps.
fn make_music(r: rng&) -> audio::Sound {
    let step = 9600;
    var pcm: f32[>..] = [];
    pcm.resize(64 * step, 0.0);
    let roots: i64[4] = [45, 41, 48, 43];
    let tones: i64[12] = [69, 72, 76, 65, 69, 72, 67, 72, 76, 67, 71, 74];
    let pat: i64[8] = [0, 1, 2, 1, 0, 2, 1, 2];
    for b in 8 {
        let c = (b / 2) % 4;
        for s in 8 {
            let at = (b * 8 + s) * step;
            let n = step * 9 / 10;
            voice(pcm, at, n, roots[c] + (s % 2) * 12, 2, 0.5);
            if !(s == 3 && b % 2 == 1) {
                let k = if b >= 4 { pat[7 - s] } else { pat[s] };
                voice(pcm, at, n, tones[c * 3 + k] + (if b >= 6 { 12 } else { 0 }), if b >= 4 { 1 } else { 0 }, 0.16);
            }
            if s % 4 == 0 { drum(r, pcm, at, step / 2, true, 0.6); }
            if s % 4 == 2 { drum(r, pcm, at, step / 3, false, 0.3); }
            drum(r, pcm, at, step / 8, false, 0.07);
        }
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.5)); }
    return audio::create_sound(pcm);
}

// An 808-style sub bass note: a sine that drops in pitch, driven into soft clipping for grit.
fn sub(pcm: f32[>..]&, at: i64, n: i64, m: i64, vol: f64) {
    let f = 440.0 * exp(((m - 69) as f64) / 12.0 * 0.6931471805599453);
    var phase = 0.0;
    for i in n {
        let u = (i as f64) / (n as f64);
        phase += TAU * f * (1.0 + 0.6 * exp(-25.0 * u)) / 48000.0;
        let w = max(-0.8, min(0.8, 1.6 * sin(phase)));
        pcm[at + i] += (w * vol * exp(-1.6 * u) * min(1.0, (i as f64) / 60.0)) as f32;
    }
}

// A slow pad swell: two detuned triangle waves under a sine envelope.
fn swell(pcm: f32[>..]&, at: i64, n: i64, m: i64, vol: f64) {
    let f = 440.0 * exp(((m - 69) as f64) / 12.0 * 0.6931471805599453);
    for i in n {
        let u = (i as f64) / (n as f64);
        let x = f * (i as f64) / 48000.0;
        let y = f * 1.006 * (i as f64) / 48000.0;
        let a = x - floor(x);
        let b = y - floor(y);
        let w = (if a < 0.5 { 4.0 * a - 1.0 } else { 3.0 - 4.0 * a }) + (if b < 0.5 { 4.0 * b - 1.0 } else { 3.0 - 4.0 * b });
        pcm[at + i] += (w * 0.5 * vol * sin(3.141592653589793 * u)) as f32;
    }
}

// An original dark, heavy loop (75 BPM, D minor: Dm Bb Gm A): 808 bass, pulse-wave piano stabs, a pad and a boom-bap beat; 8 bars.
fn make_dark(r: rng&) -> audio::Sound {
    let step = 19200;
    var pcm: f32[>..] = [];
    pcm.resize(64 * step, 0.0);
    let roots: i64[4] = [38, 34, 31, 33];
    let chord: i64[12] = [62, 65, 69, 58, 62, 65, 55, 58, 62, 57, 61, 64];
    let stab: i64[12] = [74, 77, 81, 70, 74, 77, 67, 70, 74, 69, 73, 76];
    let line: i64[8] = [0, 2, 1, 2, 0, 1, 2, 1];
    for b in 8 {
        let c = (b / 2) % 4;
        if b % 2 == 0 { for k in 3 { swell(pcm, b * 8 * step, 16 * step, chord[c * 3 + k], 0.2); } }
        for s in 8 {
            let at = (b * 8 + s) * step;
            if s == 0 || (s == 5 && b % 2 == 1) || (s == 6 && b % 4 == 3) { sub(pcm, at, min(step * 3, 64 * step - at), roots[c], 0.9); }
            if s == 0 || s == 3 || s == 6 { voice(pcm, at, min(step * 2, 64 * step - at), stab[c * 3 + line[(b + s) % 8]], 1, 0.2); }
            if b >= 4 && s % 2 == 1 { voice(pcm, at, step, stab[c * 3 + line[s]] + 12, 0, 0.07); }
            if s == 0 || s == 5 || (s == 7 && b % 2 == 1) { drum(r, pcm, at, step * 2 / 3, true, 0.8); }
            if s == 4 { drum(r, pcm, at, step / 2, false, 0.45); }
            if s % 2 == 0 { drum(r, pcm, at, step / 10, false, 0.06); }
        }
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.5)); }
    return audio::create_sound(pcm);
}

// Bright metallic steel-drum / marimba pluck (fundamental + 2nd harmonic with fast decay) for Tropical Island.
fn pluck(pcm: f32[>..]&, at: i64, n: i64, m: i64, bright: f64, dec: f64, vol: f64) {
    let f = 440.0 * exp(((m - 69) as f64) / 12.0 * 0.6931471805599453);
    for i in n {
        let u = (i as f64) / (n as f64);
        let t = (i as f64) / 48000.0;
        let w = sin(TAU * f * t) + bright * sin(TAU * 2.0 * f * t) * exp(-4.0 * u) + 0.18 * bright * sin(TAU * 3.0 * f * t) * exp(-7.0 * u);
        pcm[at + i] += (w * vol * exp(-dec * u) * min(1.0, (i as f64) / 60.0)) as f32;
    }
}

// Airy vibrato flute for Forest.
fn flute(pcm: f32[>..]&, at: i64, n: i64, m: i64, vol: f64) {
    let f = 440.0 * exp(((m - 69) as f64) / 12.0 * 0.6931471805599453);
    var ph = 0.0;
    for i in n {
        let u = (i as f64) / (n as f64);
        let t = (i as f64) / 48000.0;
        ph += TAU * f * (1.0 + 0.006 * sin(TAU * 5.5 * t)) / 48000.0;
        let env = sin(3.141592653589793 * min(1.0, u * 4.0) * 0.5) * exp(-1.8 * u);
        pcm[at + i] += ((sin(ph) + 0.2 * sin(2.0 * ph)) * vol * env) as f32;
    }
}

// Tropical Island: sunny C-major calypso with steel-drum melody, island bass, and syncopated shakers.
fn make_music_island(r: rng&) -> audio::Sound {
    let step = 8800;
    var pcm: f32[>..] = [];
    pcm.resize(64 * step, 0.0);
    let roots: i64[4] = [48, 45, 41, 43]; // C Am F G
    let chord: i64[12] = [72, 76, 79, 69, 72, 76, 65, 69, 72, 67, 71, 74];
    let mel: i64[16] = [2, 1, 2, 0, 2, 1, 0, 1, 2, 2, 1, 0, 1, 2, 1, 0];
    for b in 8 {
        let c = (b / 2) % 4;
        for s in 8 {
            let at = (b * 8 + s) * step;
            let n = min(step * 9 / 10, 64 * step - at);
            if s == 0 || s == 3 || s == 6 { pluck(pcm, at, min(step * 2, 64 * step - at), roots[c], 0.25, 3.0, 0.48); }
            if s == 0 || s == 2 || s == 3 || s == 5 || s == 6 {
                let note = chord[c * 3 + mel[(b % 2) * 8 + s]] + (if b >= 4 && s % 3 == 0 { 12 } else { 0 });
                pluck(pcm, at, min(step * 3 / 2, 64 * step - at), note, 0.65, 4.5, 0.26);
            }
            if s % 4 == 0 { drum(r, pcm, at, step / 2, true, 0.45); }
            if s == 3 || s == 6 { drum(r, pcm, at, step / 5, false, 0.16); }
            drum(r, pcm, at, step / 9, false, 0.08);
        }
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.55)); }
    return audio::create_sound(pcm);
}

// Forest: warm pastoral G-major / E-minor woodland flute over plucked lute arpeggios.
fn make_music_forest(r: rng&) -> audio::Sound {
    let step = 10400;
    var pcm: f32[>..] = [];
    pcm.resize(64 * step, 0.0);
    let roots: i64[4] = [43, 50, 40, 48]; // G D Em C
    let arp: i64[12] = [67, 71, 74, 62, 66, 69, 64, 67, 71, 60, 64, 67];
    let lead: i64[16] = [79, 81, 83, 79, 78, 76, 74, 78, 76, 79, 83, 81, 79, 76, 74, 72];
    for b in 8 {
        let c = (b / 2) % 4;
        for s in 8 {
            let at = (b * 8 + s) * step;
            let n = min(step * 9 / 10, 64 * step - at);
            if s == 0 || s == 4 { pluck(pcm, at, min(step * 3, 64 * step - at), roots[c], 0.15, 2.5, 0.42); }
            pluck(pcm, at, n, arp[c * 3 + (s % 3)], 0.3, 4.0, 0.2);
            if s % 2 == 0 { flute(pcm, at, min(step * 2, 64 * step - at), lead[(b % 4) * 4 + s / 2], 0.24); }
            if s == 0 { drum(r, pcm, at, step / 3, true, 0.3); }
            if s == 4 { drum(r, pcm, at, step / 6, false, 0.14); }
        }
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.55)); }
    return audio::create_sound(pcm);
}

// Mountains: driving heroic alpine anthem (Am G F E) with soaring horns and marching drums.
fn make_music_mountains(r: rng&) -> audio::Sound {
    let step = 9200;
    var pcm: f32[>..] = [];
    pcm.resize(64 * step, 0.0);
    let roots: i64[4] = [45, 43, 41, 40]; // Am G F E
    let chord: i64[12] = [69, 72, 76, 67, 71, 74, 65, 69, 72, 64, 68, 71];
    let horn: i64[8] = [0, 2, 1, 2, 2, 1, 0, 1];
    for b in 8 {
        let c = (b / 2) % 4;
        if b % 2 == 0 {
            swell(pcm, b * 8 * step, min(16 * step, 64 * step - b * 8 * step), chord[c * 3], 0.22);
            swell(pcm, b * 8 * step, min(16 * step, 64 * step - b * 8 * step), chord[c * 3 + 2], 0.18);
        }
        for s in 8 {
            let at = (b * 8 + s) * step;
            let n = min(step * 9 / 10, 64 * step - at);
            voice(pcm, at, n, roots[c] + (if s % 2 == 1 { 12 } else { 0 }), 2, 0.42);
            if s == 0 || s == 2 || s == 3 || s == 6 {
                voice(pcm, at, min(step * 2, 64 * step - at), chord[c * 3 + horn[(b + s) % 8]] + (if b >= 4 { 12 } else { 0 }), 1, 0.17);
            }
            if s == 0 || s == 3 || s == 4 { drum(r, pcm, at, step / 2, true, 0.65); }
            if s == 2 || s == 6 { drum(r, pcm, at, step / 3, false, 0.35); }
        }
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.5)); }
    return audio::create_sound(pcm);
}

// Desert: hypnotic D Phrygian dominant (Hijaz) oud plucks, drone bass, and darbuka rhythm.
fn make_music_desert(r: rng&) -> audio::Sound {
    let step = 9000;
    var pcm: f32[>..] = [];
    pcm.resize(64 * step, 0.0);
    let scale: i64[8] = [62, 63, 66, 67, 69, 70, 72, 74]; // D Eb F# G A Bb C D
    let pat: i64[16] = [0, 2, 3, 4, 5, 4, 3, 2, 0, 1, 2, 4, 3, 2, 1, 0];
    let drone: i64[4] = [38, 38, 39, 38]; // D D Eb D
    for b in 8 {
        let c = (b / 2) % 4;
        for s in 8 {
            let at = (b * 8 + s) * step;
            let n = min(step * 9 / 10, 64 * step - at);
            if s == 0 || s == 4 { sub(pcm, at, min(step * 4, 64 * step - at), drone[c], 0.55); }
            let idx = pat[(b % 2) * 8 + s];
            let oct = if b >= 4 && s % 2 == 0 { 12 } else { 0 };
            pluck(pcm, at, min(step * 3 / 2, 64 * step - at), scale[idx] + oct, 0.9, 5.5, 0.28);
            if s == 0 || s == 3 || s == 6 { drum(r, pcm, at, step / 2, true, 0.55); }
            if s == 2 || s == 5 || s == 7 { drum(r, pcm, at, step / 5, false, 0.26); }
        }
    }
    for i in pcm.len { pcm[i] = max(-1.0, min(1.0, pcm[i] * 0.55)); }
    return audio::create_sound(pcm);
}

fn pan(x: i64) -> f32 { ((x as f32) / ((W * TILE) as f32) - 0.5) * 1.6 }

// Plays what changed between two snapshots, so a client hears what the host's game did.
fn hear(prev: State&, s: State&, sfx: Sfx, fx: Fx&) {
    if prev.over == 0 && s.over > 0 {
        if s.dance_who < 4 { audio::play(sfx.dance, 0.9, 0.0, 1.0, false); }
        else {
            for i in 4 { if s.players[i].on != 0 && s.players[i].wins > prev.players[i].wins { audio::play(sfx.win, 0.8, 0.0, 1.0, false); } }
        }
    }
    guard prev.over == 0 && s.over == 0 else { return; }
    for i in s.bombs.len {
        if bomb_at(prev, s.bombs[i].x, s.bombs[i].y) < 0 { audio::play(sfx.place, 0.6, pan(s.bombs[i].x * TILE), 1.0, false); }
    }
    for i in prev.bombs.len {
        if bomb_at(s, prev.bombs[i].x, prev.bombs[i].y) < 0 {
            audio::play(sfx.boom, 0.9, pan(prev.bombs[i].x * TILE), 1.0, false);
            fx.shake = 9.0;
        }
    }
    for i in W * H { if prev.grid[i] == 6 && s.grid[i] == 2 { audio::play(sfx.clank, 0.5, pan((i % W) * TILE), 1.0, false); } }
    for k in 2 { if prev.sheep[k].alive != 0 && s.sheep[k].alive == 0 { audio::play(sfx.die, 0.6, pan(s.sheep[k].x), 1.6, false); } }
    for i in 4 {
        let a = prev.players[i];
        let b = s.players[i];
        guard a.on != 0 && b.on != 0 else { continue; }
        let vol = if i == s.you { 0.8 } else { 0.4 };
        if a.alive != 0 && b.alive == 0 { audio::play(sfx.die, 0.8, pan(b.x), 1.0, false); }
        if b.range + b.bombs + b.speed > a.range + a.bombs + a.speed || (a.ghost == 0 && b.ghost > 0) || (a.kick == 0 && b.kick > 0) { audio::play(sfx.pickup, vol, pan(b.x), 1.0, false); }
        if b.wins > a.wins { audio::play(sfx.win, 0.8, 0.0, 1.0, false); }
    }
}

// ---- drawing ----------------------------------------------------------------------------------

fn col(i: i64) -> ui::Color {
    if i == 0 { return ui::rgb(235, 72, 72); }
    if i == 1 { return ui::rgb(80, 150, 255); }
    if i == 2 { return ui::rgb(80, 215, 120); }
    return ui::rgb(245, 205, 70);
}

// Player i's marker shape: triangle, diamond, square, circle.
fn shape(c: ui::Context, i: i64, x: f32, y: f32, r: f32, color: ui::Color) {
    if i == 0 { ui::fill_triangle(c, x, y - r, x + r, y + r * 0.8, x - r, y + r * 0.8, color); }
    else if i == 1 {
        ui::fill_triangle(c, x, y - r, x + r, y, x, y + r, color);
        ui::fill_triangle(c, x, y - r, x - r, y, x, y + r, color);
    }
    else if i == 2 { ui::fill_rect(c, ui::rect(x - r * 0.85, y - r * 0.85, r * 1.7, r * 1.7), 2.0, color); }
    else { ui::fill_circle(c, ui::rect(x - r, y - r, r * 2.0, r * 2.0), color); }
}

fn marker(c: ui::Context, i: i64, x: f32, y: f32, r: f32) {
    shape(c, i, x, y, r, ui::rgb(255, 255, 255));
    shape(c, i, x, y, r * 0.68, col(i));
}

fn text(c: ui::Context, x: f32, y: f32, str: const u8[:], color: ui::Color) {
    ui::draw_text(c, ui::rect(x, y, 600.0, 80.0), str, ui::font(c), ui::Color { 0, 0, 0, 0 }, color);
}

fn map_clear_color(m: u8) -> float4 {
    if m == MAP_ISLAND { return float4 { 0.05, 0.34, 0.45, 1.0 }; }
    if m == MAP_FOREST { return float4 { 0.07, 0.16, 0.09, 1.0 }; }
    if m == MAP_MOUNTAINS { return float4 { 0.10, 0.14, 0.22, 1.0 }; }
    return float4 { 0.32, 0.17, 0.08, 1.0 };
}

fn map_border_color(m: u8) -> ui::Color {
    if m == MAP_ISLAND { return ui::rgb(26, 152, 180); }
    if m == MAP_FOREST { return ui::rgb(30, 62, 34); }
    if m == MAP_MOUNTAINS { return ui::rgb(46, 56, 78); }
    return ui::rgb(138, 84, 42);
}

fn draw_floor(c: ui::Context, m: u8, tx: i64, ty: i64, x: f32, y: f32, t: f32) {
    let odd = (tx + ty) % 2 == 0;
    if m == MAP_ISLAND {
        let base = if odd { ui::rgb(230, 206, 150) } else { ui::rgb(220, 196, 140) };
        ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
        if (tx * 7 + ty * 13) % 11 == 0 {
            ui::fill_circle(c, ui::rect(x + t * 0.35, y + t * 0.55, t * 0.12, t * 0.08), ui::rgb(248, 236, 208));
        }
    } else if m == MAP_FOREST {
        let base = if odd { ui::rgb(78, 134, 64) } else { ui::rgb(70, 124, 58) };
        ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
        if (tx * 5 + ty * 11) % 9 == 0 {
            ui::fill_circle(c, ui::rect(x + t * 0.25, y + t * 0.3, t * 0.1, t * 0.1), ui::rgb(245, 225, 110));
        }
    } else if m == MAP_MOUNTAINS {
        let base = if odd { ui::rgb(134, 148, 170) } else { ui::rgb(144, 158, 180) };
        ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
        if (tx * 3 + ty * 17) % 10 == 0 {
            ui::fill_rect(c, ui::rect(x + t * 0.2, y + t * 0.6, t * 0.28, t * 0.08), 2.0, ui::rgba(235, 244, 255, 140));
        }
    } else {
        let base = if odd { ui::rgb(222, 170, 102) } else { ui::rgb(212, 160, 92) };
        ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
        if (tx + ty * 3) % 7 == 0 {
            ui::stroke_line(c, x + t * 0.15, y + t * 0.5, x + t * 0.75, y + t * 0.45, 1.5, ui::rgba(178, 122, 62, 120));
        }
    }
}

fn draw_wall(c: ui::Context, m: u8, x: f32, y: f32, t: f32) {
    if m == MAP_ISLAND {
        // Tropical volcanic rock + lush palm fronds
        ui::fill_rect(c, ui::rect(x, y, t, t), 5.0, ui::rgb(104, 96, 86));
        ui::fill_rect(c, ui::rect(x + t * 0.08, y + t * 0.08, t * 0.84, t * 0.2), 3.0, ui::rgb(142, 134, 120));
        ui::fill_circle(c, ui::rect(x + t * 0.22, y + t * 0.16, t * 0.56, t * 0.52), ui::rgb(42, 148, 68));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.42, x + t * 0.06, y + t * 0.2, x + t * 0.26, y + t * 0.54, ui::rgb(58, 174, 82));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.42, x + t * 0.94, y + t * 0.2, x + t * 0.74, y + t * 0.54, ui::rgb(58, 174, 82));
        ui::fill_circle(c, ui::rect(x + t * 0.42, y + t * 0.42, t * 0.16, t * 0.16), ui::rgb(120, 74, 38));
    } else if m == MAP_FOREST {
        // Tall layered pine tree on mossy soil
        ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(42, 74, 38));
        ui::fill_rect(c, ui::rect(x + t * 0.4, y + t * 0.62, t * 0.2, t * 0.3), 2.0, ui::rgb(96, 62, 36));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.08, x + t * 0.9, y + t * 0.72, x + t * 0.1, y + t * 0.72, ui::rgb(28, 92, 46));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.06, x + t * 0.8, y + t * 0.5, x + t * 0.2, y + t * 0.5, ui::rgb(44, 124, 62));
    } else if m == MAP_MOUNTAINS {
        // Jagged snow-capped alpine peak
        ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(68, 78, 98));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.08, x + t * 0.94, y + t * 0.92, x + t * 0.06, y + t * 0.92, ui::rgb(96, 108, 130));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.08, x + t * 0.7, y + t * 0.46, x + t * 0.3, y + t * 0.46, ui::rgb(242, 248, 255));
        ui::stroke_rect(c, ui::rect(x + 1.0, y + 1.0, t - 2.0, t - 2.0), 4.0, 1.5, ui::rgb(52, 60, 76));
    } else {
        // Carved desert sandstone pillar
        ui::fill_rect(c, ui::rect(x, y, t, t), 3.0, ui::rgb(176, 126, 72));
        ui::fill_rect(c, ui::rect(x, y, t, t * 0.16), 3.0, ui::rgb(218, 172, 110));
        ui::fill_rect(c, ui::rect(x, y + t * 0.84, t, t * 0.16), 3.0, ui::rgb(126, 82, 42));
        ui::stroke_rect(c, ui::rect(x + t * 0.18, y + t * 0.22, t * 0.64, t * 0.56), 2.0, 2.0, ui::rgb(132, 86, 44));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.3, x + t * 0.7, y + t * 0.68, x + t * 0.3, y + t * 0.68, ui::rgb(198, 148, 88));
    }
}

fn draw_brick(c: ui::Context, m: u8, x: f32, y: f32, t: f32) {
    if m == MAP_ISLAND {
        // Bamboo / driftwood crate
        ui::fill_rect(c, ui::rect(x, y, t, t), 5.0, ui::rgb(184, 146, 76));
        for k in 4 {
            let xx = x + t * (0.12 + 0.24 * k);
            ui::fill_rect(c, ui::rect(xx, y + t * 0.08, t * 0.16, t * 0.84), 3.0, ui::rgb(208, 174, 96));
        }
        ui::fill_rect(c, ui::rect(x + t * 0.06, y + t * 0.32, t * 0.88, t * 0.1), 2.0, ui::rgb(126, 92, 46));
        ui::fill_rect(c, ui::rect(x + t * 0.06, y + t * 0.62, t * 0.88, t * 0.1), 2.0, ui::rgb(126, 92, 46));
        ui::stroke_rect(c, ui::rect(x, y, t, t), 5.0, 2.0, ui::rgb(106, 78, 36));
    } else if m == MAP_FOREST {
        // Stacked wooden timber logs
        ui::fill_rect(c, ui::rect(x, y, t, t), 5.0, ui::rgb(114, 72, 42));
        for r in 3 {
            let yy = y + t * (0.06 + 0.31 * r);
            ui::fill_rect(c, ui::rect(x + t * 0.06, yy, t * 0.88, t * 0.25), t * 0.12, ui::rgb(148, 96, 56));
            ui::fill_circle(c, ui::rect(x + t * 0.72, yy + t * 0.03, t * 0.18, t * 0.18), ui::rgb(208, 166, 114));
        }
        ui::stroke_rect(c, ui::rect(x, y, t, t), 5.0, 2.0, ui::rgb(74, 46, 26));
    } else if m == MAP_MOUNTAINS {
        // Frosted boulder / ice block
        ui::fill_rect(c, ui::rect(x, y, t, t), 6.0, ui::rgb(154, 198, 228));
        ui::fill_rect(c, ui::rect(x + t * 0.08, y + t * 0.08, t * 0.84, t * 0.22), 4.0, ui::rgb(218, 240, 255));
        ui::stroke_line(c, x + t * 0.2, y + t * 0.35, x + t * 0.55, y + t * 0.6, 2.0, ui::rgb(96, 140, 174));
        ui::stroke_line(c, x + t * 0.55, y + t * 0.6, x + t * 0.8, y + t * 0.45, 2.0, ui::rgb(96, 140, 174));
        ui::stroke_rect(c, ui::rect(x, y, t, t), 6.0, 2.0, ui::rgb(82, 118, 150));
    } else {
        // Terracotta adobe bricks
        let mortar = ui::rgb(122, 62, 34);
        ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(196, 108, 62));
        ui::fill_rect(c, ui::rect(x, y, t, t * 0.1), 4.0, ui::rgb(226, 140, 92));
        for r in 3 {
            let yy = y + t * (r as f32) / 3.0;
            if r > 0 { ui::stroke_line(c, x, yy, x + t, yy, 2.0, mortar); }
            let off = if r % 2 == 0 { 0.5 } else { 0.25 };
            ui::stroke_line(c, x + t * off, yy, x + t * off, yy + t / 3.0, 2.0, mortar);
            if r % 2 == 1 { ui::stroke_line(c, x + t * 0.75, yy, x + t * 0.75, yy + t / 3.0, 2.0, mortar); }
        }
        ui::stroke_rect(c, ui::rect(x, y, t, t), 4.0, 2.0, ui::rgb(104, 52, 28));
    }
}

fn draw_steel(c: ui::Context, x: f32, y: f32, t: f32) {
    let rim = ui::rgb(150, 178, 200);
    ui::fill_rect(c, ui::rect(x, y, t, t), 6.0, ui::rgb(52, 72, 96));
    ui::stroke_rect(c, ui::rect(x + 2.0, y + 2.0, t - 4.0, t - 4.0), 5.0, 3.0, rim);
    ui::stroke_line(c, x + t * 0.2, y + t * 0.2, x + t * 0.8, y + t * 0.8, 4.0, rim);
    ui::stroke_line(c, x + t * 0.8, y + t * 0.2, x + t * 0.2, y + t * 0.8, 4.0, rim);
    ui::fill_circle(c, ui::rect(x + t * 0.4, y + t * 0.4, t * 0.2, t * 0.2), ui::rgb(255, 120, 80));
}

fn draw_gift(c: ui::Context, x: f32, y: f32, t: f32, tm: f32) {
    let gold = ui::rgb(255, 205, 70);
    ui::fill_rect(c, ui::rect(x, y, t, t), 6.0, ui::rgb(128, 72, 178));
    ui::fill_rect(c, ui::rect(x, y + t * 0.42, t, t * 0.16), 0.0, gold);
    ui::fill_rect(c, ui::rect(x + t * 0.42, y, t * 0.16, t), 0.0, gold);
    ui::fill_circle(c, ui::rect(x + t * 0.3, y + t * 0.3, t * 0.4, t * 0.4), gold);
    ui::fill_circle(c, ui::rect(x + t * 0.4, y + t * 0.4, t * 0.2, t * 0.2), ui::rgb(128, 72, 178));
    let sp = 0.5 + 0.5 * sin(tm * 5.0);
    ui::fill_circle(c, ui::rect(x + t * 0.78, y + t * 0.08, t * 0.14 * sp, t * 0.14 * sp), ui::rgb(255, 255, 255));
}

fn draw_power(c: ui::Context, g: u8, x: f32, y0: f32, t: f32, tm: f32) {
    let y = y0 + sin(tm * 4.0 + x) * t * 0.04;
    let plate = if g == 3 { ui::rgb(200, 60, 40) } else if g == 4 { ui::rgb(70, 70, 84) } else if g == 8 { ui::rgb(120, 80, 190) } else if g == 9 { ui::rgb(205, 125, 40) } else { ui::rgb(30, 150, 205) };
    ui::fill_circle(c, ui::rect(x + t * 0.04, y + t * 0.04, t * 0.92, t * 0.92), ui::rgba(255, 255, 255, 40));
    ui::fill_rect(c, ui::rect(x + t * 0.14, y + t * 0.14, t * 0.72, t * 0.72), t * 0.18, plate);
    ui::stroke_rect(c, ui::rect(x + t * 0.14, y + t * 0.14, t * 0.72, t * 0.72), t * 0.18, 2.0, ui::rgb(255, 255, 255));
    if g == 3 {          // flame
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.2, x + t * 0.72, y + t * 0.7, x + t * 0.28, y + t * 0.7, ui::rgb(255, 210, 60));
        ui::fill_circle(c, ui::rect(x + t * 0.3, y + t * 0.5, t * 0.4, t * 0.3), ui::rgb(255, 210, 60));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.4, x + t * 0.6, y + t * 0.72, x + t * 0.4, y + t * 0.72, ui::rgb(255, 120, 40));
    } else if g == 4 {   // bomb
        ui::fill_circle(c, ui::rect(x + t * 0.3, y + t * 0.36, t * 0.4, t * 0.4), ui::rgb(15, 15, 20));
        ui::fill_circle(c, ui::rect(x + t * 0.38, y + t * 0.43, t * 0.1, t * 0.1), ui::rgb(255, 255, 255));
        ui::stroke_line(c, x + t * 0.6, y + t * 0.4, x + t * 0.7, y + t * 0.28, 2.0, ui::rgb(230, 200, 140));
        ui::fill_circle(c, ui::rect(x + t * 0.67, y + t * 0.22, t * 0.1, t * 0.1), ui::rgb(255, 210, 60));
    } else if g == 8 {   // ghost
        ui::fill_circle(c, ui::rect(x + t * 0.3, y + t * 0.24, t * 0.4, t * 0.4), ui::rgb(240, 240, 255));
        ui::fill_rect(c, ui::rect(x + t * 0.3, y + t * 0.44, t * 0.4, t * 0.28), 0.0, ui::rgb(240, 240, 255));
        for k in 3 { ui::fill_circle(c, ui::rect(x + t * (0.3 + 0.1333 * k), y + t * 0.66, t * 0.1333, t * 0.1), ui::rgb(240, 240, 255)); }
        for e in 2 { ui::fill_circle(c, ui::rect(x + t * (0.38 + 0.15 * e), y + t * 0.4, t * 0.07, t * 0.09), ui::rgb(40, 30, 70)); }
    } else if g == 9 {   // boot
        ui::fill_rect(c, ui::rect(x + t * 0.36, y + t * 0.24, t * 0.2, t * 0.36), 2.0, ui::rgb(255, 255, 255));
        ui::fill_rect(c, ui::rect(x + t * 0.36, y + t * 0.5, t * 0.36, t * 0.17), t * 0.07, ui::rgb(255, 255, 255));
        ui::fill_rect(c, ui::rect(x + t * 0.3, y + t * 0.64, t * 0.44, t * 0.06), 1.0, ui::rgb(70, 40, 20));
        ui::stroke_line(c, x + t * 0.2, y + t * 0.42, x + t * 0.3, y + t * 0.46, 2.0, ui::rgb(255, 235, 90));
        ui::stroke_line(c, x + t * 0.2, y + t * 0.56, x + t * 0.3, y + t * 0.56, 2.0, ui::rgb(255, 235, 90));
    } else {             // bolt
        ui::fill_triangle(c, x + t * 0.56, y + t * 0.2, x + t * 0.34, y + t * 0.52, x + t * 0.52, y + t * 0.52, ui::rgb(255, 235, 90));
        ui::fill_triangle(c, x + t * 0.48, y + t * 0.46, x + t * 0.68, y + t * 0.46, x + t * 0.44, y + t * 0.8, ui::rgb(255, 235, 90));
    }
}

fn draw_flame(c: ui::Context, g: u8, x: f32, y: f32, t: f32, tm: f32) {
    let life = ((g % 16) as f32 + 1.0) / 16.0;
    let fl = 0.04 * sin(tm * 40.0 + x);
    let a = (120.0 + 135.0 * life) as i64;
    ui::fill_rect(c, ui::rect(x, y, t, t), t * 0.3, ui::rgba(255, 90, 20, a));
    ui::fill_rect(c, ui::rect(x + t * (0.12 - fl), y + t * (0.12 - fl), t * (0.76 + 2.0 * fl), t * (0.76 + 2.0 * fl)), t * 0.3, ui::rgba(255, 170, 40, a));
    ui::fill_rect(c, ui::rect(x + t * 0.28, y + t * 0.28, t * 0.44, t * 0.44), t * 0.2, ui::rgba(255, 245, 190, a));
}

// Themed bombs for each farm character: egg, acorn, diaper, cow patty, bacon, hay bale.
fn draw_egg(c: ui::Context, b: Bomb, cx: f32, cy: f32, k: f32, tm: f32) {
    let w = k * 0.62;
    let h = k * 0.8;
    let x = cx + 0.03 * k * sin(tm * 8.0 + b.t);
    let red = b.t < 45 && (b.t / 6) % 2 == 0;
    let body = if red { ui::rgb(255, 160, 140) } else { ui::rgb(250, 244, 226) };
    ui::fill_circle(c, ui::rect(cx - k * 0.4, cy + k * 0.22, k * 0.8, k * 0.3), ui::rgba(0, 0, 0, 90));
    ui::fill_rect(c, ui::rect(x - w * 0.5, cy - h * 0.5, w, h), w * 0.5, body);
    ui::stroke_rect(c, ui::rect(x - w * 0.5, cy - h * 0.5, w, h), w * 0.5, 3.0, col(b.owner));
    ui::fill_circle(c, ui::rect(x + w * 0.1, cy + h * 0.05, w * 0.12, w * 0.12), ui::rgba(190, 160, 120, 170));
    ui::fill_circle(c, ui::rect(x - w * 0.25, cy + h * 0.2, w * 0.1, w * 0.1), ui::rgba(190, 160, 120, 170));
    ui::fill_circle(c, ui::rect(x - w * 0.3, cy - h * 0.3, w * 0.22, w * 0.3), ui::rgba(255, 255, 255, 170));
    if b.t < 45 {
        ui::stroke_line(c, x - w * 0.4, cy - h * 0.05, x - w * 0.1, cy + h * 0.1, 2.0, ui::rgb(90, 70, 60));
        ui::stroke_line(c, x - w * 0.1, cy + h * 0.1, x + w * 0.1, cy - h * 0.08, 2.0, ui::rgb(90, 70, 60));
        ui::stroke_line(c, x + w * 0.1, cy - h * 0.08, x + w * 0.4, cy + h * 0.08, 2.0, ui::rgb(90, 70, 60));
    }
}

fn draw_acorn(c: ui::Context, b: Bomb, cx: f32, cy: f32, k: f32, tm: f32) {
    let red = b.t < 45 && (b.t / 6) % 2 == 0;
    let nut = if red { ui::rgb(210, 70, 45) } else { ui::rgb(176, 112, 54) };
    let cap = if red { ui::rgb(140, 40, 25) } else { ui::rgb(102, 62, 34) };
    ui::fill_circle(c, ui::rect(cx - k * 0.42, cy + k * 0.22, k * 0.84, k * 0.3), ui::rgba(0, 0, 0, 90));
    // Nut body + bottom tip
    ui::fill_circle(c, ui::rect(cx - k * 0.32, cy - k * 0.18, k * 0.64, k * 0.6), nut);
    ui::fill_triangle(c, cx - k * 0.2, cy + k * 0.28, cx + k * 0.2, cy + k * 0.28, cx, cy + k * 0.5, nut);
    ui::stroke_circle(c, ui::rect(cx - k * 0.32, cy - k * 0.18, k * 0.64, k * 0.6), 2.5, col(b.owner));
    ui::fill_circle(c, ui::rect(cx - k * 0.18, cy - k * 0.04, k * 0.14, k * 0.22), ui::rgba(255, 235, 195, 130));
    // Cap + stem
    ui::fill_rect(c, ui::rect(cx - k * 0.38, cy - k * 0.42, k * 0.76, k * 0.3), k * 0.14, cap);
    ui::stroke_rect(c, ui::rect(cx - k * 0.38, cy - k * 0.42, k * 0.76, k * 0.3), k * 0.14, 2.0, ui::rgb(68, 38, 18));
    ui::stroke_line(c, cx, cy - k * 0.42, cx + k * 0.12, cy - k * 0.62, 3.0, ui::rgb(90, 56, 30));
    let sp = (0.09 + 0.04 * sin(tm * 26.0)) * k;
    ui::fill_circle(c, ui::rect(cx + k * 0.12 - sp, cy - k * 0.62 - sp, sp * 2.0, sp * 2.0), ui::rgb(255, 220, 75));
}

fn draw_diaper(c: ui::Context, b: Bomb, cx: f32, cy: f32, k: f32, tm: f32) {
    let red = b.t < 45 && (b.t / 6) % 2 == 0;
    let cloth = if red { ui::rgb(255, 200, 175) } else { ui::rgb(248, 250, 255) };
    let trim = ui::rgb(175, 210, 245);
    ui::fill_circle(c, ui::rect(cx - k * 0.44, cy + k * 0.22, k * 0.88, k * 0.3), ui::rgba(0, 0, 0, 90));
    // Folded diaper shape
    ui::fill_rect(c, ui::rect(cx - k * 0.42, cy - k * 0.34, k * 0.84, k * 0.28), k * 0.08, cloth);
    ui::fill_triangle(c, cx - k * 0.42, cy - k * 0.14, cx + k * 0.42, cy - k * 0.14, cx, cy + k * 0.44, cloth);
    ui::fill_circle(c, ui::rect(cx - k * 0.24, cy + k * 0.12, k * 0.48, k * 0.3), cloth);
    ui::stroke_rect(c, ui::rect(cx - k * 0.42, cy - k * 0.34, k * 0.84, k * 0.28), k * 0.08, 2.5, col(b.owner));
    ui::stroke_line(c, cx - k * 0.4, cy - k * 0.06, cx, cy + k * 0.42, 2.5, trim);
    ui::stroke_line(c, cx + k * 0.4, cy - k * 0.06, cx, cy + k * 0.42, 2.5, trim);
    // Gold safety pins
    ui::fill_circle(c, ui::rect(cx - k * 0.34, cy - k * 0.25, k * 0.12, k * 0.12), ui::rgb(245, 195, 50));
    ui::fill_circle(c, ui::rect(cx + k * 0.22, cy - k * 0.25, k * 0.12, k * 0.12), ui::rgb(245, 195, 50));
    // Stink lines waving up!
    let sw = sin(tm * 10.0 + b.t) * k * 0.08;
    let stink = if red { ui::rgb(255, 110, 60) } else { ui::rgb(135, 205, 75) };
    ui::stroke_line(c, cx - k * 0.15, cy - k * 0.4, cx - k * 0.15 + sw, cy - k * 0.65, 2.5, stink);
    ui::stroke_line(c, cx + k * 0.15, cy - k * 0.4, cx + k * 0.15 - sw, cy - k * 0.65, 2.5, stink);
}

fn draw_patty(c: ui::Context, b: Bomb, cx: f32, cy: f32, k: f32, tm: f32) {
    let red = b.t < 45 && (b.t / 6) % 2 == 0;
    let d1 = if red { ui::rgb(180, 55, 35) } else { ui::rgb(104, 66, 36) };
    let d2 = if red { ui::rgb(210, 80, 45) } else { ui::rgb(126, 82, 46) };
    let d3 = if red { ui::rgb(240, 110, 60) } else { ui::rgb(148, 98, 56) };
    ui::fill_circle(c, ui::rect(cx - k * 0.5, cy + k * 0.18, k, k * 0.34), ui::rgba(0, 0, 0, 95));
    // Three swirly stacked cow patty tiers
    ui::fill_circle(c, ui::rect(cx - k * 0.46, cy - k * 0.04, k * 0.92, k * 0.46), d1);
    ui::stroke_circle(c, ui::rect(cx - k * 0.46, cy - k * 0.04, k * 0.92, k * 0.46), 2.5, col(b.owner));
    ui::fill_circle(c, ui::rect(cx - k * 0.34, cy - k * 0.24, k * 0.68, k * 0.38), d2);
    ui::fill_circle(c, ui::rect(cx - k * 0.18, cy - k * 0.4, k * 0.36, k * 0.26), d3);
    ui::fill_triangle(c, cx - k * 0.12, cy - k * 0.34, cx + k * 0.12, cy - k * 0.34, cx + k * 0.04, cy - k * 0.54, d3);
    // Buzzing fly & stink steam
    let fx = cx + cos(tm * 9.0 + b.t) * k * 0.38;
    let fy = cy - k * 0.48 + sin(tm * 13.0) * k * 0.12;
    ui::fill_circle(c, ui::rect(fx - 3.0, fy - 3.0, 6.0, 6.0), ui::rgb(30, 30, 35));
    ui::stroke_line(c, cx - k * 0.14, cy - k * 0.45, cx - k * 0.2 + sin(tm * 8.0) * k * 0.06, cy - k * 0.66, 2.0, ui::rgba(160, 210, 90, 200));
}

fn draw_bacon(c: ui::Context, b: Bomb, cx: f32, cy: f32, k: f32, tm: f32) {
    let red = b.t < 45 && (b.t / 6) % 2 == 0;
    let meat = if red { ui::rgb(255, 70, 50) } else { ui::rgb(198, 54, 48) };
    let fat = if red { ui::rgb(255, 225, 190) } else { ui::rgb(250, 222, 204) };
    let w = k * 0.84;
    let h = k * 0.5;
    let wy = sin(tm * 12.0 + b.t) * k * 0.04;
    ui::fill_circle(c, ui::rect(cx - k * 0.46, cy + k * 0.2, k * 0.92, k * 0.3), ui::rgba(0, 0, 0, 90));
    ui::fill_rect(c, ui::rect(cx - w * 0.5, cy - h * 0.5 + wy, w, h), h * 0.32, meat);
    ui::stroke_rect(c, ui::rect(cx - w * 0.5, cy - h * 0.5 + wy, w, h), h * 0.32, 2.5, col(b.owner));
    // Wavy marbled fat stripes
    ui::fill_rect(c, ui::rect(cx - w * 0.44, cy - h * 0.24 + wy, w * 0.88, h * 0.16), 3.0, fat);
    ui::fill_rect(c, ui::rect(cx - w * 0.44, cy + h * 0.08 + wy, w * 0.88, h * 0.16), 3.0, fat);
    // Sizzle sparks
    let sp = (0.08 + 0.04 * sin(tm * 28.0)) * k;
    ui::fill_circle(c, ui::rect(cx - w * 0.25 - sp, cy - h * 0.72 - sp, sp * 2.0, sp * 2.0), ui::rgb(255, 225, 90));
    ui::fill_circle(c, ui::rect(cx + w * 0.22 - sp * 0.7, cy - h * 0.62 - sp * 0.7, sp * 1.4, sp * 1.4), ui::rgb(255, 180, 60));
}

fn draw_haybale(c: ui::Context, b: Bomb, cx: f32, cy: f32, k: f32, tm: f32) {
    let red = b.t < 45 && (b.t / 6) % 2 == 0;
    let hay = if red { ui::rgb(245, 130, 55) } else { ui::rgb(232, 192, 72) };
    let hi = if red { ui::rgb(255, 185, 95) } else { ui::rgb(250, 218, 110) };
    let twine = ui::rgb(138, 86, 36);
    let w = k * 0.84;
    let h = k * 0.62;
    ui::fill_circle(c, ui::rect(cx - k * 0.46, cy + k * 0.22, k * 0.92, k * 0.3), ui::rgba(0, 0, 0, 90));
    ui::fill_rect(c, ui::rect(cx - w * 0.5, cy - h * 0.5, w, h), 5.0, hay);
    ui::fill_rect(c, ui::rect(cx - w * 0.46, cy - h * 0.46, w * 0.92, h * 0.2), 3.0, hi);
    ui::stroke_rect(c, ui::rect(cx - w * 0.5, cy - h * 0.5, w, h), 5.0, 2.5, col(b.owner));
    // Twine straps & straw wisps
    ui::fill_rect(c, ui::rect(cx - w * 0.26, cy - h * 0.5, w * 0.1, h), 0.0, twine);
    ui::fill_rect(c, ui::rect(cx + w * 0.16, cy - h * 0.5, w * 0.1, h), 0.0, twine);
    ui::stroke_line(c, cx - w * 0.5, cy - h * 0.15, cx - w * 0.62, cy - h * 0.24, 2.0, hi);
    ui::stroke_line(c, cx + w * 0.5, cy + h * 0.1, cx + w * 0.62, cy + h * 0.02, 2.0, hi);
    let sp = (0.09 + 0.04 * sin(tm * 24.0)) * k;
    ui::fill_circle(c, ui::rect(cx - sp, cy - h * 0.66 - sp, sp * 2.0, sp * 2.0), ui::rgb(255, 215, 70));
}

fn draw_goose(c: ui::Context, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    let orange = ui::rgb(255, 150, 30);
    let sw = 0.06 * k * sin(walk * 40.0 / k);
    ui::fill_circle(c, ui::rect(x - k * 0.28 + sw, y + k * 0.36, k * 0.22, k * 0.14), orange);
    ui::fill_circle(c, ui::rect(x + k * 0.06 - sw, y + k * 0.36, k * 0.22, k * 0.14), orange);
    ui::fill_circle(c, ui::rect(x - k * 0.5, y - k * 0.4 + walk, k, k * 0.95), ui::rgb(250, 250, 252));
    ui::stroke_circle(c, ui::rect(x - k * 0.5, y - k * 0.4 + walk, k, k * 0.95), 3.0, col(owner));
    ui::fill_circle(c, ui::rect(x - k * 0.46, y - k * 0.05 + walk, k * 0.28, k * 0.5), ui::rgb(205, 215, 235));
    ui::fill_circle(c, ui::rect(x + k * 0.18, y - k * 0.05 + walk, k * 0.28, k * 0.5), ui::rgb(205, 215, 235));
    let hx = x + fx * k * 0.2;
    let hy = y - k * 0.38 + fy * k * 0.1 + walk;
    ui::fill_rect(c, ui::rect(hx - k * 0.1, hy, k * 0.2, k * 0.3), 0.0, ui::rgb(250, 250, 252));
    ui::fill_circle(c, ui::rect(hx - k * 0.24, hy - k * 0.24, k * 0.48, k * 0.48), ui::rgb(250, 250, 252));
    ui::fill_triangle(c, hx + fx * k * 0.36 - fy * k * 0.1, hy + fy * k * 0.36 + fx * k * 0.1,
                         hx + fx * k * 0.36 + fy * k * 0.1, hy + fy * k * 0.36 - fx * k * 0.1,
                         hx + fx * k * 0.6, hy + fy * k * 0.6 + (if fy == 0.0 { k * 0.04 } else { 0.0 }), orange);
    if fy >= 0.0 {
        for e in 2 {
            let sd = if e == 0 { -1.0 } else { 1.0 };
            let ex = hx + sd * (if fy > 0.0 { k * 0.11 } else { 0.0 }) + fx * k * 0.1;
            ui::fill_circle(c, ui::rect(ex - k * 0.04, hy - k * 0.06, k * 0.08, k * 0.1), ui::rgb(20, 20, 30));
        }
    }
}

fn draw_squirrel(c: ui::Context, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    let fur = ui::rgb(172, 98, 46);
    let tail = ui::rgb(142, 74, 30);
    let belly = ui::rgb(240, 214, 178);
    // Big bushy curled tail behind the squirrel
    let tx = x - fx * k * 0.36 + (if fx == 0.0 { k * 0.34 } else { 0.0 });
    ui::fill_circle(c, ui::rect(tx - k * 0.26, y - k * 0.48 + walk, k * 0.52, k * 0.68), tail);
    ui::fill_circle(c, ui::rect(tx - k * 0.18, y - k * 0.56 + walk, k * 0.38, k * 0.38), fur);
    // Body & belly
    ui::fill_circle(c, ui::rect(x - k * 0.44, y - k * 0.36 + walk, k * 0.88, k * 0.86), fur);
    ui::stroke_circle(c, ui::rect(x - k * 0.44, y - k * 0.36 + walk, k * 0.88, k * 0.86), 3.0, col(owner));
    ui::fill_circle(c, ui::rect(x - k * 0.24, y - k * 0.04 + walk, k * 0.48, k * 0.48), belly);
    // Pointy ears
    ui::fill_circle(c, ui::rect(x - k * 0.34, y - k * 0.54 + walk, k * 0.22, k * 0.28), fur);
    ui::fill_circle(c, ui::rect(x + k * 0.12, y - k * 0.54 + walk, k * 0.22, k * 0.28), fur);
    ui::fill_circle(c, ui::rect(x - k * 0.29, y - k * 0.48 + walk, k * 0.12, k * 0.16), ui::rgb(235, 175, 165));
    ui::fill_circle(c, ui::rect(x + k * 0.17, y - k * 0.48 + walk, k * 0.12, k * 0.16), ui::rgb(235, 175, 165));
    // Face
    if fy >= 0.0 {
        for e in 2 {
            let ex = x + (if e == 0 { -1.0 } else { 1.0 }) * k * 0.16 + fx * k * 0.08;
            let ey = y - k * 0.18 + fy * k * 0.06 + walk;
            ui::fill_circle(c, ui::rect(ex - k * 0.08, ey - k * 0.09, k * 0.16, k * 0.18), ui::rgb(255, 255, 255));
            ui::fill_circle(c, ui::rect(ex - k * 0.04 + fx * k * 0.03, ey - k * 0.04, k * 0.09, k * 0.09), ui::rgb(20, 20, 28));
        }
        // Cute nose + buck tooth
        let nx = x + fx * k * 0.12;
        ui::fill_circle(c, ui::rect(nx - k * 0.06, y - k * 0.06 + walk, k * 0.12, k * 0.09), ui::rgb(50, 30, 24));
        ui::fill_rect(c, ui::rect(nx - k * 0.05, y + k * 0.02 + walk, k * 0.1, k * 0.09), 1.0, ui::rgb(255, 255, 255));
    }
}

fn draw_baby(c: ui::Context, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    let skin = ui::rgb(255, 218, 190);
    // Onesie body in player color
    ui::fill_circle(c, ui::rect(x - k * 0.42, y - k * 0.1 + walk, k * 0.84, k * 0.62), col(owner));
    ui::stroke_circle(c, ui::rect(x - k * 0.42, y - k * 0.1 + walk, k * 0.84, k * 0.62), 2.5, ui::rgb(255, 255, 255));
    // Big chubby baby head
    ui::fill_circle(c, ui::rect(x - k * 0.42, y - k * 0.56 + walk, k * 0.84, k * 0.74), skin);
    ui::stroke_circle(c, ui::rect(x - k * 0.42, y - k * 0.56 + walk, k * 0.84, k * 0.74), 2.5, col(owner));
    // Little hair curl on top
    ui::stroke_line(c, x, y - k * 0.56 + walk, x + k * 0.1, y - k * 0.7 + walk, 3.0, ui::rgb(130, 82, 42));
    ui::fill_circle(c, ui::rect(x - k * 0.04, y - k * 0.72 + walk, k * 0.14, k * 0.12), ui::rgb(130, 82, 42));
    if fy >= 0.0 {
        // Rosy cheeks + big eyes
        ui::fill_circle(c, ui::rect(x - k * 0.34, y - k * 0.14 + walk, k * 0.16, k * 0.12), ui::rgba(255, 130, 145, 150));
        ui::fill_circle(c, ui::rect(x + k * 0.18, y - k * 0.14 + walk, k * 0.16, k * 0.12), ui::rgba(255, 130, 145, 150));
        for e in 2 {
            let ex = x + (if e == 0 { -1.0 } else { 1.0 }) * k * 0.16 + fx * k * 0.08;
            let ey = y - k * 0.26 + walk;
            ui::fill_circle(c, ui::rect(ex - k * 0.09, ey - k * 0.1, k * 0.18, k * 0.2), ui::rgb(255, 255, 255));
            ui::fill_circle(c, ui::rect(ex - k * 0.05 + fx * k * 0.03, ey - k * 0.05, k * 0.11, k * 0.11), ui::rgb(24, 24, 34));
        }
        // Pacifier
        let px = x + fx * k * 0.1;
        ui::fill_circle(c, ui::rect(px - k * 0.13, y - k * 0.08 + walk, k * 0.26, k * 0.18), ui::rgb(95, 195, 255));
        ui::fill_circle(c, ui::rect(px - k * 0.06, y - k * 0.04 + walk, k * 0.12, k * 0.1), ui::rgb(255, 225, 80));
    }
}

fn draw_cow(c: ui::Context, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    let white = ui::rgb(248, 248, 250);
    let spot = ui::rgb(40, 40, 48);
    // Horns & ears
    ui::fill_triangle(c, x - k * 0.34, y - k * 0.34 + walk, x - k * 0.18, y - k * 0.44 + walk, x - k * 0.42, y - k * 0.64 + walk, ui::rgb(225, 200, 140));
    ui::fill_triangle(c, x + k * 0.34, y - k * 0.34 + walk, x + k * 0.18, y - k * 0.44 + walk, x + k * 0.42, y - k * 0.64 + walk, ui::rgb(225, 200, 140));
    ui::fill_circle(c, ui::rect(x - k * 0.56, y - k * 0.32 + walk, k * 0.22, k * 0.14), spot);
    ui::fill_circle(c, ui::rect(x + k * 0.34, y - k * 0.32 + walk, k * 0.22, k * 0.14), white);
    // Round spotted body
    ui::fill_circle(c, ui::rect(x - k * 0.48, y - k * 0.46 + walk, k * 0.96, k * 0.96), white);
    ui::fill_circle(c, ui::rect(x - k * 0.38, y - k * 0.34 + walk, k * 0.34, k * 0.32), spot);
    ui::fill_circle(c, ui::rect(x + k * 0.08, y - k * 0.14 + walk, k * 0.28, k * 0.3), spot);
    ui::stroke_circle(c, ui::rect(x - k * 0.48, y - k * 0.46 + walk, k * 0.96, k * 0.96), 3.0, col(owner));
    if fy >= 0.0 {
        for e in 2 {
            let ex = x + (if e == 0 { -1.0 } else { 1.0 }) * k * 0.18 + fx * k * 0.06;
            let ey = y - k * 0.22 + walk;
            ui::fill_circle(c, ui::rect(ex - k * 0.07, ey - k * 0.08, k * 0.14, k * 0.16), ui::rgb(255, 255, 255));
            ui::fill_circle(c, ui::rect(ex - k * 0.04 + fx * k * 0.03, ey - k * 0.04, k * 0.08, k * 0.08), ui::rgb(20, 20, 25));
        }
        // Wide pink snout
        let sx = x + fx * k * 0.08;
        ui::fill_rect(c, ui::rect(sx - k * 0.32, y - k * 0.02 + walk, k * 0.64, k * 0.32), k * 0.14, ui::rgb(245, 168, 182));
        ui::fill_circle(c, ui::rect(sx - k * 0.18, y + k * 0.08 + walk, k * 0.09, k * 0.11), ui::rgb(110, 52, 66));
        ui::fill_circle(c, ui::rect(sx + k * 0.09, y + k * 0.08 + walk, k * 0.09, k * 0.11), ui::rgb(110, 52, 66));
    }
}

fn draw_pig(c: ui::Context, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    let pink = ui::rgb(250, 162, 182);
    let snout = ui::rgb(238, 122, 152);
    // Floppy ears
    ui::fill_triangle(c, x - k * 0.44, y - k * 0.26 + walk, x - k * 0.16, y - k * 0.44 + walk, x - k * 0.44, y - k * 0.62 + walk, snout);
    ui::fill_triangle(c, x + k * 0.44, y - k * 0.26 + walk, x + k * 0.16, y - k * 0.44 + walk, x + k * 0.44, y - k * 0.62 + walk, snout);
    // Chubby pink body
    ui::fill_circle(c, ui::rect(x - k * 0.48, y - k * 0.46 + walk, k * 0.96, k * 0.96), pink);
    ui::stroke_circle(c, ui::rect(x - k * 0.48, y - k * 0.46 + walk, k * 0.96, k * 0.96), 3.0, col(owner));
    if fy >= 0.0 {
        for e in 2 {
            let ex = x + (if e == 0 { -1.0 } else { 1.0 }) * k * 0.19 + fx * k * 0.07;
            let ey = y - k * 0.22 + walk;
            ui::fill_circle(c, ui::rect(ex - k * 0.07, ey - k * 0.08, k * 0.14, k * 0.16), ui::rgb(255, 255, 255));
            ui::fill_circle(c, ui::rect(ex - k * 0.04 + fx * k * 0.03, ey - k * 0.04, k * 0.08, k * 0.08), ui::rgb(25, 20, 28));
        }
        // Oval snout with nostrils
        let sx = x + fx * k * 0.1;
        ui::fill_rect(c, ui::rect(sx - k * 0.24, y - k * 0.04 + walk, k * 0.48, k * 0.3), k * 0.15, snout);
        ui::fill_circle(c, ui::rect(sx - k * 0.13, y + k * 0.06 + walk, k * 0.09, k * 0.12), ui::rgb(120, 42, 64));
        ui::fill_circle(c, ui::rect(sx + k * 0.04, y + k * 0.06 + walk, k * 0.09, k * 0.12), ui::rgb(120, 42, 64));
    } else {
        // Curly tail visible from behind
        ui::stroke_circle(c, ui::rect(x - k * 0.1, y + k * 0.08 + walk, k * 0.2, k * 0.2), 2.5, snout);
    }
}

fn draw_farmer(c: ui::Context, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    let skin = ui::rgb(248, 204, 166);
    let denim = ui::rgb(52, 96, 168);
    let straw = ui::rgb(240, 204, 96);
    // Shirt (player color) + denim overalls
    ui::fill_circle(c, ui::rect(x - k * 0.44, y - k * 0.12 + walk, k * 0.88, k * 0.64), col(owner));
    ui::fill_rect(c, ui::rect(x - k * 0.3, y + k * 0.02 + walk, k * 0.6, k * 0.46), k * 0.14, denim);
    ui::fill_rect(c, ui::rect(x - k * 0.28, y - k * 0.08 + walk, k * 0.11, k * 0.22), 0.0, denim);
    ui::fill_rect(c, ui::rect(x + k * 0.17, y - k * 0.08 + walk, k * 0.11, k * 0.22), 0.0, denim);
    ui::fill_circle(c, ui::rect(x - k * 0.25, y + k * 0.04 + walk, k * 0.07, k * 0.07), ui::rgb(245, 205, 65));
    ui::fill_circle(c, ui::rect(x + k * 0.18, y + k * 0.04 + walk, k * 0.07, k * 0.07), ui::rgb(245, 205, 65));
    // Face
    ui::fill_circle(c, ui::rect(x - k * 0.32, y - k * 0.48 + walk, k * 0.64, k * 0.54), skin);
    if fy >= 0.0 {
        for e in 2 {
            let ex = x + (if e == 0 { -1.0 } else { 1.0 }) * k * 0.12 + fx * k * 0.06;
            let ey = y - k * 0.24 + walk;
            ui::fill_circle(c, ui::rect(ex - k * 0.05, ey - k * 0.06, k * 0.1, k * 0.11), ui::rgb(25, 22, 24));
        }
        // Mustache
        let mx = x + fx * k * 0.07;
        ui::fill_rect(c, ui::rect(mx - k * 0.18, y - k * 0.1 + walk, k * 0.36, k * 0.1), k * 0.05, ui::rgb(122, 74, 38));
    }
    // Wide straw hat with player-colored ribbon
    ui::fill_circle(c, ui::rect(x - k * 0.56, y - k * 0.52 + walk, k * 1.12, k * 0.24), straw);
    ui::stroke_circle(c, ui::rect(x - k * 0.56, y - k * 0.52 + walk, k * 1.12, k * 0.24), 2.0, ui::rgb(180, 140, 48));
    ui::fill_rect(c, ui::rect(x - k * 0.3, y - k * 0.68 + walk, k * 0.6, k * 0.26), k * 0.12, straw);
    ui::fill_rect(c, ui::rect(x - k * 0.3, y - k * 0.5 + walk, k * 0.6, k * 0.08), 0.0, col(owner));
}

fn draw_sheep(c: ui::Context, q: Sheep, x: f32, y: f32, t: f32, tm: f32) {
    let k = t * 0.8;
    let bob = if q.dir < 4 { 0.03 * t * sin(tm * 14.0) } else { 0.0 };
    let wool = ui::rgb(245, 244, 238);
    ui::fill_circle(c, ui::rect(x - k * 0.55, y + k * 0.25, k * 1.1, k * 0.35), ui::rgba(0, 0, 0, 100));
    for l in 2 { ui::fill_rect(c, ui::rect(x - k * 0.26 + l * k * 0.32, y + k * 0.28, k * 0.1, k * 0.2), 2.0, ui::rgb(50, 46, 50)); }
    ui::fill_circle(c, ui::rect(x - k * 0.5, y - k * 0.42 + bob, k, k * 0.95), ui::rgb(222, 222, 220));
    for n in 7 {
        let a: f32 = n as f32 * 0.9;
        ui::fill_circle(c, ui::rect(x + cos(a) * k * 0.28 - k * 0.2, y + sin(a) * k * 0.26 - k * 0.12 + bob, k * 0.4, k * 0.4), wool);
    }
    ui::fill_circle(c, ui::rect(x - k * 0.34, y - k * 0.34 + bob, k * 0.68, k * 0.72), wool);
    ui::fill_rect(c, ui::rect(x - k * 0.17, y - k * 0.18 + bob, k * 0.34, k * 0.46), k * 0.15, ui::rgb(62, 60, 66));
    ui::fill_circle(c, ui::rect(x - k * 0.1, y + k * 0.14 + bob, k * 0.2, k * 0.12), ui::rgb(100, 98, 106));
    ui::fill_circle(c, ui::rect(x - k * 0.11, y - k * 0.08 + bob, k * 0.06, k * 0.06), ui::rgb(255, 255, 255));
    ui::fill_circle(c, ui::rect(x + k * 0.05, y - k * 0.08 + bob, k * 0.06, k * 0.06), ui::rgb(255, 255, 255));
    ui::fill_rect(c, ui::rect(x - k * 0.34, y - k * 0.14 + bob, k * 0.2, k * 0.06), 2.0, ui::rgb(40, 38, 44));
    ui::fill_rect(c, ui::rect(x + k * 0.14, y - k * 0.14 + bob, k * 0.2, k * 0.06), 2.0, ui::rgb(40, 38, 44));
    ui::fill_circle(c, ui::rect(x - k * 0.2, y - k * 0.32 + bob, k * 0.4, k * 0.26), wool);
}

fn draw_bomb(c: ui::Context, s: State&, b: Bomb, ox: f32, oy: f32, t: f32, tm: f32) {
    let k = (0.72 + 0.06 * sin(tm * 10.0 + b.t)) * t;
    var cx = ox + (b.x + 0.5) * t;
    var cy = oy + (b.y + 0.5) * t;
    if b.dir != 0 {      // glide in from the tile it just left
        let sl = (1.0 - (b.m as f32) / SLIDE) * t;
        if b.dir == 1 { cy += sl; } else if b.dir == 2 { cy -= sl; } else if b.dir == 3 { cx += sl; } else { cx -= sl; }
    }
    let kd = s.players[b.owner].kind;
    if kd == CHAR_GOOSE { draw_egg(c, b, cx, cy, k, tm); return; }
    if kd == CHAR_SQUIRREL { draw_acorn(c, b, cx, cy, k, tm); return; }
    if kd == CHAR_BABY { draw_diaper(c, b, cx, cy, k, tm); return; }
    if kd == CHAR_COW { draw_patty(c, b, cx, cy, k, tm); return; }
    if kd == CHAR_PIG { draw_bacon(c, b, cx, cy, k, tm); return; }
    if kd == CHAR_FARMER { draw_haybale(c, b, cx, cy, k, tm); return; }
    ui::fill_circle(c, ui::rect(cx - k * 0.5, cy + k * 0.2, k, k * 0.4), ui::rgba(0, 0, 0, 90));
    ui::fill_circle(c, ui::rect(cx - k * 0.5, cy - k * 0.5, k, k), if b.t < 45 && (b.t / 6) % 2 == 0 { ui::rgb(120, 25, 25) } else { ui::rgb(22, 22, 30) });
    ui::stroke_circle(c, ui::rect(cx - k * 0.5, cy - k * 0.5, k, k), 3.0, col(b.owner));
}

fn draw_character(c: ui::Context, kind: u8, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    if kind == CHAR_GOOSE { draw_goose(c, owner, x, y, k, fx, fy, walk); return; }
    if kind == CHAR_SQUIRREL { draw_squirrel(c, owner, x, y, k, fx, fy, walk); return; }
    if kind == CHAR_BABY { draw_baby(c, owner, x, y, k, fx, fy, walk); return; }
    if kind == CHAR_COW { draw_cow(c, owner, x, y, k, fx, fy, walk); return; }
    if kind == CHAR_PIG { draw_pig(c, owner, x, y, k, fx, fy, walk); return; }
    draw_farmer(c, owner, x, y, k, fx, fy, walk);
}

fn draw_player(c: ui::Context, s: State&, i: i64, x: f32, y: f32, t: f32, tm: f32) {
    let k = t * 0.76;
    let bits = s.players[i].bits;
    var fx: f32 = 0.0;
    var fy: f32 = 1.0;
    if (bits & UP) != 0 { fx = 0.0; fy = -1.0; }
    else if (bits & DOWN) != 0 { fx = 0.0; fy = 1.0; }
    else if (bits & LEFT) != 0 { fx = -1.0; fy = 0.0; }
    else if (bits & RIGHT) != 0 { fx = 1.0; fy = 0.0; }
    let walk = if (bits & 15) != 0 { 0.05 * t * sin(tm * 22.0) } else { 0.0 };
    let gh = s.players[i].ghost;
    if gh > 0 {          // ghosts are unseen; only their owner sees a faint, flickering outline
        if i == s.you && (gh > 120 || (gh / 6) % 2 == 0) {
            ui::stroke_circle(c, ui::rect(x - k * 0.5, y - k * 0.5 + walk, k, k), 2.0, ui::rgba(255, 255, 255, 70));
            ui::fill_circle(c, ui::rect(x - k * 0.5, y - k * 0.5 + walk, k, k), ui::rgba(255, 255, 255, 18));
        }
        return;
    }
    if (bits & HOLD) != 0 { ui::stroke_rect(c, ui::rect(x - k * 0.62, y - k * 0.62, k * 1.24, k * 1.24), k * 0.3, 3.0, ui::rgba(255, 255, 255, 190)); }
    ui::fill_circle(c, ui::rect(x - k * 0.5, y + k * 0.3, k, k * 0.4), ui::rgba(0, 0, 0, 110));
    draw_character(c, s.players[i].kind, i, x, y, k, fx, fy, walk);
    marker(c, i, x, y - k * 0.78 + walk, t * 0.13);
    if s.players[i].name.len > 0 {
        let nw = ui::text_width(ui::font(c), s.players[i].name[..]);
        ui::fill_rect(c, ui::rect(x - nw * 0.5 - 4.0, y + k * 0.44, nw + 8.0, 20.0), 4.0, ui::rgba(10, 12, 20, 165));
        text(c, x - nw * 0.5, y + k * 0.43, s.players[i].name[..], ui::rgb(245, 245, 250));
    }
    if i == s.you {
        let bob = 0.06 * t * sin(tm * 6.0);
        ui::fill_triangle(c, x, y - k * 1.0 + bob, x + t * 0.1, y - k * 1.2 + bob, x - t * 0.1, y - k * 1.2 + bob, ui::rgb(255, 255, 255));
    }
}

// Every 5 wins: spotlight zoom-in where the winner dances right in everyone's faces!
fn draw_dance(c: ui::Context, s: State&, who: i64, size: int2, tm: f32) {
    let sw = size.x as f32;
    let sh = size.y as f32;
    let cx = sw * 0.5;
    let cy = sh * 0.54;
    let k = min(sw, sh) * 0.34;
    ui::fill_rect(c, ui::rect(0, 0, sw, sh), 0.0, ui::rgba(8, 10, 20, 205));
    // Rotating disco spotlight rays
    for r in 6 {
        let a = tm * 1.8 + r as f32 * 1.0472;
        let rc = if r % 3 == 0 { ui::rgba(255, 210, 60, 38) } else if r % 3 == 1 { ui::rgba(100, 220, 255, 38) } else { ui::rgba(255, 100, 200, 38) };
        ui::fill_triangle(c, cx, cy, cx + cos(a) * sw, cy + sin(a) * sh, cx + cos(a + 0.32) * sw, cy + sin(a + 0.32) * sh, rc);
    }
    // Stage spotlight disc
    ui::fill_circle(c, ui::rect(cx - k * 0.95, cy + k * 0.32, k * 1.9, k * 0.52), ui::rgba(255, 235, 140, 55));
    ui::fill_circle(c, ui::rect(cx - k * 0.72, cy + k * 0.38, k * 1.44, k * 0.38), ui::rgba(255, 245, 200, 85));
    // Animated confetti
    for p in 28 {
        let pf = p as f32;
        let px = ((pf * 97.3 + sin(tm * 2.5 + pf) * 40.0) % sw + sw) % sw;
        let py = ((pf * 61.7 + tm * (140.0 + (p % 5) as f32 * 25.0)) % sh);
        let cc = col(p % 4);
        ui::fill_rect(c, ui::rect(px, py, 10.0, 10.0), 2.0, cc);
    }
    // Bouncing, wiggling, groove-spinning winner right in everyone's faces
    let beat = tm * 11.0;
    let jump = abs(sin(beat)) * k * 0.22;
    let sway = sin(beat) * k * 0.14;
    let dx = cx + sway;
    let dy = cy - jump;
    let spin = ((tm * 3.5) as i64) % 4;
    let fx: f32 = if spin == 1 { 1.0 } else if spin == 3 { -1.0 } else { 0.0 };
    let fy: f32 = if spin == 0 || spin == 2 { 1.0 } else { 0.0 };
    let arm_l = sin(beat * 2.0) * k * 0.25;
    let arm_r = -arm_l;
    ui::stroke_line(c, dx - k * 0.44, dy, dx - k * 0.78, dy - k * 0.2 + arm_l, 8.0, ui::rgb(255, 255, 255));
    ui::stroke_line(c, dx + k * 0.44, dy, dx + k * 0.78, dy - k * 0.2 + arm_r, 8.0, ui::rgb(255, 255, 255));
    draw_character(c, s.players[who].kind, who, dx, dy, k, fx, fy, sin(beat * 2.0) * k * 0.04);
    // Golden crown bouncing on top
    let cy0 = dy - k * 0.62 - abs(cos(beat)) * k * 0.08;
    let cw = k * 0.44;
    let ch = k * 0.22;
    let gold = ui::rgb(255, 215, 50);
    ui::fill_rect(c, ui::rect(dx - cw * 0.5, cy0, cw, ch * 0.5), 3.0, gold);
    ui::fill_triangle(c, dx - cw * 0.5, cy0, dx - cw * 0.22, cy0, dx - cw * 0.42, cy0 - ch * 0.7, gold);
    ui::fill_triangle(c, dx - cw * 0.16, cy0, dx + cw * 0.16, cy0, dx, cy0 - ch * 0.9, gold);
    ui::fill_triangle(c, dx + cw * 0.22, cy0, dx + cw * 0.5, cy0, dx + cw * 0.42, cy0 - ch * 0.7, gold);
    // Orbiting sparkles
    for sp in 6 {
        let a = tm * 4.0 + sp as f32 * 1.0472;
        let sx = dx + cos(a) * k * 0.78;
        let sy = dy + sin(a) * k * 0.58;
        let r = 6.0 + 4.0 * sin(tm * 12.0 + sp as f32);
        ui::fill_circle(c, ui::rect(sx - r, sy - r, r * 2.0, r * 2.0), ui::rgb(255, 245, 130));
    }
    var sub: u8[>..] = [];
    if s.players[who].streak >= 2 { format(sub, "VICTORY DANCE!  ", s.players[who].streak, " WIN STREAK!"); }
    else { sub.append("VICTORY DANCE!"); }
    let sw2 = ui::text_width(ui::font(c), sub);
    ui::fill_rect(c, ui::rect((sw - sw2) * 0.5 - 16.0, sh - 68.0, sw2 + 32.0, 34.0), 8.0, ui::rgba(15, 18, 30, 210));
    text(c, (sw - sw2) * 0.5, sh - 63.0, sub, ui::rgb(255, 225, 90));
}

fn draw(hud: ui::Context, big: ui::Context, s: State&, shown: float2[:], fx: Fx&, mode: const u8[:]) {
    let size = gfx::screen_size();
    let tm = gfx::time() as f32;
    let top: f32 = 46.0;
    let t = min((size.x as f32) / W, (size.y as f32 - top) / H);
    let ox = (size.x as f32 - t * W) / 2.0 + fx.shake * sin(tm * 90.0);
    let oy = top + fx.shake * cos(tm * 77.0);
    fx.shake *= 0.88;
    if ui::begin(hud, "G", ui::rect(0, 0, size.x, size.y), ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        ui::fill_rect(hud, ui::rect(ox - 8.0, oy - 8.0, t * W + 16.0, t * H + 16.0), 10.0, map_border_color(s.map));
        for ty in H {
            for tx in W {
                let g = s.grid[ty * W + tx];
                let x = ox + tx * t;
                let y = oy + ty * t;
                draw_floor(hud, s.map, tx, ty, x, y, t);
                if g == 1 { draw_wall(hud, s.map, x, y, t); }
                else if g == 2 { draw_brick(hud, s.map, x, y, t); }
                else if g == 6 { draw_steel(hud, x, y, t); }
                else if g == 7 { draw_gift(hud, x, y, t, tm); }
                else if (g >= 3 && g <= 5) || g == 8 || g == 9 { draw_power(hud, g, x, y, t, tm); }
                else if g >= 16 { draw_flame(hud, g, x, y, t, tm); }
            }
        }
        for b in s.bombs { draw_bomb(hud, s, b, ox, oy, t, tm); }
        for k in 2 {
            if s.sheep[k].alive != 0 { draw_sheep(hud, s.sheep[k], ox + s.sheep[k].x as f32 / TILE * t, oy + s.sheep[k].y as f32 / TILE * t, t, tm); }
        }
        for d in fx.dust {
            let a = 1.0 - d.z / 40.0;
            let r = t * (0.05 + 0.05 * a);
            ui::fill_circle(hud, ui::rect(ox + d.x / TILE * t - r, oy + d.y / TILE * t - r - d.z * 0.25, r * 2.0, r * 2.0), ui::rgba(220, 215, 200, (50.0 * a) as i64));
        }
        for i in 4 {
            if s.players[i].on != 0 && s.players[i].alive != 0 {
                draw_player(hud, s, i, ox + shown[i].x / TILE * t, oy + shown[i].y / TILE * t, t, tm);
            }
        }
        ui::fill_rect(hud, ui::rect(0, 0, size.x, top - 10.0), 0.0, ui::rgba(10, 12, 20, 200));
        var x: f32 = 16.0;
        for i in 4 {
            guard s.players[i].on != 0 else { continue; }
            var nm: u8[>..] = [];
            player_name(s, i, nm);
            var line: u8[>..] = [];
            if s.players[i].streak >= 2 { format(line, nm[..], " ", s.players[i].wins, " [", s.players[i].streak, "x]"); }
            else { format(line, nm[..], " ", s.players[i].wins); }
            let lw = ui::text_width(ui::font(hud), line);
            let boxw = max(92.0, lw + 34.0);
            marker(hud, i, x + 10.0, 17.0, 8.0);
            text(hud, x + 24.0, 4.0, line, if s.players[i].alive != 0 { ui::rgb(240, 240, 245) } else { ui::rgb(120, 124, 140) });
            if i == s.you && mode != "solo" { ui::stroke_rect(hud, ui::rect(x - 6.0, 2.0, boxw, 28.0), 6.0, 2.0, ui::rgb(255, 255, 255)); }
            x += boxw + 12.0;
        }
        var tag: u8[>..] = [];
        if mode == "solo" { tag.append("SOLO"); } else if mode == "host" { tag.append("HOST"); } else { format(tag, "CLIENT P", s.you + 1); if mode == "udp" { tag.append(" UDP"); } }
        if fx.lost { tag.append("  DISCONNECTED"); }
        text(hud, size.x - 16.0 - ui::text_width(ui::font(hud), tag), 4.0, tag, ui::rgb(150, 156, 176));
        if s.over > 0 && s.dance_who < 4 {
            draw_dance(hud, s, s.dance_who as i64, size, tm);
        }
    }
    ui::end(hud);
    if ui::begin(big, "B", ui::rect(0, 0, size.x, size.y), ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) && s.over > 0 {
        if s.dance_who < 4 {
            let who = s.dance_who as i64;
            var nm: u8[>..] = [];
            player_name(s, who, nm);
            var title: u8[>..] = [];
            format(title, nm[..], " - ", s.players[who].wins, " WINS!");
            let tw = ui::text_width(ui::font(big), title);
            text(big, (size.x as f32 - tw) * 0.5, 48.0, title, col(who));
        } else {
            var who = -1;
            for i in 4 { if s.players[i].on != 0 && s.players[i].alive != 0 { who = i; } }
            var msg: u8[>..] = [];
            if who >= 0 && s.players[who].on != 0 {
                var nm: u8[>..] = [];
                player_name(s, who, nm);
                if s.players[who].streak >= 2 { format(msg, nm[..], " WINS! (", s.players[who].streak, "x)"); }
                else { format(msg, nm[..], " WINS!"); }
            } else { msg.append("DRAW"); }
            let w = ui::text_width(ui::font(big), msg);
            ui::fill_rect(big, ui::rect(0, size.y / 2.0 - 60.0, size.x, 110.0), 0.0, ui::rgba(10, 12, 20, 190));
            text(big, (size.x as f32 - w) / 2.0, size.y / 2.0 - 52.0, msg, if who >= 0 { col(who) } else { ui::rgb(230, 230, 235) });
        }
    }
    ui::end(big);
}

// ---- main -------------------------------------------------------------------------------------

fn keys() -> u8 {
    var b: u8 = 0;
    if gfx::key_down("Up") || gfx::key_down("W") { b |= UP; }
    if gfx::key_down("Down") || gfx::key_down("S") { b |= DOWN; }
    if gfx::key_down("Left") || gfx::key_down("A") { b |= LEFT; }
    if gfx::key_down("Right") || gfx::key_down("D") { b |= RIGHT; }
    if gfx::key_down("Space") { b |= BOMB; }
    if gfx::key_down("Left Shift") || gfx::key_down("Right Shift") { b |= HOLD; }
    return b;
}

// A bot's keys: wander in changing directions and drop bombs now and then.
fn bot(frame: i64, seed: i64) -> u8 {
    let d = ((frame / 20 + seed) * 7) % 4;
    var b: u8 = (1 << d) as u8;
    if frame % 45 == 0 { b |= BOMB; }
    return b;
}

// A transparent full-window ui context for drawing on, with a font of the given height.
fn overlay(height: f32) -> ui::Context {
    let c = ui::create_from_memory(ROBOTO, height);
    var style = ui::style(c);
    style.window.fixed_background = ui::style_item_hide();
    ui::set_style(c, style);
    return c;
}

// Little-endian integer of n bytes at i.
fn le(raw: const u8[:], i: i64, n: i64) -> i64 {
    var v = 0;
    for k in n { v |= (raw[i + k] as i64) << (8 * k); }
    return v;
}

fn is_tag(raw: const u8[:], i: i64, t: const u8[:]) -> bool {
    for k in 4 { if raw[i + k] != t[k] { return false; } }
    return true;
}

// Reads 16-bit PCM WAV bytes into f32 samples; info gets sample rate then channel count.
fn wav_pcm(raw: const u8[:], pcm: f32[>..]&, info: i64[>..]&) -> bool {
    var pos = 12;
    var ok = false;
    var rate = 0;
    var ch = 0;
    while pos + 8 <= raw.len {
        let size = le(raw, pos + 4, 4);
        if is_tag(raw, pos, "fmt ") {
            ok = le(raw, pos + 8, 2) == 1 && le(raw, pos + 22, 2) == 16;
            ch = le(raw, pos + 10, 2);
            rate = le(raw, pos + 12, 4);
        } else if is_tag(raw, pos, "data") {
            guard ok && (ch == 1 || ch == 2) else { return false; }
            let n = min(size, raw.len - pos - 8) / 2;
            pcm.resize(n, 0.0);
            for j in n {
                var v = le(raw, pos + 8 + 2 * j, 2);
                if v >= 32768 { v -= 65536; }
                pcm[j] = v as f32 / 32768.0;
            }
            info.push(rate);
            info.push(ch);
            return true;
        }
        pos += 8 + size + size % 2;
    }
    return false;
}

fn main() {
    let argv = args();
    let mode = if argv.len > 1 { argv[1] } else { "solo" };
    guard mode == "solo" || mode == "host" || (mode == "join" && argv.len > 2) else { abort("usage: bomberman [solo | host | join HOST]"); }
    var frames = -1;
    var init_map: u8 = MAP_ISLAND;
    var my_name: u8[..12] = [];
    var my_kind: u8 = if mode == "join" { CHAR_GOOSE } else { default_kind(0) };
    for i in argv.len {
        if argv[i] == "--frames" && i + 1 < argv.len { frames = parse_int(argv[i + 1]); }
        if argv[i] == "--map" && i + 1 < argv.len { init_map = (parse_int(argv[i + 1]) & 3) as u8; }
        if argv[i] == "--name" && i + 1 < argv.len {
            my_name.resize(0);
            let ln = min(12, argv[i + 1].len);
            for k in ln { my_name.push(argv[i + 1][k]); }
        }
    }
    var s = State { .. };
    var prev = State { .. };
    var r = rng { random_seed() };
    var ack: i64[4] = [0, 0, 0, 0];
    let usock = if mode == "host" { udp_open(8080) } else { -1 };
    var upeer: i64[4] = [-1, -1, -1, -1];      // host: where each client's datagrams come from
    var uage: i64[4] = [999, 999, 999, 999];   // host: ticks since a client's last datagram
    var rbuf: u8[>..] = [];
    rbuf.resize(4096, 0);
    let want_udp = mode == "join" && argv.len > 3 && argv[3] == "udp";
    let csock = if want_udp { udp_open(0) } else { -1 };
    let hostpeer = if want_udp { udp_peer(argv[2], 8080) } else { -1 };
    guard !want_udp || (csock >= 0 && hostpeer >= 0) else { abort("udp: cannot open a socket or resolve the host"); }
    var joined = false;  // client: got the first snapshot, so we know our slot
    var lasttick = 0;
    var n_udp = 0;       // datagrams received (host: inputs, client: snapshots)
    var n_applied = 0;       // snapshots applied (from either channel)
    let none = http::MailAddress { .. };
    var addr: http::MailAddress[4] = [none, none, none, none];
    for i in 4 { s.players[i].kind = default_kind(i); }
    s.players[0].on = 1;
    s.players[0].name = my_name;
    s.players[0].kind = my_kind;
    s.drops = 33;
    s.map = init_map;
    reset_round(s, r);
    if mode == "host" {
        let cfg = http::Config { port: 8080, workers: 1, mail_slots: 64, mail_size: 4096, max_waiting: 16, .. };
        thread_spawn(server, cfg);
    }
    if mode == "join" {
        var url: u8[..64] = [];
        format(url, "ws://", argv[2], ":8080/ws");
        thread_spawn(client, url);
        if my_name.len > 0 { qput(Profile { my_kind, my_name }); }
    }
    guard gfx::open("Bomberman", 960, 720, gfx::WINDOW_RESIZABLE) else { abort(str("gfx: ", gfx::error())); }
    audio::open();
    let sfx = make_sfx(r);
    // Your own music: put a 16-bit PCM WAV named music.wav next to the game and it plays instead of the chiptune.
    var wav: u8[>..] = [];
    var pcm: f32[>..] = [];
    var info: i64[>..] = [];
    let own = file_exists("music.wav") && read_file("music.wav", wav) && wav_pcm(wav, pcm, info);
    if own { print("playing music.wav: ", info[0], " Hz, ", info[1], " channels"); }
    let mvol: f32 = if own { 0.5 } else { 0.2 };
    let songs: audio::Sound[6] = [make_music_island(r), make_music_forest(r), make_music_mountains(r), make_music_desert(r), make_music(r), make_dark(r)];
    var track = s.map as i64;
    var last_map = s.map;
    var tune = if own { audio::play(audio::create_sound(pcm, info[0], info[1]), mvol, 0.0, 1.0, true) } else { audio::play(songs[track], mvol, 0.0, 1.0, true) };
    var muted = false;
    let hud = overlay(20.0);
    let big = overlay(72.0);
    let panel = overlay(18.0);
    let menu = ui::create_from_memory(ROBOTO, 17.0);
    var menu_open = frames < 0 && my_name.len == 0;
    let z = float2 { 0.0, 0.0 };
    var shown: float2[4] = [z, z, z, z];
    var fx = Fx { .. };
    var seq = 0;         // client: number of the latest input step
    var hist: u8[..240] = [];       // the key bits of the last steps, to replay on top of a snapshot
    var px = 0;          // client: where this player is predicted to be
    var py = 0;
    var acc = 0.0;
    var n = 0;
    var frame = 0;
    while gfx::frame() {
        if frame == frames { break; }
        if gfx::key_pressed("Escape") {
            if menu_open { menu_open = false; } else { break; }
        }
        let typing = menu_open || ui::wants_keyboard(menu);
        if !typing && gfx::key_pressed("N") && !own {          // cycle through all map themes + classic & dark tracks
            track = (track + 1) % 6;
            audio::stop(tune);
            tune = audio::play(songs[track], if muted { 0.0 } else { mvol }, 0.0, 1.0, true);
        }
        if !typing && gfx::key_pressed("M") { muted = !muted; audio::set_voice(tune, if muted { 0.0 } else { mvol }, 0.0, 1.0); }
        ui::input_from_gfx(hud);
        ui::input_from_gfx(big);
        ui::input_from_gfx(panel);
        ui::input_from_gfx(menu);
        if frames >= 0 { sleep(0.016); }
        let bits = if frames >= 0 { bot(frame, if mode == "join" { 3 } else { 0 }) } else if typing { 0 as u8 } else { keys() };
        acc += if frames >= 0 { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.1) };
        if mode == "join" {
            loop {          // datagram snapshots join the WebSocket's in one stream
                var from = 0;
                let got = udp_recv(csock, rbuf[..], from);
                if got < 0 { break; }
                var f = State { .. };
                if http::mail_value(rbuf[0..got], f) { qput(f); n_udp += 1; }
            }
            loop {
                let f, got = qpoll<State>();
                guard got else { break; }
                if f.tick <= lasttick { continue; }
                lasttick = f.tick;
                n_applied += 1;
                joined = true;
                s = f;
                // The snapshot is a round trip old: replay the inputs the host has not seen, then ease toward that.
                var c = s;
                let back = min((seq - s.ack) & 65535, hist.len);
                if c.players[s.you].alive != 0 {
                    for j in hist.len - back..hist.len { c.players[s.you].bits = hist[j]; step_player(c, s.you); }
                }
                let ex = c.players[s.you].x - px;
                let ey = c.players[s.you].y - py;
                if abs(ex) + abs(ey) > TILE { px = c.players[s.you].x; py = c.players[s.you].y; }
                else { px += ex / 3; py += ey / 3; }
                hear(prev, s, sfx, fx);
                prev = s;
            }
            let l, gone = qpoll<Lost>();
            if gone { fx.lost = true; }
            // Predict our own player with the same rules, so keys answer at once.
            while acc >= 1.0 / 60.0 {
                acc -= 1.0 / 60.0;
                seq = (seq + 1) & 65535;
                if hist.len >= 240 { remove_at(hist, 0); }
                hist.push(bits);
                var c = s;
                c.players[s.you].x = px;
                c.players[s.you].y = py;
                c.players[s.you].bits = bits;
                if c.players[s.you].alive != 0 { step_player(c, s.you); }
                px = c.players[s.you].x;
                py = c.players[s.you].y;
            }
            qput(Pad { bits, seq });
            if want_udp && joined {
                var d: u8[>..] = [];
                d.push(66);
                d.push(s.you);
                d.push(bits);
                d.push((seq & 255) as u8);
                d.push((seq >> 8) as u8);
                udp_send(csock, d[..], hostpeer);
            }
        } else {
            s.players[0].bits = bits;
            loop {
                let m, ok = qpoll<Msg>();
                guard ok else { break; }
                var who = -1;
                for i in 1..4 { if s.players[i].on != 0 && addr[i].key == m.reply.key { who = i; } }
                if who >= 0 && uage[who] < 30 && !m.leave && !m.is_profile { continue; }   // UDP is carrying this player's input
                if who < 0 && !m.leave {
                    for i in 1..4 { if who < 0 && s.players[i].on == 0 { who = i; } }
                    if who >= 0 { addr[who] = m.reply; s.players[who].on = 1; s.players[who].name.resize(0); s.players[who].kind = default_kind(who); s.players[who].wins = 0; s.players[who].streak = 0; upeer[who] = -1; uage[who] = 999; reset_round(s, r); }
                }
                if who < 0 { continue; }
                if m.leave { s.players[who].on = 0; s.players[who].alive = 0; upeer[who] = -1; uage[who] = 999; }
                else if m.is_profile { s.players[who].name = m.name; s.players[who].kind = m.kind; }
                else { s.players[who].bits = m.bits; ack[who] = m.seq; }
            }
            loop {          // datagrams: 'B', slot, bits, seq lo, seq hi
                var from = 0;
                let got = udp_recv(usock, rbuf[..], from);
                if got < 0 { break; }
                guard got >= 5 && rbuf[0] == 66 else { continue; }
                let who = rbuf[1] as i64;
                guard who >= 1 && who < 4 && s.players[who].on != 0 else { continue; }
                let sq = (rbuf[3] as i64) | ((rbuf[4] as i64) << 8);
                n_udp += 1;
                upeer[who] = from;
                uage[who] = 0;
                if ((sq - ack[who]) & 65535) < 32768 { s.players[who].bits = rbuf[2]; ack[who] = sq; }
            }
            while acc >= 1.0 / 60.0 {
                acc -= 1.0 / 60.0;
                tick(s, r, n);
                n += 1;
                s.tick = n;
                for i in 1..4 {
                    guard s.players[i].on != 0 else { continue; }
                    var c = s;
                    c.you = i as u8;
                    c.ack = ack[i];
                    uage[i] += 1;
                    let viaudp = uage[i] < 30 && upeer[i] >= 0;
                    if viaudp {
                        var one = [c];
                        var image: u8[>..] = [];
                        one.to_bytes(image);
                        udp_send(usock, image[..], upeer[i]);
                    }
                    if !viaudp || n % 30 == 0 {          // TCP carries every snapshot, or just a heartbeat while UDP flows
                        if http::mail_send_value(addr[i], 0, c) == http::STALE { s.players[i].on = 0; s.players[i].alive = 0; }
                    }
                }
            }
            hear(prev, s, sfx, fx);
            prev = s;
        }
        for i in 4 {
            let tgt = float2 { s.players[i].x as f32, s.players[i].y as f32 };
            if mode == "join" { shown[i] = if i == s.you { float2 { px as f32, py as f32 } } else { shown[i] + (tgt - shown[i]) * 0.5 }; }
            else { shown[i] = tgt; }
        }
        var di = 0;
        while di < fx.dust.len {
            fx.dust[di].z += 1.0;
            if fx.dust[di].z > 40.0 { remove_at(fx.dust, di); } else { di += 1; }
        }
        for i in 4 {
            let moved = abs(shown[i].x - fx.last[i].x) + abs(shown[i].y - fx.last[i].y) > 0.5;
            if s.players[i].ghost > 0 && moved && fx.dust.len < 64 { fx.dust.push(float4 { shown[i].x, shown[i].y, 0.0, 0.0 }); }
            fx.last[i] = shown[i];
        }
        if s.map != last_map {
            last_map = s.map;
            if !own {
                track = (s.map & 3) as i64;
                audio::stop(tune);
                tune = audio::play(songs[track], if muted { 0.0 } else { mvol }, 0.0, 1.0, true);
            }
        }
        draw(hud, big, s, shown, fx, if want_udp { "udp" } else { mode });
        let sz = gfx::screen_size();
        if ui::begin(panel, "Bar", ui::rect(sz.x as f32 - 440.0, 4.0, 310.0, 28.0), ui::WINDOW_NO_SCROLLBAR) {
            if mode != "join" {
                let rat: f32[3] = [0.28, 0.34, 0.38];
                ui::layout_row(panel, ui::DYNAMIC, 22.0, rat);
                if ui::button_label(panel, "Profile") { menu_open = !menu_open; }
                var mlbl: u8[>..] = [];
                format(mlbl, "Map: ", map_name(s.map));
                if ui::button_label(panel, mlbl) { s.map = (s.map + 1) % 4; reset_round(s, r); }
                s.drops = ui::slide_int(panel, 0, s.drops as i64, 100, 1) as u8;
            } else {
                ui::layout_row_dynamic(panel, 22.0, 1);
                if ui::button_label(panel, "Profile") { menu_open = !menu_open; }
            }
        }
        ui::end(panel);
        if menu_open {
            let mw: f32 = 400.0;
            let mh: f32 = 285.0;
            if ui::begin(menu, "Player Setup", ui::rect((sz.x as f32 - mw) * 0.5, (sz.y as f32 - mh) * 0.5, mw, mh), ui::WINDOW_BORDER | ui::WINDOW_TITLE | ui::WINDOW_NO_SCROLLBAR) {
                ui::layout_row_dynamic(menu, 22.0, 1);
                ui::label(menu, "Your Name (max 12 chars):", ui::TEXT_LEFT);
                ui::layout_row_dynamic(menu, 30.0, 1);
                let ed = ui::edit_string(menu, ui::EDIT_FIELD | ui::EDIT_SIG_ENTER, my_name, ui::FILTER_ASCII);
                ui::layout_row_dynamic(menu, 22.0, 1);
                ui::label(menu, "Pick your Farm Character:", ui::TEXT_LEFT);
                var changed = false;
                ui::layout_row_dynamic(menu, 28.0, 2);
                if ui::option_label(menu, "Goose (Eggs)", my_kind == CHAR_GOOSE) { my_kind = CHAR_GOOSE; changed = true; }
                if ui::option_label(menu, "Squirrel (Acorns)", my_kind == CHAR_SQUIRREL) { my_kind = CHAR_SQUIRREL; changed = true; }
                ui::layout_row_dynamic(menu, 28.0, 2);
                if ui::option_label(menu, "Baby (Diapers)", my_kind == CHAR_BABY) { my_kind = CHAR_BABY; changed = true; }
                if ui::option_label(menu, "Cow (Patties)", my_kind == CHAR_COW) { my_kind = CHAR_COW; changed = true; }
                ui::layout_row_dynamic(menu, 28.0, 2);
                if ui::option_label(menu, "Pig (Bacon)", my_kind == CHAR_PIG) { my_kind = CHAR_PIG; changed = true; }
                if ui::option_label(menu, "Farmer (Hay Bales)", my_kind == CHAR_FARMER) { my_kind = CHAR_FARMER; changed = true; }
                ui::layout_row_dynamic(menu, 32.0, 1);
                let done = ui::button_label(menu, "Play!") || (ed & ui::EDIT_COMMITTED) != 0;
                if mode == "join" {
                    if changed || (ed & ui::EDIT_ACTIVE) != 0 || done { qput(Profile { my_kind, my_name }); }
                } else {
                    s.players[0].name = my_name;
                    s.players[0].kind = my_kind;
                }
                if done { menu_open = false; }
            }
            ui::end(menu);
        }
        gfx::begin_screen(map_clear_color(s.map));
        gfx::end_pass();
        ui::render(hud);
        ui::render(big);
        ui::render(panel);
        ui::render(menu);
        frame += 1;
    }
    for i in 4 { if s.players[i].on != 0 { print("player ", i, " at ", s.players[i].x / TILE, ",", s.players[i].y / TILE, " alive ", s.players[i].alive, " wins ", s.players[i].wins, " streak ", s.players[i].streak); } }
    if mode != "solo" { print("datagrams ", n_udp, ", snapshots applied ", n_applied); }
    ui::destroy(hud);
    ui::destroy(big);
    ui::destroy(panel);
    ui::destroy(menu);
    audio::close();
    gfx::close();
}
