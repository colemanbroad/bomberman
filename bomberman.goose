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
let GHOST = 600;             // ghost power-up length in ticks

// Tile values: 0 empty, 1 wall, 2 brick, 3 range+, 4 bomb+, 5 speed+, 8 ghost, 6 steel crate (two hits), 7 gift crate (always drops),
// 16+ttl flame, 32+ttl flame over a brick (may drop), 48+ttl flame over a gift (drops).
let ROBOTO: const u8[:] = embed_file("Roboto-Regular.ttf");
struct Player { x: i64, y: i64, on: u8, alive: u8, bombs: u8, range: u8, speed: u8, wins: u8, bits: u8, held: u8, placed: u8, ghost: u16 }
struct Bomb { x: u8, y: u8, t: u8, range: u8, owner: u8 }
struct State { grid: u8[195], players: Player[4], bombs: Bomb[..16], over: i64, you: u8 }

// Host: input from a connection (reply names it). Client: the key bits to send.
struct Msg { reply: http::MailAddress, bits: u8, leave: bool }
struct Pad { bits: u8 }
struct Lost { code: i64 }

// ---- simulation -------------------------------------------------------------------------------

fn bomb_at(s: State&, tx: i64, ty: i64) -> i64 {
    for i in s.bombs.len { if s.bombs[i].x == tx && s.bombs[i].y == ty { return i; } }
    return -1;
}

// Does player p's box centered at x y hit a wall, block, or a bomb it is not already standing on?
fn blocked(s: State&, i: i64, x: i64, y: i64) -> bool {
    let p = s.players[i];
    for j in 4 {
        let q = s.players[j];
        guard j != i && q.on != 0 && q.alive != 0 && (q.bits & HOLD) != 0 else { continue; }
        let into = abs(x - q.x) < 2 * HB && abs(y - q.y) < 2 * HB;
        let inside = abs(p.x - q.x) < 2 * HB && abs(p.y - q.y) < 2 * HB;
        if into && !inside { return true; }
    }
    for ty in (y - HB) / TILE..(y + HB - 1) / TILE + 1 {
        for tx in (x - HB) / TILE..(x + HB - 1) / TILE + 1 {
            let g = s.grid[ty * W + tx];
            if g == 1 || g == 2 { return true; }
            let on_it = tx >= (p.x - HB) / TILE && tx <= (p.x + HB - 1) / TILE &&
                        ty >= (p.y - HB) / TILE && ty <= (p.y + HB - 1) / TILE;
            if bomb_at(s, tx, ty) >= 0 && !on_it { return true; }
        }
    }
    return false;
}

fn reset_round(s: State&, r: rng&) {
    for ty in H {
        for tx in W {
            var g: u8 = 0;
            let cx = min(tx, W - 1 - tx);
            let cy = min(ty, H - 1 - ty);
            if cx == 0 || cy == 0 || (tx % 2 == 0 && ty % 2 == 0) { g = 1; }
            else if cx + cy > 3 && r.rand_int(10) < 7 {
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
    }
    s.bombs.resize(0);
    s.over = 0;
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
    if (g >= 3 && g <= 5) || g == 8 {
        if g == 3 { s.players[i].range += 1; }
        if g == 4 { s.players[i].bombs += 1; }
        if g == 5 && s.players[i].speed < 3 { s.players[i].speed += 1; }
        if g == 8 { s.players[i].ghost = GHOST; }
        s.grid[ty * W + tx] = 0;
    }
    let p = s.players[i];
    if (bits & BOMB) != 0 && p.held == 0 && p.placed < p.bombs && bomb_at(s, tx, ty) < 0 {
        s.bombs.push(Bomb { tx as u8, ty as u8, FUSE, p.range, i as u8 });
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
    for i in s.bombs.len { s.bombs[i].t -= 1; }
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
            else if g >= 48 || (g >= 32 && r.rand_int(3) == 0) {
                let k = r.rand_int(5);
                s.grid[i] = if k == 4 { 8 } else { 3 + k as u8 };
            }
            else { s.grid[i] = 0; }
        }
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
        if joined > 1 && alive == 1 { s.players[last].wins += 1; }
    }
}

// ---- network ----------------------------------------------------------------------------------

struct Conn { ws: http::WebSocket = http::WebSocket { limit: 4096, .. }, reply: http::MailAddress }

fn serve_event(ev: http::Event, st: Conn&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        http::ws_upgrade(ev.req, st.ws, out);
    } else if ev.kind == http::WAKE {
        http::ws_send(out, http::WS_BINARY, ev.data);       // a snapshot mailed by the game
        http::later(out, 5000);
    } else if ev.kind == http::TIMEOUT {
        http::later(out, 5000);
    } else {
        if ev.kind == http::CLOSED && st.reply.key != 0 { qput(Msg { st.reply, 0, true }); }
        http::ws_read(ev, st.ws, out) { op, data, o =>
            if st.reply.key == 0 { st.reply = http::later(o, 5000); }
            if data.len > 0 { qput(Msg { st.reply, data[0], false }); }
        };
    }
}

thread_fn server(cfg: http::Config) {
    http::report(http::serve(cfg, Conn { .. }) { ev, st, out => serve_event(ev, st, out); });
}

// Joins ws://url: sends the key bits main queues, and queues each snapshot back to main.
thread_fn client(url: u8[..64]) {
    var session = http::session();
    var conn, err = http::ws_client_connect(session, url[..]);
    guard err.code == 0 else { write_stderr(str("connect: ", err.call, " ", err.code, "\n")); qput(Lost { 1 }); return; }
    var bits: u8 = 0;
    loop {
        var one: u8[>..] = [];
        one.push(bits);
        guard http::ws_client_binary(conn, one).code == 0 else { break; }
        let m, e = http::ws_client_recv(conn);
        guard e.code == 0 else { break; }
        var s = State { .. };
        if http::mail_value(m.data, s) { qput(s); }
        loop {
            let p, ok = qpoll<Pad>();
            guard ok else { break; }
            bits = p.bits;
        }
    }
    qput(Lost { 2 });
}

// ---- sound ------------------------------------------------------------------------------------

struct Sfx { place: audio::Sound, boom: audio::Sound, pickup: audio::Sound, die: audio::Sound, win: audio::Sound, clank: audio::Sound }
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

fn make_sfx(r: rng&) -> Sfx {
    Sfx { synth(r, 0.12, 220.0, 110.0, 0.1, 6.0), synth(r, 0.7, 90.0, 35.0, 0.85, 4.5), synth(r, 0.25, 500.0, 1100.0, 0.0, 5.0),
          synth(r, 0.6, 400.0, 60.0, 0.1, 3.0), synth(r, 0.7, 523.0, 1318.0, 0.0, 2.0), synth(r, 0.1, 1200.0, 800.0, 0.5, 12.0) }
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

fn pan(x: i64) -> f32 { ((x as f32) / ((W * TILE) as f32) - 0.5) * 1.6 }

// Plays what changed between two snapshots, so a client hears what the host's game did.
fn hear(prev: State&, s: State&, sfx: Sfx, fx: Fx&) {
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
    for i in 4 {
        let a = prev.players[i];
        let b = s.players[i];
        guard a.on != 0 && b.on != 0 else { continue; }
        let vol = if i == s.you { 0.8 } else { 0.4 };
        if a.alive != 0 && b.alive == 0 { audio::play(sfx.die, 0.8, pan(b.x), 1.0, false); }
        if b.range + b.bombs + b.speed > a.range + a.bombs + a.speed || (a.ghost == 0 && b.ghost > 0) { audio::play(sfx.pickup, vol, pan(b.x), 1.0, false); }
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

fn draw_wall(c: ui::Context, x: f32, y: f32, t: f32) {
    ui::fill_rect(c, ui::rect(x, y, t, t), 3.0, ui::rgb(92, 100, 120));
    ui::fill_rect(c, ui::rect(x, y, t, t * 0.14), 3.0, ui::rgb(140, 150, 172));
    ui::fill_rect(c, ui::rect(x, y + t * 0.86, t, t * 0.14), 3.0, ui::rgb(58, 64, 82));
    ui::stroke_rect(c, ui::rect(x + t * 0.15, y + t * 0.2, t * 0.7, t * 0.6), 2.0, 1.5, ui::rgb(70, 77, 96));
    for k in 4 {
        ui::fill_circle(c, ui::rect(x + t * (0.08 + (k % 2) * 0.8), y + t * (0.1 + (k / 2) * 0.76), t * 0.1, t * 0.1), ui::rgb(160, 168, 188));
    }
}

fn draw_brick(c: ui::Context, x: f32, y: f32, t: f32) {
    let mortar = ui::rgb(112, 58, 38);
    ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(186, 104, 64));
    ui::fill_rect(c, ui::rect(x, y, t, t * 0.1), 4.0, ui::rgb(214, 134, 90));
    for r in 3 {
        let yy = y + t * (r as f32) / 3.0;
        if r > 0 { ui::stroke_line(c, x, yy, x + t, yy, 2.0, mortar); }
        let off = if r % 2 == 0 { 0.5 } else { 0.25 };
        ui::stroke_line(c, x + t * off, yy, x + t * off, yy + t / 3.0, 2.0, mortar);
        if r % 2 == 1 { ui::stroke_line(c, x + t * 0.75, yy, x + t * 0.75, yy + t / 3.0, 2.0, mortar); }
    }
    ui::stroke_rect(c, ui::rect(x, y, t, t), 4.0, 2.0, ui::rgb(90, 46, 30));
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
    let plate = if g == 3 { ui::rgb(200, 60, 40) } else if g == 4 { ui::rgb(70, 70, 84) } else if g == 8 { ui::rgb(120, 80, 190) } else { ui::rgb(30, 150, 205) };
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

fn draw_bomb(c: ui::Context, b: Bomb, ox: f32, oy: f32, t: f32, tm: f32) {
    let k = (0.72 + 0.06 * sin(tm * 10.0 + b.t)) * t;
    let cx = ox + (b.x + 0.5) * t;
    let cy = oy + (b.y + 0.5) * t;
    ui::fill_circle(c, ui::rect(cx - k * 0.5, cy + k * 0.2, k, k * 0.4), ui::rgba(0, 0, 0, 90));
    ui::fill_circle(c, ui::rect(cx - k * 0.5, cy - k * 0.5, k, k), if b.t < 45 && (b.t / 6) % 2 == 0 { ui::rgb(120, 25, 25) } else { ui::rgb(22, 22, 30) });
    ui::stroke_circle(c, ui::rect(cx - k * 0.5, cy - k * 0.5, k, k), 3.0, col(b.owner));
    ui::fill_circle(c, ui::rect(cx - k * 0.3, cy - k * 0.32, k * 0.2, k * 0.2), ui::rgba(255, 255, 255, 170));
    ui::stroke_line(c, cx + k * 0.25, cy - k * 0.42, cx + k * 0.4, cy - k * 0.68, 2.5, ui::rgb(230, 200, 140));
    let sp = (0.12 + 0.05 * sin(tm * 30.0)) * t;
    ui::fill_circle(c, ui::rect(cx + k * 0.4 - sp, cy - k * 0.68 - sp, sp * 2.0, sp * 2.0), ui::rgb(255, 220, 80));
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
    ui::fill_circle(c, ui::rect(x - k * 0.5, y - k * 0.5 + walk, k, k), col(i));
    ui::stroke_circle(c, ui::rect(x - k * 0.5, y - k * 0.5 + walk, k, k), 3.0, ui::rgb(255, 255, 255));
    ui::fill_circle(c, ui::rect(x - k * 0.3, y - k * 0.42 + walk, k * 0.22, k * 0.22), ui::rgba(255, 255, 255, 120));
    for e in 2 {
        let ex = x + (if e == 0 { -1.0 } else { 1.0 }) * k * 0.2 + fx * k * 0.1;
        let ey = y - k * 0.05 + fy * k * 0.1 + walk;
        ui::fill_circle(c, ui::rect(ex - k * 0.13, ey - k * 0.16, k * 0.26, k * 0.32), ui::rgb(255, 255, 255));
        ui::fill_circle(c, ui::rect(ex - k * 0.06 + fx * k * 0.06, ey - k * 0.06 + fy * k * 0.06, k * 0.14, k * 0.14), ui::rgb(20, 20, 30));
    }
    marker(c, i, x, y - k * 0.78 + walk, t * 0.13);
    if i == s.you {
        let bob = 0.06 * t * sin(tm * 6.0);
        ui::fill_triangle(c, x, y - k * 1.0 + bob, x + t * 0.1, y - k * 1.2 + bob, x - t * 0.1, y - k * 1.2 + bob, ui::rgb(255, 255, 255));
    }
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
        ui::fill_rect(hud, ui::rect(ox - 8.0, oy - 8.0, t * W + 16.0, t * H + 16.0), 10.0, ui::rgb(28, 32, 44));
        for ty in H {
            for tx in W {
                let g = s.grid[ty * W + tx];
                let x = ox + tx * t;
                let y = oy + ty * t;
                ui::fill_rect(hud, ui::rect(x, y, t, t), 0.0, if (tx + ty) % 2 == 0 { ui::rgb(54, 62, 78) } else { ui::rgb(60, 68, 86) });
                if g == 1 { draw_wall(hud, x, y, t); }
                else if g == 2 { draw_brick(hud, x, y, t); }
                else if g == 6 { draw_steel(hud, x, y, t); }
                else if g == 7 { draw_gift(hud, x, y, t, tm); }
                else if (g >= 3 && g <= 5) || g == 8 { draw_power(hud, g, x, y, t, tm); }
                else if g >= 16 { draw_flame(hud, g, x, y, t, tm); }
            }
        }
        for b in s.bombs { draw_bomb(hud, b, ox, oy, t, tm); }
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
            var line: u8[>..] = [];
            format(line, "P", i + 1, "  ", s.players[i].wins);
            marker(hud, i, x + 10.0, 17.0, 8.0);
            text(hud, x + 26.0, 4.0, line, if s.players[i].alive != 0 { ui::rgb(240, 240, 245) } else { ui::rgb(120, 124, 140) });
            if i == s.you && mode != "solo" { ui::stroke_rect(hud, ui::rect(x - 6.0, 2.0, 112.0, 28.0), 6.0, 2.0, ui::rgb(255, 255, 255)); }
            x += 124.0;
        }
        var tag: u8[>..] = [];
        if mode == "solo" { tag.append("SOLO"); } else if mode == "host" { tag.append("HOST"); } else { format(tag, "CLIENT P", s.you + 1); }
        if fx.lost { tag.append("  DISCONNECTED"); }
        text(hud, size.x - 24.0 - ui::text_width(ui::font(hud), tag), 4.0, tag, ui::rgb(150, 156, 176));
    }
    ui::end(hud);
    if ui::begin(big, "B", ui::rect(0, 0, size.x, size.y), ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) && s.over > 0 {
        var who = -1;
        for i in 4 { if s.players[i].on != 0 && s.players[i].alive != 0 { who = i; } }
        var msg: u8[>..] = [];
        if who >= 0 && s.players[who].on != 0 { format(msg, "P", who + 1, " WINS!"); } else { msg.append("DRAW"); }
        let w = ui::text_width(ui::font(big), msg);
        ui::fill_rect(big, ui::rect(0, size.y / 2.0 - 60.0, size.x, 110.0), 0.0, ui::rgba(10, 12, 20, 190));
        text(big, (size.x as f32 - w) / 2.0, size.y / 2.0 - 52.0, msg, if who >= 0 { col(who) } else { ui::rgb(230, 230, 235) });
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

fn main() {
    let argv = args();
    let mode = if argv.len > 1 { argv[1] } else { "solo" };
    guard mode == "solo" || mode == "host" || (mode == "join" && argv.len > 2) else { abort("usage: bomberman [solo | host | join HOST]"); }
    var frames = -1;
    for i in argv.len { if argv[i] == "--frames" && i + 1 < argv.len { frames = parse_int(argv[i + 1]); } }
    var s = State { .. };
    var prev = State { .. };
    var r = rng { random_seed() };
    let none = http::MailAddress { .. };
    var addr: http::MailAddress[4] = [none, none, none, none];
    s.players[0].on = 1;
    reset_round(s, r);
    if mode == "host" {
        let cfg = http::Config { port: 8080, workers: 1, mail_slots: 64, mail_size: 512, max_waiting: 16, .. };
        thread_spawn(server, cfg);
    }
    if mode == "join" {
        var url: u8[..64] = [];
        format(url, "ws://", argv[2], ":8080/ws");
        thread_spawn(client, url);
    }
    guard gfx::open("Bomberman", 960, 720, gfx::WINDOW_RESIZABLE) else { abort(str("gfx: ", gfx::error())); }
    audio::open();
    let sfx = make_sfx(r);
    let tune = audio::play(make_music(r), 0.2, 0.0, 1.0, true);
    var muted = false;
    let hud = overlay(20.0);
    let big = overlay(72.0);
    let z = float2 { 0.0, 0.0 };
    var shown: float2[4] = [z, z, z, z];
    var fx = Fx { .. };
    var px = 0;          // client: where this player is predicted to be
    var py = 0;
    var acc = 0.0;
    var n = 0;
    var frame = 0;
    while gfx::frame() {
        if gfx::key_pressed("Escape") || frame == frames { break; }
        if gfx::key_pressed("M") { muted = !muted; audio::set_voice(tune, if muted { 0.0 } else { 0.2 }, 0.0, 1.0); }
        ui::input_from_gfx(hud);
        ui::input_from_gfx(big);
        if frames >= 0 { sleep(0.016); }
        let bits = if frames >= 0 { bot(frame, if mode == "join" { 3 } else { 0 }) } else { keys() };
        acc += if frames >= 0 { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.1) };
        if mode == "join" {
            qput(Pad { bits });
            loop {
                let f, got = qpoll<State>();
                guard got else { break; }
                s = f;
                let ex = s.players[s.you].x - px;
                let ey = s.players[s.you].y - py;
                if abs(ex) + abs(ey) > 80 { px = s.players[s.you].x; py = s.players[s.you].y; }
                else if bits == 0 { px += ex / 3; py += ey / 3; }
                hear(prev, s, sfx, fx);
                prev = s;
            }
            let l, gone = qpoll<Lost>();
            if gone { fx.lost = true; }
            // Predict our own player with the same rules, so keys answer at once.
            while acc >= 1.0 / 60.0 {
                acc -= 1.0 / 60.0;
                var c = s;
                c.players[s.you].x = px;
                c.players[s.you].y = py;
                c.players[s.you].bits = bits;
                if c.players[s.you].alive != 0 { step_player(c, s.you); }
                px = c.players[s.you].x;
                py = c.players[s.you].y;
            }
        } else {
            s.players[0].bits = bits;
            loop {
                let m, ok = qpoll<Msg>();
                guard ok else { break; }
                var who = -1;
                for i in 1..4 { if s.players[i].on != 0 && addr[i].key == m.reply.key { who = i; } }
                if who < 0 && !m.leave {
                    for i in 1..4 { if who < 0 && s.players[i].on == 0 { who = i; } }
                    if who >= 0 { addr[who] = m.reply; s.players[who].on = 1; reset_round(s, r); }
                }
                if who < 0 { continue; }
                if m.leave { s.players[who].on = 0; s.players[who].alive = 0; }
                else { s.players[who].bits = m.bits; }
            }
            while acc >= 1.0 / 60.0 {
                acc -= 1.0 / 60.0;
                tick(s, r, n);
                n += 1;
                for i in 1..4 {
                    guard s.players[i].on != 0 else { continue; }
                    var c = s;
                    c.you = i as u8;
                    if http::mail_send_value(addr[i], 0, c) == http::STALE { s.players[i].on = 0; s.players[i].alive = 0; }
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
        draw(hud, big, s, shown, fx, mode);
        gfx::begin_screen(float4 { 0.06, 0.07, 0.1, 1.0 });
        gfx::end_pass();
        ui::render(hud);
        ui::render(big);
        frame += 1;
    }
    for i in 4 { if s.players[i].on != 0 { print("player ", i, " at ", s.players[i].x / TILE, ",", s.players[i].y / TILE, " alive ", s.players[i].alive, " wins ", s.players[i].wins); } }
    ui::destroy(hud);
    ui::destroy(big);
    audio::close();
    gfx::close();
}
