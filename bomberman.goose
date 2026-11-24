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
let MINE_KEY = 64;           // E / X drops a proximity mine (Shift+Space also works)
let BUILD_KEY = 128;         // Q places a 2-hit reinforced block ahead; Shift+Q places a 2-hit chain-link fence on the tile edge
let FIRE_KEY = 256;          // F fires active weapon (flamethrower / fireball)
let SLIDE = 5;               // ticks a kicked bomb takes per tile
let GHOST = 600;             // ghost power-up length in ticks
let NAPALM = 480;            // napalm trail length in ticks
let DRUNK = 900;             // drunk jitter length in ticks
let BOMB_UNKICK: u8 = 1;
let BOMB_WARPED: u8 = 2;
let CAUSE_NONE: u8 = 0;
let CAUSE_BOMB: u8 = 1;
let CAUSE_SUICIDE: u8 = 2;
let CAUSE_SHEEP: u8 = 3;

enum Character { Goose, Squirrel, Baby, Cow, Pig, Farmer }
enum Map { Island, Forest, Mountains, Desert, Sandbox }
enum Dir { None, Up, Down, Left, Right }
enum Life { Off, Alive, BlackSheep, FogGhost }
enum GameMode { Lobby, Solo, Host, Join }
enum HostNet { Lan, Upnp, Playit }
enum MatchMode { FreeForAll, Teams2v2, Prey, Predator }

fn is_dead(l: Life) -> bool { l == Life.BlackSheep || l == Life.FogGhost }

fn default_kind(slot: i64) -> Character {
    if slot == 0 { return Character.Farmer; }
    if slot == 1 { return Character.Goose; }
    if slot == 2 { return Character.Cow; }
    return Character.Pig;
}

fn char_to_u8(k: Character) -> u8 {
    match k {
        Goose => { return 0; },
        Squirrel => { return 1; },
        Baby => { return 2; },
        Cow => { return 3; },
        Pig => { return 4; },
        Farmer => { return 5; },
    }
}

fn char_from_u8(v: u8) -> Character {
    if v == 1 { return Character.Squirrel; }
    if v == 2 { return Character.Baby; }
    if v == 3 { return Character.Cow; }
    if v == 4 { return Character.Pig; }
    if v == 5 { return Character.Farmer; }
    return Character.Goose;
}

fn map_from_int(v: i64) -> Map {
    let m = ((v % 5) + 5) % 5;
    if m == 1 { return Map.Forest; }
    if m == 2 { return Map.Mountains; }
    if m == 3 { return Map.Desert; }
    if m == 4 { return Map.Sandbox; }
    return Map.Island;
}

fn map_name(m: Map) -> const u8[:] {
    match m {
        Island => { return "Island"; },
        Forest => { return "Forest"; },
        Mountains => { return "Mountains"; },
        Desert => { return "Desert"; },
        Sandbox => { return "Sandbox"; },
    }
}

fn map_track(m: Map) -> i64 {
    match m {
        Forest => { return 0; },
        Mountains => { return 1; },
        Desert => { return 2; },
        Sandbox => { return 3; },
        Island => { return 5; },
    }
}

fn dir_dx(d: Dir) -> i64 {
    match d {
        Left => { return -1; },
        Right => { return 1; },
        _ => { return 0; },
    }
}

fn dir_dy(d: Dir) -> i64 {
    match d {
        Up => { return -1; },
        Down => { return 1; },
        _ => { return 0; },
    }
}

fn dir_from_int(v: i64) -> Dir {
    if v == 1 { return Dir.Up; }
    if v == 2 { return Dir.Down; }
    if v == 3 { return Dir.Left; }
    if v == 4 { return Dir.Right; }
    return Dir.None;
}

// Tile values: 0 empty, 1 wall, 2 brick, 3 range+, 4 bomb+, 5 speed+, 6 steel crate (two hits), 7 gift crate (always drops),
// 8 ghost, 9 kick, 10 missile, 11 napalm, 12 mines, 13 drunk, 14 bad/curse, 15 unkickable bombs,
// 16..31 flame, 32..47 flame over brick, 48..63 flame over gift, 64..95 slow-decaying napalm flame, 96..127 fog cloud,
// 128 brush/forest (walkable, hides players, burns away), 129 semi-permeable grate (blocks players, lets bombs & flames pass),
// 130 builder kit power-up.

let TILE_BRUSH: u8 = 128;
let TILE_GRATE: u8 = 129;
let TILE_PWR_BUILD: u8 = 130;
let TILE_PWR_DIRBOMB: u8 = 131;
let TILE_PWR_FLAMER: u8 = 132;
let TILE_PWR_FIREBALL: u8 = 133;
let TILE_STEEL_DMG: u8 = 136;

let PWR_FLAME: u32 = 1;
let PWR_BOMB: u32 = 2;
let PWR_SPEED: u32 = 4;
let PWR_GHOST: u32 = 8;
let PWR_KICK: u32 = 16;
let PWR_MISSILE: u32 = 32;
let PWR_NAPALM: u32 = 64;
let PWR_MINES: u32 = 128;
let PWR_DRUNK: u32 = 256;
let PWR_BAD: u32 = 512;
let PWR_UNKICK: u32 = 1024;
let PWR_BUILD: u32 = 2048;
let PWR_DIRBOMB: u32 = 4096;
let PWR_FLAMER: u32 = 8192;
let PWR_FIREBALL: u32 = 16384;
let PWR_CLASSIC: u32 = 31;
let PWR_ALL: u32 = 32767;

fn is_power(g: u8) -> bool { (g >= 3 && g <= 5) || (g >= 8 && g <= 15) || (g >= 130 && g <= 133) }
fn is_flame(g: u8) -> bool { g >= 16 && g < 96 }
fn is_fog(g: u8) -> bool { g >= 96 && g < 128 }
fn is_solid(g: u8) -> bool { g == 1 || g == 2 || g == 6 || g == 7 || g == TILE_GRATE || g == TILE_STEEL_DMG }
fn is_solid_bomb(g: u8) -> bool { g == 1 || g == 2 || g == 6 || g == 7 || g == TILE_STEEL_DMG }

fn pick_power(mask: u32, r: rng&) -> u8 {
    var opts: u8[..20] = [];
    if (mask & PWR_FLAME) != 0 { opts.push(3); }
    if (mask & PWR_BOMB) != 0 { opts.push(4); }
    if (mask & PWR_SPEED) != 0 { opts.push(5); }
    if (mask & PWR_GHOST) != 0 { opts.push(8); }
    if (mask & PWR_KICK) != 0 { opts.push(9); }
    if (mask & PWR_MISSILE) != 0 { opts.push(10); }
    if (mask & PWR_NAPALM) != 0 { opts.push(11); }
    if (mask & PWR_MINES) != 0 { opts.push(12); }
    if (mask & PWR_DRUNK) != 0 { opts.push(13); }
    if (mask & PWR_BAD) != 0 { opts.push(14); }
    if (mask & PWR_UNKICK) != 0 { opts.push(15); }
    if (mask & PWR_BUILD) != 0 { opts.push(TILE_PWR_BUILD); }
    if (mask & PWR_DIRBOMB) != 0 { opts.push(TILE_PWR_DIRBOMB); }
    if (mask & PWR_FLAMER) != 0 { opts.push(TILE_PWR_FLAMER); }
    if (mask & PWR_FIREBALL) != 0 { opts.push(TILE_PWR_FIREBALL); }
    if opts.len == 0 { return 0; }
    return opts[r.rand_int(opts.len)];
}

let ROBOTO: const u8[:] = embed_file("Roboto-Regular.ttf");
struct Player { x: i64, y: i64, life: Life, facing: Dir, portal_cd: u8, bombs: u8, range: u8, speed: u8, slow: u8, wins: u8, streak: u8, kills: u8, suicides: u8, sheep_deaths: u8, deaths: u8, bits: u16, held: u8, mine_held: u8, build_held: u8, fire_held: u8, placed: u8, ghost: u16, napalm: u16, drunk: u16, kick: u8, unkick: u8, mines: u8, missiles: u8, builds: u8, dir_bombs: u8, flamer: u8, fireballs: u8, kind: Character, name: u8[..12] }
// dir: None when still, otherwise slides; m: ticks since its last step; flags: bit 0 = unkickable, bit 1 = warped; fire_lvl: 1..15 flame linger; blast_dir: None for 4-way, else single-direction blast.
struct Bomb { x: u8, y: u8, t: u16, range: u8, owner: u8, dir: Dir, m: u8, flags: u8, fire_lvl: u8, blast_dir: Dir }
// Proximity mine: arms down to 0, then explodes when stepped on or blasted.
struct Mine { x: u8, y: u8, owner: u8, arm: u8 }
// Player-steered heat-seeker missile: while active, the owner stands still wearing a headset.
struct Missile { x: i32, y: i32, active: u8, dir: Dir, portal_cd: u8, t: u16 }
// Fireball projectile launched by Fireball Thrower (`F`).
struct Fireball { x: i32, y: i32, dir: Dir, owner: u8, portal_cd: u8, life: u8 }
// A sheep wanders at random and blocks the way like a movable block. dir: None when grazing; on_fire > 0: blazing & lethal!
struct Sheep { x: i64, y: i64, alive: u8, dir: Dir, t: u8, portal_cd: u8, on_fire: u16, facing_left: u8 }
// fences: 4 bits per tile (2 bits per right/bottom edge: 0 none, 1 damaged, 2 intact) packed into 98 bytes;
// flame_owner: 4 bits per tile packed into 98 bytes (0..3 player, 4 sheep, 15 none).
struct State { grid: u8[195], fences: u8[98], flame_owner: u8[98], players: Player[4], bombs: Bomb[..16], mines: Mine[..8], missiles: Missile[4], fireballs: Fireball[..8], sheep: Sheep[2], drops: u8, regrow: u8, map: Map, portals_on: u8, portals: u8[4], power_mask: u32, fuse_ticks: u16, fuse_rand: u8, fire_ticks: u8, fire_rand: u8, fire_range: u8, range_rand: u8, day_night_on: u8, day_phase: u16, detailed_tex: u8, match_mode: MatchMode, friendly_fire: u8, vip_slot: u8, round_timer: u16, round_num: u16, last_kill_victim: u8, last_kill_killer: u8, last_kill_cause: u8, over: i64, dance_who: u8, you: u8, ack: i64, tick: i64 }   // drops: percent of brick fires that leave a power-up

struct KillClip { round: i64, victim: u8, killer: u8, cause: u8, label: u8[..64], frames: State[..90] }

// UDP (udp.c): inputs and snapshots fly as datagrams when a client joins with `udp`; the WebSocket stays up for
// joining, leaving and a slow heartbeat. Each snapshot carries its tick, so stale or reordered ones are dropped.
extern fn udp_open(port: i64) -> i64;
extern fn udp_peer(host: const u8[:], port: i64) -> i64;
extern fn udp_send(fd: i64, b: const u8[:], peer: i64) -> i64;
extern fn udp_recv(fd: i64, b: u8[:], from: i64&) -> i64;
extern fn udp_local_ip(b: u8[:]) -> i64;

// Automatic router port forwarding (UPnP IGD + NAT-PMP) in upnp.c.
// Returns 0 = mapped with public IP, 1 = mapped but CGNAT/double-NAT detected, -1 = failed/unavailable.
extern fn upnp_map(port: i64, pub_ip: u8[:], pub_len: i64&, msg: u8[:], msg_len: i64&) -> i64;
extern fn upnp_unmap(port: i64) -> i64;

// Host: input, profile update, or disconnect from a connection (reply names it). Client: key bits or profile to send.
// seq numbers a client's input steps; the host echoes the latest one it has seen in State.ack.
enum Msg {
    Input { reply: http::MailAddress, bits: u16, seq: i64 },
    Profile { reply: http::MailAddress, kind: Character, name: u8[..12] },
    Leave { reply: http::MailAddress },
}
struct Pad { bits: u16, seq: i64 }
struct Profile { kind: Character, name: u8[..12] }
struct Lost { code: i64 }
struct UpnpReq { port: i64, enable: bool }
struct UpnpRes { code: i64, pub_ip: u8[..64], msg: u8[..128] }

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

fn mine_at(s: State&, tx: i64, ty: i64) -> i64 {
    for i in s.mines.len { if s.mines[i].x == tx && s.mines[i].y == ty { return i; } }
    return -1;
}

fn is_portal(s: State&, tx: i64, ty: i64) -> bool {
    if s.portals_on == 0 { return false; }
    return (tx == s.portals[0] && ty == s.portals[1]) || (tx == s.portals[2] && ty == s.portals[3]);
}

fn portal_dest(s: State&, tx: i64, ty: i64) -> int2 {
    if s.portals_on == 0 { return int2 { -1, -1 }; }
    if tx == s.portals[0] && ty == s.portals[1] { return int2 { s.portals[2] as i32, s.portals[3] as i32 }; }
    if tx == s.portals[2] && ty == s.portals[3] { return int2 { s.portals[0] as i32, s.portals[1] as i32 }; }
    return int2 { -1, -1 };
}

fn hits(ax: i64, ay: i64, bx: i64, by: i64) -> bool { return abs(ax - bx) < 2 * HB && abs(ay - by) < 2 * HB; }

fn team_of(slot: i64) -> i64 { slot % 2 }

fn fowner_get(s: State&, idx: i64) -> i64 {
    if idx < 0 || idx >= W * H { return 15; }
    let b = s.flame_owner[idx / 2];
    return if (idx & 1) == 0 { (b & 15) as i64 } else { ((b >> 4) & 15) as i64 };
}

fn fowner_set(s: State&, idx: i64, who: i64) {
    if idx < 0 || idx >= W * H { return; }
    let v = (who & 15) as u8;
    let bi = idx / 2;
    if (idx & 1) == 0 { s.flame_owner[bi] = (s.flame_owner[bi] & 240) | v; }
    else { s.flame_owner[bi] = (s.flame_owner[bi] & 15) | (v << 4); }
}

fn fence_state(s: State&, tx: i64, ty: i64, bit: i64) -> i64 {
    if tx < 0 || tx >= W || ty < 0 || ty >= H { return 0; }
    let idx = ty * W + tx;
    let sh = (idx & 1) * 4 + bit * 2;
    return ((s.fences[idx / 2] as i64) >> sh) & 3;
}

fn fence_set_state(s: State&, tx: i64, ty: i64, bit: i64, st: i64) {
    if tx < 0 || tx >= W || ty < 0 || ty >= H { return; }
    let idx = ty * W + tx;
    let sh = (idx & 1) * 4 + bit * 2;
    let bi = idx / 2;
    let mask = 255 ^ (3 << sh);
    s.fences[bi] = (((s.fences[bi] as i64) & mask) | ((st & 3) << sh)) as u8;
}

fn fence_get(s: State&, tx: i64, ty: i64, bit: i64) -> bool {
    return fence_state(s, tx, ty, bit) > 0;
}

fn fence_set(s: State&, tx: i64, ty: i64, bit: i64) {
    fence_set_state(s, tx, ty, bit, 2);
}

fn fence_hit(s: State&, tx: i64, ty: i64, bit: i64) -> bool {
    let st = fence_state(s, tx, ty, bit);
    if st == 0 { return false; }
    fence_set_state(s, tx, ty, bit, if st >= 2 { 1 } else { 0 });
    return true;
}

fn fence_between(s: State&, ax: i64, ay: i64, bx: i64, by: i64) -> bool {
    if bx == ax + 1 && by == ay { return fence_get(s, ax, ay, 0); }
    if bx == ax - 1 && by == ay { return fence_get(s, bx, ay, 0); }
    if by == ay + 1 && bx == ax { return fence_get(s, ax, ay, 1); }
    if by == ay - 1 && bx == ax { return fence_get(s, ax, by, 1); }
    return false;
}

fn fence_hit_between(s: State&, ax: i64, ay: i64, bx: i64, by: i64) -> bool {
    if bx == ax + 1 && by == ay { return fence_hit(s, ax, ay, 0); }
    if bx == ax - 1 && by == ay { return fence_hit(s, bx, ay, 0); }
    if by == ay + 1 && bx == ax { return fence_hit(s, ax, ay, 1); }
    if by == ay - 1 && bx == ax { return fence_hit(s, ax, by, 1); }
    return false;
}

// Does a box centered at x y hit a wall, block, boundary fence, or a bomb that the box (now at ox oy) is not already standing on?
fn tiles_blocked(s: State&, ox: i64, oy: i64, x: i64, y: i64) -> bool {
    let x0 = (x - HB) / TILE;
    let x1 = (x + HB - 1) / TILE;
    let y0 = (y - HB) / TILE;
    let y1 = (y + HB - 1) / TILE;
    for ty in y0..y1 + 1 {
        for tx in x0..x1 + 1 {
            let g = s.grid[ty * W + tx];
            if is_solid(g) { return true; }
            let on_it = tx >= (ox - HB) / TILE && tx <= (ox + HB - 1) / TILE &&
                        ty >= (oy - HB) / TILE && ty <= (oy + HB - 1) / TILE;
            if bomb_at(s, tx, ty) >= 0 && !on_it { return true; }
        }
    }
    if x1 > x0 {
        for ty in y0..y1 + 1 {
            if fence_get(s, x0, ty, 0) { return true; }
        }
    }
    if y1 > y0 {
        for tx in x0..x1 + 1 {
            if fence_get(s, tx, y0, 1) { return true; }
        }
    }
    return false;
}

// Player i, moving to x y, is stopped by tiles, holding players, wandering sheep, and dead black sheep.
fn blocked(s: State&, i: i64, x: i64, y: i64) -> bool {
    let p = s.players[i];
    for j in 4 {
        let q = s.players[j];
        guard j != i else { continue; }
        let holds = q.life == Life.Alive && (q.bits & HOLD) != 0;
        let bsheep = q.life == Life.BlackSheep;
        guard holds || bsheep else { continue; }
        if hits(x, y, q.x, q.y) && !hits(p.x, p.y, q.x, q.y) { return true; }
    }
    for k in 2 {
        let q = s.sheep[k];
        if q.alive != 0 && hits(x, y, q.x, q.y) && !hits(p.x, p.y, q.x, q.y) { return true; }
    }
    return tiles_blocked(s, p.x, p.y, x, y);
}

// Blocking check for a player-controlled black sheep: stopped by tiles, bombs, alive players, and other sheep.
fn dead_sheep_blocked(s: State&, i: i64, x: i64, y: i64) -> bool {
    let me = s.players[i];
    for j in 4 {
        let q = s.players[j];
        guard j != i else { continue; }
        if (q.life == Life.Alive || q.life == Life.BlackSheep) && hits(x, y, q.x, q.y) && !hits(me.x, me.y, q.x, q.y) { return true; }
    }
    for k in 2 {
        let q = s.sheep[k];
        if q.alive != 0 && hits(x, y, q.x, q.y) && !hits(me.x, me.y, q.x, q.y) { return true; }
    }
    return tiles_blocked(s, me.x, me.y, x, y);
}

fn sheep_blocked(s: State&, k: i64, x: i64, y: i64) -> bool {
    let me = s.sheep[k];
    for j in 4 {
        let q = s.players[j];
        // Flaming sheep charge straight into alive players instead of stopping!
        let stop_p = (me.on_fire == 0 && q.life == Life.Alive) || q.life == Life.BlackSheep;
        if stop_p && hits(x, y, q.x, q.y) && !hits(me.x, me.y, q.x, q.y) { return true; }
    }
    for j in 2 {
        let q = s.sheep[j];
        if j != k && q.alive != 0 && hits(x, y, q.x, q.y) && !hits(me.x, me.y, q.x, q.y) { return true; }
    }
    return tiles_blocked(s, me.x, me.y, x, y);
}

fn reset_round(s: State&, r: rng&) {
    for fi in 98 { s.fences[fi] = 0; }
    for fi in 98 { s.flame_owner[fi] = 255; }
    if s.map == Map.Sandbox {
        // Playtest Sandbox: open arena with all 15 power-ups, all block types, intact & damaged fences, portals, and sheep.
        for ty in H {
            for tx in W {
                let is_border = tx == 0 || tx == W - 1 || ty == 0 || ty == H - 1;
                let is_pillar = ((tx == 2 || tx == W - 3) && (ty == 2 || ty == H - 3)) || ((tx == 4 || tx == W - 5) && ty == 6);
                s.grid[ty * W + tx] = if is_border || is_pillar { 1 } else { 0 };
            }
        }
        // Top row (ty = 1): classic & utility power-ups
        s.grid[1 * W + 3] = 3;                 // Flame (Range+)
        s.grid[1 * W + 4] = 4;                 // Extra Bomb
        s.grid[1 * W + 5] = 5;                 // Speed Bolt
        s.grid[1 * W + 6] = 8;                 // Ghost (Invisible)
        s.grid[1 * W + 7] = 9;                 // Kick Boot
        s.grid[1 * W + 8] = 10;                // Heat-Seeker Missile
        s.grid[1 * W + 9] = 11;                // Napalm Fire Trail
        s.grid[1 * W + 10] = 12;               // Proximity Mines
        s.grid[1 * W + 11] = 15;               // Unkickable Bombs
        // Upper gallery (ty = 3): Builder Kit, Directional Bombs, Flamethrower, Fireball, plus Drunk & Curse off to the right
        s.grid[3 * W + 4] = TILE_PWR_BUILD;    // Builder Kit (Q=Block, Shift+Q=Fence)
        s.grid[3 * W + 5] = TILE_PWR_DIRBOMB;  // Directional Bombs
        s.grid[3 * W + 6] = TILE_PWR_FLAMER;   // Flamethrower (F)
        s.grid[3 * W + 7] = TILE_PWR_FIREBALL; // Fireball Thrower (F)
        s.grid[3 * W + 9] = 13;                // Drunk
        s.grid[3 * W + 10] = 14;               // Bad / Curse
        // Bottom row (ty = 11): extra copies of core & weapon power-ups for P3/P4 or quick refills
        s.grid[11 * W + 4] = 3;
        s.grid[11 * W + 5] = 4;
        s.grid[11 * W + 6] = 5;
        s.grid[11 * W + 7] = TILE_PWR_BUILD;
        s.grid[11 * W + 8] = TILE_PWR_FLAMER;
        s.grid[11 * W + 9] = TILE_PWR_FIREBALL;
        s.grid[11 * W + 10] = TILE_PWR_DIRBOMB;
        // Center showcase (ty = 5..9): Bricks, Grates, Steel Crates, Damaged Steel Crate, Gift Crates, Brush, and Fences
        s.grid[5 * W + 3] = 2;                 // Brick
        s.grid[5 * W + 5] = 2;                 // Brick
        s.grid[5 * W + 6] = TILE_GRATE;        // Semi-permeable Grate
        s.grid[5 * W + 8] = TILE_GRATE;        // Semi-permeable Grate
        s.grid[5 * W + 9] = 2;                 // Brick
        s.grid[5 * W + 11] = 2;                // Brick
        s.grid[7 * W + 3] = 6;                 // Reinforced Steel Crate (2 hits)
        s.grid[7 * W + 5] = 6;                 // Reinforced Steel Crate (2 hits)
        s.grid[7 * W + 7] = TILE_STEEL_DMG;    // Damaged Steel Crate (1 hit left)
        s.grid[7 * W + 9] = 7;                 // Gift Crate
        s.grid[7 * W + 11] = 7;                // Gift Crate
        s.grid[9 * W + 5] = TILE_BRUSH;        // Walkable burnable Forest/Brush
        s.grid[9 * W + 6] = TILE_BRUSH;
        s.grid[9 * W + 8] = TILE_BRUSH;
        s.grid[9 * W + 9] = TILE_BRUSH;
        // Intact fences (2 hits) + a pre-damaged fence (1 hit left) for instant testing
        fence_set(s, 5, 6, 0);                 // Intact vertical fence
        fence_set(s, 7, 5, 1);                 // Intact horizontal fence
        fence_set_state(s, 8, 6, 0, 1);        // Pre-damaged vertical fence
    } else {
        for ty in H {
            for tx in W {
                var g: u8 = 0;
                let cx = min(tx, W - 1 - tx);
                let cy = min(ty, H - 1 - ty);
                let is_border = cx == 0 || cy == 0;
                var is_pillar = tx % 2 == 0 && ty % 2 == 0;
                // Subtle symmetric map layout flavor per biome
                match s.map {
                    Island => { if tx >= 6 && tx <= 8 && ty >= 5 && ty <= 7 { is_pillar = false; } },
                    Desert => { if (tx == 4 || tx == 10) && (ty == 4 || ty == 8) { is_pillar = false; } },
                    Mountains => { if (tx == 4 || tx == 10) && ty == 6 { is_pillar = true; } },
                    Forest => {},
                    Sandbox => {},
                }
                let density = match s.map {
                    Forest => 8,
                    Desert => 6,
                    _ => 7,
                };
                if is_border || is_pillar { g = 1; }
                else if cx + cy > 3 && r.rand_int(10) < density {
                    let k = r.rand_int(100);
                    g = if k < 7 { 6 }
                        else if k < 14 { 7 }
                        else if k < 22 { TILE_GRATE }
                        else if k < (if s.map == Map.Forest { 38 } else { 28 }) { TILE_BRUSH }
                        else { 2 };
                }
                s.grid[ty * W + tx] = g;
            }
        }
        // Symmetric 2-hit boundary fences along a few central corridor edges (never trapping spawns).
        fence_set(s, 5, 3, 0);
        fence_set(s, W - 7, 3, 0);
        fence_set(s, 5, H - 4, 0);
        fence_set(s, W - 7, H - 4, 0);
    }
    for i in 4 {
        let p = s.players[i];
        s.missiles[i] = Missile { .. };
        if p.life == Life.Off { continue; }
        s.players[i].x = (if i % 2 == 0 { 1 } else { W - 2 }) * TILE + TILE / 2;
        s.players[i].y = (if i < 2 { 1 } else { H - 2 }) * TILE + TILE / 2;
        s.players[i].life = Life.Alive;
        s.players[i].facing = Dir.Down;
        s.players[i].portal_cd = 0;
        s.players[i].bombs = 1;
        s.players[i].range = max(1, s.fire_range as i64) as u8;
        s.players[i].speed = 0;
        s.players[i].slow = 0;
        s.players[i].placed = 0;
        s.players[i].held = 0;
        s.players[i].mine_held = 0;
        s.players[i].build_held = 0;
        s.players[i].fire_held = 0;
        s.players[i].ghost = 0;
        s.players[i].napalm = 0;
        s.players[i].drunk = 0;
        s.players[i].kick = 0;
        s.players[i].unkick = 0;
        s.players[i].mines = 0;
        s.players[i].missiles = 0;
        s.players[i].builds = 0;
        s.players[i].dir_bombs = 0;
        s.players[i].flamer = 0;
        s.players[i].fireballs = 0;
    }
    for k in 2 {
        let tx = if s.map == Map.Sandbox { (if k == 0 { 6 } else { 8 }) } else { (if k == 0 { 5 } else { W - 6 }) };
        s.grid[(H / 2) * W + tx] = 0;
        s.sheep[k] = Sheep { tx * TILE + TILE / 2, (H / 2) * TILE + TILE / 2, 1, Dir.None, 0, 0, 0, if k == 1 { 1 } else { 0 } };
    }
    // Linked portal pair on symmetric open interior tiles
    let pset = r.rand_int(3);
    let ax = if s.map == Map.Sandbox { 3 } else if pset == 2 { 5 } else { 3 };
    let ay = if s.map == Map.Sandbox { 9 } else if pset == 1 { H - 4 } else { 3 };
    let bx = W - 1 - ax;
    let by = if s.map == Map.Sandbox { 9 } else { H - 1 - ay };
    s.portals = [ax as u8, ay as u8, bx as u8, by as u8];
    if s.portals_on != 0 {
        s.grid[ay * W + ax] = 0;
        s.grid[by * W + bx] = 0;
    }
    s.bombs.resize(0);
    s.mines.resize(0);
    s.fireballs.resize(0);
    s.day_phase = 0;
    s.round_num += 1;
    s.last_kill_victim = 255;
    s.last_kill_killer = 255;
    s.last_kill_cause = CAUSE_NONE;
    s.over = 0;
    s.dance_who = 255;
    // Rotate VIP (Prey or Predator) across active players each round.
    var next_vip = (s.vip_slot as i64 + 1) % 4;
    for tries in 4 {
        let cand = (next_vip + tries) % 4;
        if s.players[cand].life != Life.Off { s.vip_slot = cand as u8; break; }
    }
    s.round_timer = if s.match_mode == MatchMode.Prey { 3600 } else { 0 };
    if s.match_mode == MatchMode.Prey {
        let vp = s.vip_slot as i64;
        if s.players[vp].life == Life.Alive { s.players[vp].speed = 1; }
    } else if s.match_mode == MatchMode.Predator {
        let vp = s.vip_slot as i64;
        if s.players[vp].life == Life.Alive {
            s.players[vp].speed = 2;
            s.players[vp].bombs = 2;
            s.players[vp].range = max(3, s.fire_range as i64) as u8;
        }
    }
}

fn flame(s: State&, i: i64, lvl: i64, owner: i64) {
    let g = s.grid[i];
    let lv = max(1, min(15, lvl)) as u8;
    s.grid[i] = if g == 6 { TILE_STEEL_DMG } else if g == 7 || (g >= 48 && g < 64) { 48 + lv } else if g == 2 || g == TILE_STEEL_DMG || (g >= 32 && g < 48) { 32 + lv } else { 16 + lv };
    fowner_set(s, i, owner);
}

fn explode_arm(s: State&, bx: i64, by: i64, dx: i64, dy: i64, rng: i64, fire_lvl: i64, owner: i64) {
    for k in 1..rng + 1 {
        let px = bx + dx * (k - 1);
        let py = by + dy * (k - 1);
        let tx = bx + dx * k;
        let ty = by + dy * k;
        if tx < 0 || tx >= W || ty < 0 || ty >= H { break; }
        // Fences take 2 hits: 1st hit damages them, 2nd hit destroys them.
        if fence_hit_between(s, px, py, tx, ty) { break; }
        let g = s.grid[ty * W + tx];
        if g == 1 { break; }
        if g == TILE_GRATE { continue; } // semi-permeable: flames pass straight through
        flame(s, ty * W + tx, fire_lvl, owner);
        if g == 2 || g == 6 || g == 7 || g == TILE_STEEL_DMG { break; }
        let o = bomb_at(s, tx, ty);
        if o >= 0 { s.bombs[o].t = 0; break; }
    }
}

// Explosion at tile bx by with arm length rng, flame linger level (1..15), and owner (0..3 player).
fn explode_at(s: State&, bx: i64, by: i64, rng: i64, fire_lvl: i64, owner: i64) {
    if bx <= 0 || bx >= W - 1 || by <= 0 || by >= H - 1 { return; }
    flame(s, by * W + bx, fire_lvl, owner);
    explode_arm(s, bx, by, 1, 0, rng, fire_lvl, owner);
    explode_arm(s, bx, by, -1, 0, rng, fire_lvl, owner);
    explode_arm(s, bx, by, 0, 1, rng, fire_lvl, owner);
    explode_arm(s, bx, by, 0, -1, rng, fire_lvl, owner);
}

fn explode(s: State&, b: Bomb) {
    let bx = b.x as i64;
    let by = b.y as i64;
    let ow = b.owner as i64;
    if b.blast_dir != Dir.None {
        if bx > 0 && bx < W - 1 && by > 0 && by < H - 1 {
            flame(s, by * W + bx, b.fire_lvl as i64, ow);
            explode_arm(s, bx, by, dir_dx(b.blast_dir), dir_dy(b.blast_dir), (b.range as i64) * 2 + 2, b.fire_lvl as i64, ow);
        }
    } else {
        explode_at(s, bx, by, b.range as i64, b.fire_lvl as i64, ow);
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

// Can a sliding bomb not enter tile nx ny from bx by? Semi-permeable grates let bombs pass; boundary fences stop them.
fn bomb_stopped(s: State&, bx: i64, by: i64, nx: i64, ny: i64) -> bool {
    if nx < 0 || nx >= W || ny < 0 || ny >= H { return true; }
    if fence_between(s, bx, by, nx, ny) { return true; }
    let g = s.grid[ny * W + nx];
    if is_solid_bomb(g) || is_flame(g) || bomb_at(s, nx, ny) >= 0 { return true; }
    let cx = nx * TILE + TILE / 2;
    let cy = ny * TILE + TILE / 2;
    for k in 2 {
        let q = s.sheep[k];
        if q.alive != 0 && abs(q.x - cx) < TILE / 2 + HB && abs(q.y - cy) < TILE / 2 + HB { return true; }
    }
    for j in 4 {
        let q = s.players[j];
        let holds = q.life == Life.Alive && (q.bits & HOLD) != 0;
        let bsheep = q.life == Life.BlackSheep;
        if (holds || bsheep) && abs(q.x - cx) < TILE / 2 + HB && abs(q.y - cy) < TILE / 2 + HB { return true; }
    }
    return false;
}

fn step_player(s: State&, i: i64) {
    let bits = s.players[i].bits;
    if s.players[i].ghost > 0 { s.players[i].ghost -= 1; }
    if s.players[i].napalm > 0 { s.players[i].napalm -= 1; }
    if s.players[i].drunk > 0 { s.players[i].drunk -= 1; }
    if s.players[i].portal_cd > 0 { s.players[i].portal_cd -= 1; }
    // While guiding a heat-seeker missile, the player stands stationary wearing a headset.
    if s.missiles[i].active != 0 {
        if (bits & UP) != 0 { s.missiles[i].dir = Dir.Up; }
        else if (bits & DOWN) != 0 { s.missiles[i].dir = Dir.Down; }
        else if (bits & LEFT) != 0 { s.missiles[i].dir = Dir.Left; }
        else if (bits & RIGHT) != 0 { s.missiles[i].dir = Dir.Right; }
        if (bits & BOMB) != 0 && s.players[i].held == 0 { s.missiles[i].t = 0; }
        s.players[i].held = if (bits & BOMB) != 0 { 1 } else { 0 };
        return;
    }
    let sp = max(2, 5 + (s.players[i].speed as i64) - (s.players[i].slow as i64) * 2);
    var dx = 0;
    var dy = 0;
    if (bits & UP) != 0 { dy = -sp; s.players[i].facing = Dir.Up; }
    else if (bits & DOWN) != 0 { dy = sp; s.players[i].facing = Dir.Down; }
    else if (bits & LEFT) != 0 { dx = -sp; s.players[i].facing = Dir.Left; }
    else if (bits & RIGHT) != 0 { dx = sp; s.players[i].facing = Dir.Right; }
    // Drunk power-up: deterministic random jitter you have to fight against!
    if s.players[i].drunk > 0 && (bits & HOLD) == 0 {
        let h = (((s.tick / 10) * 1103515245 + i * 2654435761) >> 4) & 7;
        let jx = if h == 0 || h == 4 { 3 } else if h == 1 || h == 5 { -3 } else { 0 };
        let jy = if h == 2 || h == 4 { 3 } else if h == 3 || h == 5 { -3 } else { 0 };
        dx += jx;
        dy += jy;
    }
    if (bits & HOLD) != 0 { dx = 0; dy = 0; }
    let x = s.players[i].x;
    let y = s.players[i].y;
    let otx = x / TILE;
    let oty = y / TILE;
    if s.players[i].kick != 0 && (dx != 0 || dy != 0) {          // running into a kickable bomb kicks it
        let b = bomb_ahead(s, i, x + dx, y + dy);
        if b >= 0 && s.bombs[b].dir == Dir.None && (s.bombs[b].flags & BOMB_UNKICK) == 0 {
            s.bombs[b].dir = if abs(dy) > abs(dx) { if dy < 0 { Dir.Up } else { Dir.Down } } else if dx < 0 { Dir.Left } else { Dir.Right };
            s.bombs[b].m = 0;
        }
    }
    if dx == 0 && dy == 0 {
    } else if !blocked(s, i, x + dx, y + dy) {
        s.players[i].x = x + dx;
        s.players[i].y = y + dy;
    } else if dx != 0 && !blocked(s, i, x + dx, y) {
        s.players[i].x = x + dx;
    } else if dy != 0 && !blocked(s, i, x, y + dy) {
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
    let tx0 = s.players[i].x / TILE;
    let ty0 = s.players[i].y / TILE;
    // Portal teleport for alive player
    if s.players[i].portal_cd == 0 {
        let dst = portal_dest(s, tx0, ty0);
        if dst.x >= 0 {
            s.players[i].x = dst.x * TILE + TILE / 2;
            s.players[i].y = dst.y * TILE + TILE / 2;
            s.players[i].portal_cd = 35;
        }
    }
    let tx = s.players[i].x / TILE;
    let ty = s.players[i].y / TILE;
    // Napalm: leave slowly-decaying fire on the tile you just walked out of.
    if s.players[i].napalm > 0 && (tx != otx || ty != oty) {
        let og = s.grid[oty * W + otx];
        if og == 0 || (og >= 64 && og < 96) || is_fog(og) {
            s.grid[oty * W + otx] = 95;
            fowner_set(s, oty * W + otx, i);
        }
    }
    let g = s.grid[ty * W + tx];
    if is_power(g) {
        if g == 3 { s.players[i].range += 1; }
        else if g == 4 { s.players[i].bombs += 1; }
        else if g == 5 {
            if s.players[i].slow > 0 { s.players[i].slow -= 1; }
            else if s.players[i].speed < 3 { s.players[i].speed += 1; }
        }
        else if g == 8 { s.players[i].ghost = GHOST; }
        else if g == 9 { s.players[i].kick = 1; }
        else if g == 10 { s.players[i].missiles += 1; }
        else if g == 11 { s.players[i].napalm = NAPALM; }
        else if g == 12 { s.players[i].mines += 2; }
        else if g == 13 {          // Drunk: jitter to fight, plus EVERY other positive power!
            s.players[i].drunk = DRUNK;
            s.players[i].range = max(s.players[i].range + 2, 4);
            s.players[i].bombs = max(s.players[i].bombs + 2, 3);
            s.players[i].speed = 3;
            s.players[i].slow = 0;
            s.players[i].kick = 1;
            s.players[i].unkick = 1;
            s.players[i].napalm = NAPALM;
            s.players[i].mines += 2;
            s.players[i].missiles += 1;
            s.players[i].builds += 2;
            s.players[i].dir_bombs += 1;
            s.players[i].flamer += 2;
            s.players[i].fireballs += 1;
        }
        else if g == 14 {          // Bad/Curse: longer fire, but slows you down!
            s.players[i].range += 2;
            if s.players[i].slow < 3 { s.players[i].slow += 1; }
        }
        else if g == 15 { s.players[i].unkick = 1; }
        else if g == TILE_PWR_BUILD { s.players[i].builds += 3; }
        else if g == TILE_PWR_DIRBOMB { s.players[i].dir_bombs += 3; }
        else if g == TILE_PWR_FLAMER { s.players[i].flamer += 4; }
        else if g == TILE_PWR_FIREBALL { s.players[i].fireballs += 3; }
        s.grid[ty * W + tx] = 0;
    }
    let p = s.players[i];
    // F fires active weapon: Fireball Thrower (fast projectile) or Flamethrower (3-tile flame jet ahead).
    let want_fire = (bits & FIRE_KEY) != 0;
    if want_fire && p.fire_held == 0 {
        let fdir = if p.facing == Dir.None { Dir.Down } else { p.facing };
        if p.fireballs > 0 && s.fireballs.len < 8 {
            let sx = s.players[i].x + dir_dx(fdir) * (TILE / 2);
            let sy = s.players[i].y + dir_dy(fdir) * (TILE / 2);
            s.fireballs.push(Fireball { sx as i32, sy as i32, fdir, i as u8, 0, 120 });
            s.players[i].fireballs -= 1;
        } else if p.flamer > 0 {
            explode_arm(s, tx, ty, dir_dx(fdir), dir_dy(fdir), 3, 10, i);
            s.players[i].flamer -= 1;
        }
    }
    s.players[i].fire_held = if want_fire { 1 } else { 0 };
    // Q places a 2-hit reinforced block ahead; Shift+Q places a 2-hit chain-link fence ahead (1st hit damages, 2nd destroys).
    let want_build = (bits & BUILD_KEY) != 0;
    if want_build && p.build_held == 0 && p.builds > 0 {
        let fdir = if p.facing == Dir.None { Dir.Down } else { p.facing };
        let btx = tx + dir_dx(fdir);
        let bty = ty + dir_dy(fdir);
        if (bits & HOLD) != 0 {
            if btx > 0 && btx < W - 1 && bty > 0 && bty < H - 1 && !fence_between(s, tx, ty, btx, bty) {
                if btx == tx + 1 { fence_set(s, tx, ty, 0); }
                else if btx == tx - 1 { fence_set(s, btx, ty, 0); }
                else if bty == ty + 1 { fence_set(s, tx, ty, 1); }
                else if bty == ty - 1 { fence_set(s, tx, bty, 1); }
                s.players[i].builds -= 1;
            }
        } else if btx > 0 && btx < W - 1 && bty > 0 && bty < H - 1 {
            let tg = s.grid[bty * W + btx];
            var occ = (tg != 0 && !is_fog(tg)) || is_portal(s, btx, bty) || bomb_at(s, btx, bty) >= 0 || mine_at(s, btx, bty) >= 0;
            for j in 4 {
                if (s.players[j].life == Life.Alive || s.players[j].life == Life.BlackSheep) && s.players[j].x / TILE == btx && s.players[j].y / TILE == bty { occ = true; }
            }
            for k in 2 {
                if s.sheep[k].alive != 0 && s.sheep[k].x / TILE == btx && s.sheep[k].y / TILE == bty { occ = true; }
            }
            if !occ {
                s.grid[bty * W + btx] = 6;
                s.players[i].builds -= 1;
            }
        }
    }
    s.players[i].build_held = if want_build { 1 } else { 0 };
    let want_mine = ((bits & MINE_KEY) != 0) || ((bits & HOLD) != 0 && (bits & BOMB) != 0);
    if want_mine && p.mine_held == 0 && p.mines > 0 && mine_at(s, tx, ty) < 0 && s.mines.len < 8 {
        s.mines.push(Mine { tx as u8, ty as u8, i as u8, 60 });
        s.players[i].mines -= 1;
    }
    s.players[i].mine_held = if want_mine { 1 } else { 0 };
    if (bits & BOMB) != 0 && p.held == 0 && !want_mine {
        if p.missiles > 0 && s.missiles[i].active == 0 {
            let mdir = if (bits & UP) != 0 { Dir.Up } else if (bits & DOWN) != 0 { Dir.Down } else if (bits & LEFT) != 0 { Dir.Left } else if (bits & RIGHT) != 0 { Dir.Right } else { Dir.Down };
            s.missiles[i] = Missile { s.players[i].x as i32, s.players[i].y as i32, 1, mdir, 0, 300 };
            s.players[i].missiles -= 1;
        } else if p.placed < p.bombs && bomb_at(s, tx, ty) < 0 {
            var bx = tx;
            var by = ty;
            var fl: u8 = if p.unkick != 0 { BOMB_UNKICK } else { 0 };
            let pdst = portal_dest(s, bx, by);
            if pdst.x >= 0 && bomb_at(s, pdst.x, pdst.y) < 0 {
                bx = pdst.x;
                by = pdst.y;
                fl |= BOMB_WARPED;
            }
            let h0 = ((s.tick * 1103515245 + i * 2654435761 + bx * 37 + by * 91) >> 4) & 65535;
            let h1 = ((h0 * 48271 + 12345) >> 3) & 65535;
            let h2 = ((h1 * 48271 + 54321) >> 3) & 65535;
            let base_fuse = max(30, if s.fuse_ticks > 0 { s.fuse_ticks as i64 } else { FUSE });
            let bt = if s.fuse_rand != 0 {
                let lo = max(20, base_fuse / 2);
                let hi = min(360, base_fuse * 3 / 2);
                lo + (h0 % max(1, hi - lo + 1))
            } else { base_fuse };
            let base_rng = max(1, p.range as i64);
            let br = if s.range_rand != 0 {
                let lo = max(1, base_rng / 2);
                let hi = min(12, base_rng * 2);
                lo + (h1 % max(1, hi - lo + 1))
            } else { base_rng };
            let flvl = if s.fire_rand != 0 { 4 + (h2 % 12) } else { 15 };
            var bdir = Dir.None;
            if p.dir_bombs > 0 {
                bdir = if p.facing == Dir.None { Dir.Down } else { p.facing };
                s.players[i].dir_bombs -= 1;
            }
            s.bombs.push(Bomb { bx as u8, by as u8, bt as u16, br as u8, i as u8, Dir.None, 0, fl, flvl as u8, bdir });
            s.players[i].placed += 1;
        }
    }
    s.players[i].held = if (bits & BOMB) != 0 { 1 } else { 0 };
}

// Post-death participation: control a blocking Black Sheep or a fast wall-phasing Fog Ghost.
fn step_dead(s: State&, i: i64) {
    let bits = s.players[i].bits;
    if s.players[i].portal_cd > 0 { s.players[i].portal_cd -= 1; }
    // Space toggles between Black Sheep and Fog Ghost (when not inside a solid block).
    if (bits & BOMB) != 0 && s.players[i].held == 0 {
        if s.players[i].life == Life.BlackSheep {
            s.players[i].life = Life.FogGhost;
        } else if s.players[i].life == Life.FogGhost {
            let tx = s.players[i].x / TILE;
            let ty = s.players[i].y / TILE;
            if tx > 0 && tx < W - 1 && ty > 0 && ty < H - 1 && !is_solid(s.grid[ty * W + tx]) && bomb_at(s, tx, ty) < 0 {
                s.players[i].x = tx * TILE + TILE / 2;
                s.players[i].y = ty * TILE + TILE / 2;
                s.players[i].life = Life.BlackSheep;
            }
        }
    }
    s.players[i].held = if (bits & BOMB) != 0 { 1 } else { 0 };
    let is_gh = s.players[i].life == Life.FogGhost;
    let sp = if is_gh { 7 } else { 4 };
    var dx = 0;
    var dy = 0;
    if (bits & UP) != 0 { dy = -sp; s.players[i].facing = Dir.Up; }
    else if (bits & DOWN) != 0 { dy = sp; s.players[i].facing = Dir.Down; }
    else if (bits & LEFT) != 0 { dx = -sp; s.players[i].facing = Dir.Left; }
    else if (bits & RIGHT) != 0 { dx = sp; s.players[i].facing = Dir.Right; }
    let x = s.players[i].x;
    let y = s.players[i].y;
    if is_gh {
        // Fast Fog Ghost phases through all interior blocks/walls/bombs and leaves thick fog behind!
        let nx = max(TILE + HB, min((W - 1) * TILE - HB, x + dx));
        let ny = max(TILE + HB, min((H - 1) * TILE - HB, y + dy));
        s.players[i].x = nx;
        s.players[i].y = ny;
        let tx = nx / TILE;
        let ty = ny / TILE;
        let g = s.grid[ty * W + tx];
        if g == 0 || is_fog(g) { s.grid[ty * W + tx] = 127; }
    } else {
        // Black Sheep moves around the arena and blocks alive players and kicked bombs.
        if dx == 0 && dy == 0 {
        } else if !dead_sheep_blocked(s, i, x + dx, y + dy) {
            s.players[i].x = x + dx;
            s.players[i].y = y + dy;
        } else if dx != 0 {
            let off = (y / TILE) * TILE + TILE / 2 - y;
            let st = max(-sp, min(sp, off));
            if abs(off) <= 24 && !dead_sheep_blocked(s, i, x, y + st) { s.players[i].y = y + st; }
        } else if dy != 0 {
            let off = (x / TILE) * TILE + TILE / 2 - x;
            let st = max(-sp, min(sp, off));
            if abs(off) <= 24 && !dead_sheep_blocked(s, i, x + st, y) { s.players[i].x = x + st; }
        }
        if s.players[i].portal_cd == 0 {
            let dst = portal_dest(s, s.players[i].x / TILE, s.players[i].y / TILE);
            if dst.x >= 0 {
                s.players[i].x = dst.x * TILE + TILE / 2;
                s.players[i].y = dst.y * TILE + TILE / 2;
                s.players[i].portal_cd = 35;
            }
        }
    }
}

// One 60 Hz step: move, burn, age flames, kill, and decide when a round ends.
fn tick(s: State&, r: rng&, n: i64) {
    let was_over = s.over > 0;
    if was_over {
        s.over -= 1;
        if s.over == 0 { reset_round(s, r); return; }
    }
    for i in 4 {
        match s.players[i].life {
            Alive => {
                if was_over { s.players[i].bits = s.players[i].bits & (15 as u16); }
                step_player(s, i);
            },
            BlackSheep => { step_dead(s, i); },
            FogGhost => { step_dead(s, i); },
            Off => {},
        }
    }
    if s.day_night_on != 0 {
        s.day_phase = ((s.day_phase as i64 + 1) % 2400) as u16;
    } else {
        s.day_phase = 0;
    }
    for k in 2 {
        guard s.sheep[k].alive != 0 else { continue; }
        if s.sheep[k].portal_cd > 0 { s.sheep[k].portal_cd -= 1; }
        let blazing = s.sheep[k].on_fire > 0;
        if blazing {
            s.sheep[k].on_fire -= 1;
            if s.sheep[k].on_fire == 0 { s.sheep[k].alive = 0; continue; }
        }
        if s.sheep[k].t == 0 || (blazing && s.sheep[k].dir == Dir.None) {
            s.sheep[k].dir = if blazing { dir_from_int(1 + r.rand_int(4)) } else { dir_from_int(r.rand_int(5)) };
            s.sheep[k].t = (if blazing { 15 + r.rand_int(30) } else { 40 + r.rand_int(80) }) as u8;
        } else { s.sheep[k].t -= 1; }
        let d = s.sheep[k].dir;
        if d == Dir.Left { s.sheep[k].facing_left = 1; }
        else if d == Dir.Right { s.sheep[k].facing_left = 0; }
        if d == Dir.None { continue; }
        let sp = if blazing { 4 } else { 2 };
        let dx = dir_dx(d) * sp;
        let dy = dir_dy(d) * sp;
        if sheep_blocked(s, k, s.sheep[k].x + dx, s.sheep[k].y + dy) { s.sheep[k].t = 0; }
        else {
            s.sheep[k].x += dx;
            s.sheep[k].y += dy;
            if s.sheep[k].portal_cd == 0 {
                let dst = portal_dest(s, s.sheep[k].x / TILE, s.sheep[k].y / TILE);
                if dst.x >= 0 {
                    s.sheep[k].x = dst.x * TILE + TILE / 2;
                    s.sheep[k].y = dst.y * TILE + TILE / 2;
                    s.sheep[k].portal_cd = 35;
                }
            }
        }
    }
    for i in s.bombs.len { s.bombs[i].t -= 1; }
    for i in s.bombs.len {
        guard s.bombs[i].dir != Dir.None else { continue; }
        s.bombs[i].m += 1;
        guard s.bombs[i].m >= SLIDE else { continue; }
        s.bombs[i].m = 0;
        let b = s.bombs[i];
        let nx = b.x as i64 + dir_dx(b.dir);
        let ny = b.y as i64 + dir_dy(b.dir);
        if bomb_stopped(s, b.x as i64, b.y as i64, nx, ny) { s.bombs[i].dir = Dir.None; }
        else {
            var fx = nx;
            var fy = ny;
            let dst = portal_dest(s, fx, fy);
            if dst.x >= 0 && (s.bombs[i].flags & BOMB_WARPED) == 0 && bomb_at(s, dst.x, dst.y) < 0 {
                fx = dst.x;
                fy = dst.y;
                s.bombs[i].flags |= BOMB_WARPED;
            } else if !is_portal(s, fx, fy) {
                s.bombs[i].flags &= (255 - BOMB_WARPED);
            }
            s.bombs[i].x = fx as u8;
            s.bombs[i].y = fy as u8;
        }
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
    // Step player-steered heat-seeker missiles.
    for i in 4 {
        guard s.missiles[i].active != 0 else { continue; }
        if s.players[i].life != Life.Alive {
            explode_at(s, s.missiles[i].x / TILE, s.missiles[i].y / TILE, max(3, s.players[i].range as i64), 15, i);
            s.missiles[i].active = 0;
            continue;
        }
        var boom = false;
        if s.missiles[i].t == 0 { boom = true; } else { s.missiles[i].t -= 1; }
        let sp = 7;
        let d = s.missiles[i].dir;
        let dx = dir_dx(d) * sp;
        let dy = dir_dy(d) * sp;
        var nx = s.missiles[i].x as i64 + dx;
        var ny = s.missiles[i].y as i64 + dy;
        // Gently align perpendicular axis toward tile center so steering into corridors feels smooth.
        if dx != 0 {
            let off = (ny / TILE) * TILE + TILE / 2 - ny;
            ny += max(-4, min(4, off));
        } else if dy != 0 {
            let off = (nx / TILE) * TILE + TILE / 2 - nx;
            nx += max(-4, min(4, off));
        }
        let ntx = nx / TILE;
        let nty = ny / TILE;
        if ntx <= 0 || ntx >= W - 1 || nty <= 0 || nty >= H - 1 || is_solid(s.grid[nty * W + ntx]) || bomb_at(s, ntx, nty) >= 0 {
            boom = true;
        } else {
            if s.missiles[i].portal_cd > 0 { s.missiles[i].portal_cd -= 1; }
            if s.missiles[i].portal_cd == 0 {
                let dst = portal_dest(s, ntx, nty);
                if dst.x >= 0 {
                    nx = dst.x * TILE + TILE / 2;
                    ny = dst.y * TILE + TILE / 2;
                    s.missiles[i].portal_cd = 16;
                }
            }
            s.missiles[i].x = nx as i32;
            s.missiles[i].y = ny as i32;
            for j in 4 {
                if j != i && s.players[j].life == Life.Alive && abs(s.players[j].x - nx) < HB + 12 && abs(s.players[j].y - ny) < HB + 12 { boom = true; }
            }
            for k in 2 {
                if s.sheep[k].alive != 0 && abs(s.sheep[k].x - nx) < HB + 12 && abs(s.sheep[k].y - ny) < HB + 12 { boom = true; }
            }
        }
        if boom {
            explode_at(s, s.missiles[i].x / TILE, s.missiles[i].y / TILE, max(3, s.players[i].range as i64), 15, i);
            s.missiles[i].active = 0;
        }
    }
    // Step Fireball Thrower projectiles: fast fiery orbs that warp through portals and pass semi-permeable grates.
    var fi = 0;
    while fi < s.fireballs.len {
        let fb = s.fireballs[fi];
        let otx = (fb.x as i64) / TILE;
        let oty = (fb.y as i64) / TILE;
        let sp = 10;
        var nx = (fb.x as i64) + dir_dx(fb.dir) * sp;
        var ny = (fb.y as i64) + dir_dy(fb.dir) * sp;
        let ntx = nx / TILE;
        let nty = ny / TILE;
        var hit = fb.life == 0 || ntx <= 0 || ntx >= W - 1 || nty <= 0 || nty >= H - 1;
        if !hit && (ntx != otx || nty != oty) && fence_between(s, otx, oty, ntx, nty) { hit = true; }
        if !hit {
            let g = s.grid[nty * W + ntx];
            if is_solid_bomb(g) || bomb_at(s, ntx, nty) >= 0 { hit = true; }
        }
        if !hit {
            if s.fireballs[fi].portal_cd > 0 { s.fireballs[fi].portal_cd -= 1; }
            if s.fireballs[fi].portal_cd == 0 {
                let dst = portal_dest(s, ntx, nty);
                if dst.x >= 0 {
                    nx = dst.x * TILE + TILE / 2;
                    ny = dst.y * TILE + TILE / 2;
                    s.fireballs[fi].portal_cd = 12;
                }
            }
            s.fireballs[fi].x = nx as i32;
            s.fireballs[fi].y = ny as i32;
            s.fireballs[fi].life -= 1;
            for j in 4 {
                if j != (fb.owner as i64) && s.players[j].life == Life.Alive && abs(s.players[j].x - nx) < HB + 10 && abs(s.players[j].y - ny) < HB + 10 { hit = true; }
            }
            for k in 2 {
                if s.sheep[k].alive != 0 && abs(s.sheep[k].x - nx) < HB + 10 && abs(s.sheep[k].y - ny) < HB + 10 { hit = true; }
            }
        }
        if hit {
            let ex = max(1, min(W - 2, (s.fireballs[fi].x as i64) / TILE));
            let ey = max(1, min(H - 2, (s.fireballs[fi].y as i64) / TILE));
            let fbo = s.fireballs[fi].owner as i64;
            remove_at(s.fireballs, fi);
            explode_at(s, ex, ey, 1, 12, fbo);
        } else {
            fi += 1;
        }
    }
    // Step proximity mines: arm down, then detonate if stepped on or hit by flame.
    var mi = 0;
    while mi < s.mines.len {
        let m = s.mines[mi];
        if m.arm > 0 {
            s.mines[mi].arm -= 1;
            mi += 1;
            continue;
        }
        var trig = is_flame(s.grid[(m.y as i64) * W + (m.x as i64)]);
        for j in 4 {
            if s.players[j].life == Life.Alive && s.players[j].x / TILE == m.x && s.players[j].y / TILE == m.y { trig = true; }
        }
        for k in 2 {
            if s.sheep[k].alive != 0 && s.sheep[k].x / TILE == m.x && s.sheep[k].y / TILE == m.y { trig = true; }
        }
        if trig {
            let mo = m.owner as i64;
            remove_at(s.mines, mi);
            explode_at(s, m.x as i64, m.y as i64, max(2, s.players[mo].range as i64), 15, mo);
        } else {
            mi += 1;
        }
    }
    let fdiv = max(1, (if s.fire_ticks > 0 { s.fire_ticks as i64 } else { 16 }) / 8);
    if n % fdiv == 0 {
        for i in W * H {
            let g = s.grid[i];
            if g < 16 || g >= 64 { continue; }
            if g % 16 > 0 { s.grid[i] = g - 1; }
            else if g >= 48 || (g >= 32 && r.rand_int(100) < s.drops as i64) {
                s.grid[i] = pick_power(s.power_mask, r);
            }
            else { s.grid[i] = 0; }
        }
    }
    // Napalm flames (64..95) decay 3x slower than normal flames.
    if n % 6 == 0 {
        for i in W * H {
            let g = s.grid[i];
            if g >= 64 && g < 96 {
                s.grid[i] = if g > 64 { g - 1 } else { 0 };
            }
        }
    }
    // Fog clouds (96..127) left by dead Fog Ghosts linger and slowly dissipate.
    if n % 10 == 0 {
        for i in W * H {
            let g = s.grid[i];
            if is_fog(g) {
                s.grid[i] = if g > 96 { g - 1 } else { 0 };
            }
        }
    }
    // Randomly spawn new blocks when the arena gets too empty, at a host-controllable rate.
    if s.regrow > 0 {
        let iv = max(18, 260 - (s.regrow as i64) * 24 / 10);
        if n > 0 && n % iv == 0 {
            var blocks = 0;
            for i in W * H {
                let g = s.grid[i];
                if g == 2 || g == 6 || g == 7 || g == TILE_STEEL_DMG { blocks += 1; }
            }
            if blocks < 34 {
                for tries in 24 {
                    let tx = 1 + r.rand_int(W - 2);
                    let ty = 1 + r.rand_int(H - 2);
                    let cur = s.grid[ty * W + tx];
                    if (cur != 0 && !is_fog(cur)) || is_portal(s, tx, ty) || bomb_at(s, tx, ty) >= 0 || mine_at(s, tx, ty) >= 0 { continue; }
                    var clear = true;
                    for i in 4 {
                        guard s.players[i].life == Life.Alive || s.players[i].life == Life.BlackSheep else { continue; }
                        if abs(s.players[i].x / TILE - tx) <= 1 && abs(s.players[i].y / TILE - ty) <= 1 { clear = false; }
                    }
                    for k in 2 {
                        if s.sheep[k].alive != 0 && abs(s.sheep[k].x / TILE - tx) <= 1 && abs(s.sheep[k].y / TILE - ty) <= 1 { clear = false; }
                    }
                    if clear {
                        let roll = r.rand_int(100);
                        s.grid[ty * W + tx] = if roll < 6 { 6 } else if roll < 12 { 7 } else { 2 };
                        break;
                    }
                }
            }
        }
    }
    for k in 2 {
        if s.sheep[k].alive != 0 && is_flame(s.grid[(s.sheep[k].y / TILE) * W + s.sheep[k].x / TILE]) {
            if s.sheep[k].on_fire == 0 { s.sheep[k].on_fire = 360; s.sheep[k].t = 0; }
        }
    }
    if was_over { return; }
    if s.match_mode == MatchMode.Prey && s.round_timer > 0 {
        s.round_timer -= 1;
    }
    var joined = 0;
    var alive = 0;
    var last = 0;
    for i in 4 {
        guard s.players[i].life != Life.Off else { continue; }
        joined += 1;
        if s.players[i].life == Life.Alive {
            let ti = (s.players[i].y / TILE) * W + s.players[i].x / TILE;
            var burned = is_flame(s.grid[ti]);
            let fo = fowner_get(s, ti);
            if burned && s.match_mode == MatchMode.Teams2v2 && s.friendly_fire == 0 {
                if fo < 4 && fo != i && team_of(fo) == team_of(i) { burned = false; }
            }
            var by_sheep = false;
            for k in 2 {
                if s.sheep[k].alive != 0 && s.sheep[k].on_fire > 0 && hits(s.players[i].x, s.players[i].y, s.sheep[k].x, s.sheep[k].y) {
                    burned = true;
                    by_sheep = true;
                }
            }
            if burned {
                s.players[i].life = Life.BlackSheep;
                s.players[i].held = 1;
                s.players[i].deaths += 1;
                s.last_kill_victim = i as u8;
                if by_sheep {
                    s.players[i].sheep_deaths += 1;
                    s.last_kill_killer = 255;
                    s.last_kill_cause = CAUSE_SHEEP;
                } else if fo == i {
                    s.players[i].suicides += 1;
                    s.last_kill_killer = i as u8;
                    s.last_kill_cause = CAUSE_SUICIDE;
                } else if fo < 4 {
                    s.players[fo].kills += 1;
                    s.last_kill_killer = fo as u8;
                    s.last_kill_cause = CAUSE_BOMB;
                } else {
                    s.last_kill_killer = 255;
                    s.last_kill_cause = CAUSE_BOMB;
                }
            }
            else { alive += 1; last = i; }
        }
    }
    var round_done = false;
    var win_mask = 0;
    match s.match_mode {
        FreeForAll => {
            if (joined > 1 && alive <= 1) || (joined == 1 && alive == 0) {
                round_done = true;
                if joined > 1 && alive == 1 { win_mask = 1 << last; }
            }
        },
        Teams2v2 => {
            var t0_on = 0; var t1_on = 0;
            var t0_al = 0; var t1_al = 0;
            for i in 4 {
                if s.players[i].life == Life.Off { continue; }
                if team_of(i) == 0 { t0_on += 1; if s.players[i].life == Life.Alive { t0_al += 1; } }
                else { t1_on += 1; if s.players[i].life == Life.Alive { t1_al += 1; } }
            }
            if t0_on > 0 && t1_on > 0 {
                if t0_al == 0 || t1_al == 0 {
                    round_done = true;
                    if t0_al > 0 { for i in 4 { if s.players[i].life != Life.Off && team_of(i) == 0 { win_mask |= 1 << i; } } }
                    else if t1_al > 0 { for i in 4 { if s.players[i].life != Life.Off && team_of(i) == 1 { win_mask |= 1 << i; } } }
                }
            } else if (joined > 1 && alive <= 1) || (joined == 1 && alive == 0) {
                round_done = true;
                if joined > 1 && alive == 1 { win_mask = 1 << last; }
            }
        },
        Prey => {
            let vp = s.vip_slot as i64;
            let prey_alive = s.players[vp].life == Life.Alive;
            var hunt_on = 0; var hunt_al = 0;
            for i in 4 {
                if i != vp && s.players[i].life != Life.Off {
                    hunt_on += 1;
                    if s.players[i].life == Life.Alive { hunt_al += 1; }
                }
            }
            if hunt_on > 0 {
                if !prey_alive {
                    round_done = true;
                    for i in 4 { if i != vp && s.players[i].life != Life.Off { win_mask |= 1 << i; } }
                } else if s.round_timer == 0 || hunt_al == 0 {
                    round_done = true;
                    win_mask = 1 << vp;
                }
            } else if alive == 0 {
                round_done = true;
            }
        },
        Predator => {
            let vp = s.vip_slot as i64;
            let pred_alive = s.players[vp].life == Life.Alive;
            var run_on = 0; var run_al = 0;
            for i in 4 {
                if i != vp && s.players[i].life != Life.Off {
                    run_on += 1;
                    if s.players[i].life == Life.Alive { run_al += 1; }
                }
            }
            if run_on > 0 {
                if !pred_alive {
                    round_done = true;
                    for i in 4 { if i != vp && s.players[i].life != Life.Off { win_mask |= 1 << i; } }
                } else if run_al == 0 {
                    round_done = true;
                    win_mask = 1 << vp;
                }
            } else if alive == 0 {
                round_done = true;
            }
        },
    }
    if round_done {
        s.over = 450;
        s.dance_who = 255;
        if win_mask != 0 {
            for i in 4 {
                if (win_mask & (1 << i)) != 0 {
                    s.players[i].wins += 1;
                    s.players[i].streak += 1;
                    if s.players[i].wins % 5 == 0 && s.dance_who == 255 {
                        s.over = 540;
                        s.dance_who = i as u8;
                    }
                } else {
                    s.players[i].streak = 0;
                }
            }
        } else {
            for i in 4 { s.players[i].streak = 0; }
        }
    }
}

// ---- network ----------------------------------------------------------------------------------

struct Conn { ws: http::WebSocket = http::WebSocket { limit: 8192, .. }, reply: http::MailAddress }

fn post_msg(m: Msg) { qput(m); }

fn serve_event(ev: http::Event, st: Conn&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        http::ws_upgrade(ev.req, st.ws, out);
    } else if ev.kind == http::WAKE {
        http::ws_send(out, http::WS_BINARY, ev.data);       // a snapshot mailed by the game
        http::later(out, 5000);
    } else if ev.kind == http::TIMEOUT {
        http::later(out, 5000);
    } else {
        if ev.kind == http::CLOSED && st.reply.key != 0 { post_msg(Msg.Leave { reply: st.reply }); }
        http::ws_read(ev, st.ws, out) { op, data, o =>
            if st.reply.key == 0 { st.reply = http::later(o, 5000); }
            if data.len >= 3 && data[0] == 255 {
                let kd = char_from_u8(data[1]);
                var nm: u8[..12] = [];
                let ln = min(data[2] as i64, min(12, data.len - 3));
                for k in ln { nm.push(data[3 + k]); }
                post_msg(Msg.Profile { reply: st.reply, kind: kd, name: nm });
            } else if data.len >= 5 && data[0] == 254 {
                let b16 = ((data[1] as u16) | ((data[2] as u16) << 8));
                post_msg(Msg.Input { reply: st.reply, bits: b16, seq: (data[3] as i64) | ((data[4] as i64) << 8) });
            } else if data.len >= 3 {
                post_msg(Msg.Input { reply: st.reply, bits: data[0] as u16, seq: (data[1] as i64) | ((data[2] as i64) << 8) });
            }
        };
    }
}

thread_fn server(cfg: http::Config) {
    http::report(http::serve(cfg, Conn { .. }) { ev, st, out => serve_event(ev, st, out); });
}

thread_fn upnp_worker(req: UpnpReq) {
    var res = UpnpRes { code: -1, .. };
    if !req.enable {
        upnp_unmap(req.port);
        res.code = 2;
        let m = "Port mapping removed (LAN only)";
        for k in m.len { res.msg.push(m[k]); }
        qput(res);
        return;
    }
    var ipbuf: u8[>..] = [];
    ipbuf.resize(64, 0);
    var msgbuf: u8[>..] = [];
    msgbuf.resize(128, 0);
    var iplen = 0;
    var msglen = 0;
    res.code = upnp_map(req.port, ipbuf[..], iplen, msgbuf[..], msglen);
    for k in min(64, iplen) { res.pub_ip.push(ipbuf[k]); }
    for k in min(128, msglen) { res.msg.push(msgbuf[k]); }
    qput(res);
}

// Joins ws://url: sends the key bits and profile updates main queues, and queues each snapshot back to main.
thread_fn client(url: u8[..128]) {
    var session = http::session();
    var conn, err = http::ws_client_connect(session, url[..]);
    guard err.code == 0 else { write_stderr(str("connect: ", err.call, " ", err.code, "\n")); qput(Lost { 1 }); return; }
    var bits: u16 = 0;
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
            pkt.push(char_to_u8(prof.kind));
            pkt.push(prof.name.len as u8);
            for k in prof.name.len { pkt.push(prof.name[k]); }
            guard http::ws_client_binary(conn, pkt).code == 0 else { break; }
        }
        var one: u8[>..] = [];
        one.push(254);
        one.push((bits & 255) as u8);
        one.push((bits >> 8) as u8);
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

struct Sfx { place: audio::Sound, boom: audio::Sound, pickup: audio::Sound, die: audio::Sound, win: audio::Sound, clank: audio::Sound, dance: audio::Sound, warp: audio::Sound }
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

// Soft nighttime cricket chirps & evening breeze for the Day/Night cycle.
fn make_night_sfx(r: rng&) -> audio::Sound {
    let n = 48000 * 3; // 3-second seamless loop
    var pcm: f32[>..] = [];
    pcm.resize(n, 0.0);
    var lp = 0.0;
    for i in n {
        lp += 0.015 * (r.rand_flt() * 2.0 - 1.0 - lp);
        var s = lp * 0.14;
        // Two rhythmic cricket chirps per 3s loop
        let p0 = i % 72000;
        if p0 < 14000 {
            let pulse = p0 % 3500;
            if pulse < 2200 {
                let env = sin(pulse * 3.14159 / 2200.0);
                s += sin(i * TAU * 4250.0 / 48000.0) * 0.14 * env;
            }
        }
        let p1 = (i + 31000) % 48000;
        if p1 < 9000 {
            let pulse = p1 % 3000;
            if pulse < 1800 {
                let env = sin(pulse * 3.14159 / 1800.0);
                s += sin(i * TAU * 4680.0 / 48000.0) * 0.09 * env;
            }
        }
        pcm[i] = max(-1.0, min(1.0, s)) as f32;
    }
    return audio::create_sound(pcm);
}

fn make_sfx(r: rng&) -> Sfx {
    Sfx { synth(r, 0.12, 220.0, 110.0, 0.1, 6.0), synth(r, 0.7, 90.0, 35.0, 0.85, 4.5), synth(r, 0.25, 500.0, 1100.0, 0.0, 5.0),
          synth(r, 0.6, 400.0, 60.0, 0.1, 3.0), synth(r, 0.7, 523.0, 1318.0, 0.0, 2.0), synth(r, 0.1, 1200.0, 800.0, 0.5, 12.0),
          make_dance_sfx(), synth(r, 0.28, 320.0, 1320.0, 0.12, 4.0) }
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
    let win_sfx_at = if s.dance_who < 4 { 512 } else { 422 };
    if prev.over > win_sfx_at && s.over <= win_sfx_at && s.over > 0 {
        if s.dance_who < 4 { audio::play(sfx.dance, 0.9, 0.0, 1.0, false); }
        else {
            var any_win = false;
            for i in 4 { if s.players[i].life == Life.Alive { any_win = true; } }
            if any_win { audio::play(sfx.win, 0.8, 0.0, 1.0, false); }
        }
    }
    // Skip only the reset_round transition (prev.over > 0 && s.over == 0); let fatal explosions & aftermath play!
    guard !(prev.over > 0 && s.over == 0) else { return; }
    let dt = s.tick - prev.tick;
    for i in s.bombs.len {
        let b = s.bombs[i];
        var existed = false;
        for j in prev.bombs.len {
            if prev.bombs[j].owner == b.owner && b.t + dt == prev.bombs[j].t { existed = true; }
        }
        if !existed { audio::play(sfx.place, 0.6, pan(b.x * TILE), 1.0, false); }
    }
    for i in prev.bombs.len {
        let b = prev.bombs[i];
        var still = false;
        for j in s.bombs.len {
            if s.bombs[j].owner == b.owner && s.bombs[j].t + dt == b.t { still = true; }
        }
        if dt > 0 && !still {
            audio::play(sfx.boom, 0.9, pan(b.x * TILE), 1.0, false);
            fx.shake = 9.0;
        }
    }
    for i in W * H {
        if prev.grid[i] == 6 && s.grid[i] == TILE_STEEL_DMG { audio::play(sfx.clank, 0.55, pan((i % W) * TILE), 1.05, false); }
        else if prev.grid[i] == 0 && (s.grid[i] == 2 || s.grid[i] == 6 || s.grid[i] == 7) { audio::play(sfx.clank, 0.3, pan((i % W) * TILE), 0.7, false); }
    }
    for ty in H {
        for tx in W {
            for bit in 2 {
                let a = fence_state(prev, tx, ty, bit);
                let b = fence_state(s, tx, ty, bit);
                if b < a { audio::play(sfx.clank, 0.6, pan(tx * TILE), if b == 1 { 1.25 } else { 0.75 }, false); }
                else if b > a { audio::play(sfx.clank, 0.35, pan(tx * TILE), 0.9, false); }
            }
        }
    }
    for k in 2 {
        if prev.sheep[k].alive != 0 && s.sheep[k].alive == 0 { audio::play(sfx.die, 0.6, pan(s.sheep[k].x), 1.6, false); }
        if prev.sheep[k].on_fire == 0 && s.sheep[k].on_fire > 0 { audio::play(sfx.die, 0.75, pan(s.sheep[k].x), 2.1, false); }
    }
    for i in prev.mines.len {
        if mine_at(s, prev.mines[i].x, prev.mines[i].y) < 0 {
            audio::play(sfx.boom, 0.9, pan(prev.mines[i].x * TILE), 1.1, false);
            fx.shake = 9.0;
        }
    }
    for i in 4 {
        if prev.missiles[i].active != 0 && s.missiles[i].active == 0 {
            audio::play(sfx.boom, 0.95, pan(prev.missiles[i].x), 0.85, false);
            fx.shake = 11.0;
        }
        if prev.missiles[i].active == 0 && s.missiles[i].active != 0 {
            audio::play(sfx.place, 0.7, pan(s.missiles[i].x), 1.6, false);
        }
    }
    if s.fireballs.len > prev.fireballs.len {
        let fb = s.fireballs[s.fireballs.len - 1];
        audio::play(sfx.place, 0.6, pan(fb.x as i64), 1.85, false);
    } else if s.fireballs.len < prev.fireballs.len {
        audio::play(sfx.boom, 0.65, pan(prev.fireballs[0].x as i64), 1.35, false);
        if fx.shake < 4.5 { fx.shake = 4.5; }
    }
    for i in 4 {
        let a = prev.players[i];
        let b = s.players[i];
        guard a.life != Life.Off && b.life != Life.Off else { continue; }
        let vol = if i == s.you { 0.8 } else { 0.4 };
        if a.life == Life.Alive && b.life != Life.Alive { audio::play(sfx.die, 0.8, pan(b.x), 1.0, false); }
        if abs(b.x - a.x) + abs(b.y - a.y) > TILE * 2 { audio::play(sfx.warp, vol, pan(b.x), 1.0, false); }
        let got_pwr = b.range + b.bombs + b.speed + b.mines + b.missiles + b.builds + b.dir_bombs + b.flamer + b.fireballs > a.range + a.bombs + a.speed + a.mines + a.missiles + a.builds + a.dir_bombs + a.flamer + a.fireballs ||
                      (a.ghost == 0 && b.ghost > 0) || (a.kick == 0 && b.kick > 0) || (a.unkick == 0 && b.unkick > 0) ||
                      (a.napalm == 0 && b.napalm > 0) || (a.drunk == 0 && b.drunk > 0);
        if got_pwr { audio::play(sfx.pickup, vol, pan(b.x), if b.slow > a.slow { 0.65 } else { 1.0 }, false); }
        if b.wins > a.wins && s.over == 0 { audio::play(sfx.win, 0.8, 0.0, 1.0, false); }
    }
}

// ---- drawing ----------------------------------------------------------------------------------

// Procedural 512x256 GPU tile atlas (8x4 grid of 64x64 tiles) for the "Detailed Textures" mode.
// Rows 0..3 = Island, Forest, Mountains, Desert: col 0 = floor, col 1 = wall, col 2 = brick, col 3 = brush;
// Row 3 cols 4..6 = shared steel crate, gift crate, semi-permeable grate.
fn set_px(buf: u8[:], w: i64, x: i64, y: i64, r: i64, g: i64, b: i64, a: i64) {
    let i = (y * w + x) * 4;
    buf[i + 0] = max(0, min(255, r)) as u8;
    buf[i + 1] = max(0, min(255, g)) as u8;
    buf[i + 2] = max(0, min(255, b)) as u8;
    buf[i + 3] = max(0, min(255, a)) as u8;
}

fn seg_dist(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) -> f32 {
    let vx = bx - ax;
    let vy = by - ay;
    let l2 = vx * vx + vy * vy;
    let t = if l2 > 0.0001 { max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / l2)) } else { 0.0 };
    let dx = px - (ax + t * vx);
    let dy = py - (ay + t * vy);
    return sqrt(dx * dx + dy * dy);
}

// Crisp 32x32 green checkbox fill with bold anti-aliased white checkmark for checked settings checkboxes.
fn make_check_tex() -> gfx::Texture {
    let sz = 32;
    var px: u8[>..] = [];
    px.resize(sz * sz * 4, 255);
    for y in sz {
        for x in sz {
            let fx = (x as f32) + 0.5;
            let fy = (y as f32) + 0.5;
            // Vibrant emerald background with subtle top sheen & clean inner border
            var r: f32 = 38.0;
            var g: f32 = 186.0 - fy * 1.1;
            var b: f32 = 96.0 - fy * 0.4;
            if x == 0 || y == 0 || x == sz - 1 || y == sz - 1 {
                r = 26.0; g = 145.0; b = 72.0;
            }
            // Bold two-segment checkmark: (6.5, 16.5) -> (13.0, 23.5) -> (25.5, 9.0)
            let d = min(seg_dist(fx, fy, 6.5, 16.5, 13.0, 23.5), seg_dist(fx, fy, 13.0, 23.5, 25.5, 9.0));
            // Subtle dark drop shadow right below the white tick for extra contrast
            let ds = min(seg_dist(fx, fy - 1.2, 6.5, 16.5, 13.0, 23.5), seg_dist(fx, fy - 1.2, 13.0, 23.5, 25.5, 9.0));
            if ds < 3.4 {
                let sa = max(0.0, min(1.0, (3.4 - ds) / 1.2)) * 0.35;
                r *= (1.0 - sa);
                g *= (1.0 - sa);
                b *= (1.0 - sa);
            }
            let cov = max(0.0, min(1.0, (3.1 - d) / 1.1));
            let fr = r * (1.0 - cov) + 255.0 * cov;
            let fg = g * (1.0 - cov) + 255.0 * cov;
            let fb = b * (1.0 - cov) + 255.0 * cov;
            set_px(px[..], sz, x, y, fr as i64, fg as i64, fb as i64, 255);
        }
    }
    let tex = gfx::texture2d(sz, sz);
    gfx::update_texture(tex, px[..]);
    return tex;
}

fn hash2(x: i64, y: i64, seed: i64) -> i64 {
    let h = (x * 374761393 + y * 668265263 + seed * 1442695041) & 2147483647;
    return ((h ^ (h >> 13)) * 1274126177 >> 16) & 255;
}

fn make_tile_atlas() -> gfx::Texture {
    let aw = 512;
    let ah = 256;
    var px: u8[>..] = [];
    px.resize(aw * ah * 4, 255);
    for row in 4 {
        // Biome palettes (floor, wall, brick, brush)
        let fr = if row == 0 { 222 } else if row == 1 { 62 } else if row == 2 { 106 } else { 228 };
        let fg = if row == 0 { 196 } else if row == 1 { 114 } else if row == 2 { 114 } else { 184 };
        let fb = if row == 0 { 134 } else if row == 1 { 56 } else if row == 2 { 132 } else { 114 };

        let wr = if row == 0 { 74 } else if row == 1 { 58 } else if row == 2 { 92 } else { 158 };
        let wg = if row == 0 { 94 } else if row == 1 { 72 } else if row == 2 { 102 } else { 118 };
        let wb = if row == 0 { 104 } else if row == 1 { 54 } else if row == 2 { 122 } else { 66 };

        let br = if row == 0 { 166 } else if row == 1 { 126 } else if row == 2 { 142 } else { 196 };
        let bg = if row == 0 { 106 } else if row == 1 { 82 } else if row == 2 { 154 } else { 134 };
        let bb = if row == 0 { 58 } else if row == 1 { 46 } else if row == 2 { 174 } else { 78 };

        let lr = if row == 0 { 44 } else if row == 1 { 40 } else if row == 2 { 48 } else { 116 };
        let lg = if row == 0 { 156 } else if row == 1 { 132 } else if row == 2 { 122 } else { 142 };
        let lb = if row == 0 { 68 } else if row == 1 { 54 } else if row == 2 { 84 } else { 54 };

        for ty in 64 {
            for tx in 64 {
                let n1 = hash2(tx, ty, row * 7 + 1) - 128;
                let n2 = hash2(tx / 2, ty / 2, row * 13 + 3) - 128;
                // Col 0: textured biome floor (sand ripples / grass blades / alpine stone / desert dunes)
                var r0 = fr + n1 / 12 + n2 / 14;
                var g0 = fg + n1 / 12 + n2 / 14;
                var b0 = fb + n1 / 14 + n2 / 16;
                if row == 0 || row == 3 {
                    let wave = sin((tx as f64) * 0.25 + (ty as f64) * 0.45) * 9.0;
                    r0 += wave as i64; g0 += (wave * 0.8) as i64; b0 += (wave * 0.5) as i64;
                } else if row == 1 {
                    if (tx * 7 + ty * 3) % 19 == 0 { g0 += 20; r0 -= 8; }
                } else {
                    if n2 > 75 { r0 += 22; g0 += 24; b0 += 28; } // snow flecks
                }
                if tx == 0 || ty == 0 { r0 -= 10; g0 -= 10; b0 -= 10; }
                set_px(px[..], aw, tx, row * 64 + ty, r0, g0, b0, 255);

                // Col 1: chiseled beveled wall block with subtle stone grain + mortar
                let edge = min(min(tx, 63 - tx), min(ty, 63 - ty));
                var bv = if tx < 5 || ty < 5 { 28 } else if tx > 58 || ty > 58 { -34 } else { 0 };
                if edge < 2 { bv = -45; }
                let crack = if ((tx + ty * 2) % 29 == 0 && n2 > 40) { -22 } else { 0 };
                set_px(px[..], aw, 64 + tx, row * 64 + ty, wr + bv + n1 / 10 + crack, wg + bv + n1 / 10 + crack, wb + bv + n1 / 10 + crack, 255);

                // Col 2: detailed masonry / timber brick
                let brow = ty / 16;
                let bx = (tx + (brow % 2) * 16) % 32;
                let by = ty % 16;
                let mortar = bx < 2 || by < 2;
                let grain = (hash2(tx, ty / 2, row * 19 + 5) - 128) / 9;
                if mortar {
                    set_px(px[..], aw, 128 + tx, row * 64 + ty, br - 62, bg - 54, bb - 42, 255);
                } else {
                    let bsh = if by < 4 { 18 } else if by > 13 { -20 } else { 0 };
                    set_px(px[..], aw, 128 + tx, row * 64 + ty, br + bsh + grain, bg + bsh + grain, bb + bsh + grain, 255);
                }

                // Col 3: leafy brush canopy (transparent edges)
                let dx = tx - 32;
                let dy = ty - 32;
                let d2 = dx * dx + dy * dy;
                let wob = (hash2(tx / 4, ty / 4, row * 23 + 9) - 128) * 3;
                if d2 + wob < 860 {
                    let shade = if d2 < 260 { 22 } else if d2 > 600 { -22 } else { 0 };
                    let leaf = (hash2(tx / 2, ty / 2, row * 29 + 11) - 128) / 6;
                    set_px(px[..], aw, 192 + tx, row * 64 + ty, lr + shade + leaf, lg + shade + leaf, lb + shade + leaf, 240);
                } else {
                    set_px(px[..], aw, 192 + tx, row * 64 + ty, 0, 0, 0, 0);
                }
            }
        }
    }
    // Shared special blocks in Row 3, cols 4..6: steel crate (col 4), gift crate (col 5), grate (col 6)
    for ty in 64 {
        for tx in 64 {
            let n = (hash2(tx, ty, 77) - 128) / 14;
            // Col 4: brushed steel crate with rivets & X-brace
            let border = tx < 6 || tx > 57 || ty < 6 || ty > 57;
            let diag = abs(tx - ty) < 4 || abs(tx - (63 - ty)) < 4;
            let rivet = (abs(tx - 10) < 3 || abs(tx - 53) < 3) && (abs(ty - 10) < 3 || abs(ty - 53) < 3);
            var sr = 58 + n; var sg = 78 + n; var sb = 104 + n;
            if border || diag { sr += 42; sg += 48; sb += 54; }
            if rivet { sr = 215; sg = 228; sb = 240; }
            set_px(px[..], aw, 256 + tx, 192 + ty, sr, sg, sb, 255);

            // Col 5: ornate gift box
            let rib = abs(tx - 32) < 5 || abs(ty - 32) < 5;
            if rib { set_px(px[..], aw, 320 + tx, 192 + ty, 255, 206 + n, 68, 255); }
            else { set_px(px[..], aw, 320 + tx, 192 + ty, 134 + n, 68 + n, 186 + n, 255); }

            // Col 6: semi-permeable metallic chain-link grate (transparent openings!)
            let frame = tx < 5 || tx > 58 || ty < 5 || ty > 58;
            let mesh = ((tx + ty) % 12 < 2) || ((tx - ty + 128) % 12 < 2);
            if frame { set_px(px[..], aw, 384 + tx, 192 + ty, 152 + n, 178 + n, 204 + n, 255); }
            else if mesh { set_px(px[..], aw, 384 + tx, 192 + ty, 184 + n, 212 + n, 236 + n, 220); }
            else { set_px(px[..], aw, 384 + tx, 192 + ty, 30, 44, 62, 65); }

            // Col 7: damaged/cracked reinforced steel crate (1 hit left before destruction!)
            let fx = (tx as f32) + 0.5;
            let fy = (ty as f32) + 0.5;
            let dcrack1 = min(seg_dist(fx, fy, 10.0, 12.0, 28.0, 30.0), seg_dist(fx, fy, 28.0, 30.0, 52.0, 46.0));
            let dcrack2 = min(seg_dist(fx, fy, 28.0, 30.0, 18.0, 52.0), seg_dist(fx, fy, 38.0, 14.0, 28.0, 30.0));
            let dcrack = min(dcrack1, dcrack2);
            var dr = 64 + n; var dg = 58 + n; var db = 66 + n;
            if border || diag { dr += 32; dg += 22; db += 20; }
            if rivet && (tx < 32 || ty > 32) { dr = 185; dg = 148; db = 112; }
            if dcrack < 2.2 {
                dr = 24; dg = 16; db = 14;
            } else if dcrack < 4.5 {
                dr = 215; dg = 104; db = 48;
            }
            set_px(px[..], aw, 448 + tx, 192 + ty, dr, dg, db, 255);
        }
    }
    let tex = gfx::texture2d(aw, ah);
    gfx::update_texture(tex, px[..]);
    return tex;
}

fn draw_atlas_tile(c: ui::Context, atlas: gfx::Texture, col: i64, row: i64, x: f32, y: f32, t: f32, alpha: i64) {
    let img = ui::subimage_id(atlas.id, 512, 256, ui::rect((col * 64) as f32, (row * 64) as f32, 64.0, 64.0));
    ui::draw_image(c, ui::rect(x, y, t, t), img, ui::rgba(255, 255, 255, alpha));
}

fn map_row(m: Map) -> i64 {
    match m {
        Island => { return 0; },
        Forest => { return 1; },
        Mountains => { return 2; },
        Desert => { return 3; },
        Sandbox => { return 2; },
    }
}

// Smooth darkness factor (0.0 = bright day, 1.0 = pitch night) from State.day_phase (0..2399).
fn night_darkness(s: State&) -> f32 {
    if s.day_night_on == 0 { return 0.0; }
    let p = s.day_phase as f32;
    if p < 900.0 { return 0.0; }
    if p < 1200.0 { return (p - 900.0) / 300.0; }
    if p < 2100.0 { return 1.0; }
    return max(0.0, 1.0 - (p - 2100.0) / 300.0);
}

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
    ui::draw_text(c, ui::rect(x, y, 2000.0, 200.0), str, ui::font(c), ui::Color { 0, 0, 0, 0 }, color);
}

fn map_clear_color(m: Map) -> float4 {
    match m {
        Island => { return float4 { 0.05, 0.34, 0.45, 1.0 }; },
        Forest => { return float4 { 0.07, 0.16, 0.09, 1.0 }; },
        Mountains => { return float4 { 0.10, 0.14, 0.22, 1.0 }; },
        Desert => { return float4 { 0.32, 0.17, 0.08, 1.0 }; },
        Sandbox => { return float4 { 0.09, 0.12, 0.18, 1.0 }; },
    }
}

fn map_border_color(m: Map) -> ui::Color {
    match m {
        Island => { return ui::rgb(26, 152, 180); },
        Forest => { return ui::rgb(30, 62, 34); },
        Mountains => { return ui::rgb(46, 56, 78); },
        Desert => { return ui::rgb(138, 84, 42); },
        Sandbox => { return ui::rgb(52, 74, 108); },
    }
}

fn draw_floor(c: ui::Context, m: Map, tx: i64, ty: i64, x: f32, y: f32, t: f32) {
    let odd = (tx + ty) % 2 == 0;
    match m {
        Island => {
            let base = if odd { ui::rgb(230, 206, 150) } else { ui::rgb(220, 196, 140) };
            ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
            if (tx * 7 + ty * 13) % 11 == 0 {
                ui::fill_circle(c, ui::rect(x + t * 0.35, y + t * 0.55, t * 0.12, t * 0.08), ui::rgb(248, 236, 208));
            }
        },
        Forest => {
            let base = if odd { ui::rgb(78, 134, 64) } else { ui::rgb(70, 124, 58) };
            ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
            if (tx * 5 + ty * 11) % 9 == 0 {
                ui::fill_circle(c, ui::rect(x + t * 0.25, y + t * 0.3, t * 0.1, t * 0.1), ui::rgb(245, 225, 110));
            }
        },
        Mountains => {
            let base = if odd { ui::rgb(134, 148, 170) } else { ui::rgb(144, 158, 180) };
            ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
            if (tx * 3 + ty * 17) % 10 == 0 {
                ui::fill_rect(c, ui::rect(x + t * 0.2, y + t * 0.6, t * 0.28, t * 0.08), 2.0, ui::rgba(235, 244, 255, 140));
            }
        },
        Desert => {
            let base = if odd { ui::rgb(222, 170, 102) } else { ui::rgb(212, 160, 92) };
            ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
            if (tx + ty * 3) % 7 == 0 {
                ui::stroke_line(c, x + t * 0.15, y + t * 0.5, x + t * 0.75, y + t * 0.45, 1.5, ui::rgba(178, 122, 62, 120));
            }
        },
        Sandbox => {
            let base = if odd { ui::rgb(52, 62, 78) } else { ui::rgb(46, 56, 70) };
            ui::fill_rect(c, ui::rect(x, y, t, t), 0.0, base);
            ui::stroke_rect(c, ui::rect(x, y, t, t), 0.0, 1.0, ui::rgba(110, 138, 175, 45));
        },
    }
}

fn draw_wall(c: ui::Context, m: Map, x: f32, y: f32, t: f32) {
    match m {
        Island => {
            // Tropical volcanic rock + lush palm fronds
            ui::fill_rect(c, ui::rect(x, y, t, t), 5.0, ui::rgb(104, 96, 86));
            ui::fill_rect(c, ui::rect(x + t * 0.08, y + t * 0.08, t * 0.84, t * 0.2), 3.0, ui::rgb(142, 134, 120));
            ui::fill_circle(c, ui::rect(x + t * 0.22, y + t * 0.16, t * 0.56, t * 0.52), ui::rgb(42, 148, 68));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.42, x + t * 0.06, y + t * 0.2, x + t * 0.26, y + t * 0.54, ui::rgb(58, 174, 82));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.42, x + t * 0.94, y + t * 0.2, x + t * 0.74, y + t * 0.54, ui::rgb(58, 174, 82));
            ui::fill_circle(c, ui::rect(x + t * 0.42, y + t * 0.42, t * 0.16, t * 0.16), ui::rgb(120, 74, 38));
        },
        Forest => {
            // Tall layered pine tree on mossy soil
            ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(42, 74, 38));
            ui::fill_rect(c, ui::rect(x + t * 0.4, y + t * 0.62, t * 0.2, t * 0.3), 2.0, ui::rgb(96, 62, 36));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.08, x + t * 0.9, y + t * 0.72, x + t * 0.1, y + t * 0.72, ui::rgb(28, 92, 46));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.06, x + t * 0.8, y + t * 0.5, x + t * 0.2, y + t * 0.5, ui::rgb(44, 124, 62));
        },
        Mountains => {
            // Jagged snow-capped alpine peak
            ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(68, 78, 98));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.08, x + t * 0.94, y + t * 0.92, x + t * 0.06, y + t * 0.92, ui::rgb(96, 108, 130));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.08, x + t * 0.7, y + t * 0.46, x + t * 0.3, y + t * 0.46, ui::rgb(242, 248, 255));
            ui::stroke_rect(c, ui::rect(x + 1.0, y + 1.0, t - 2.0, t - 2.0), 4.0, 1.5, ui::rgb(52, 60, 76));
        },
        Desert => {
            // Carved desert sandstone pillar
            ui::fill_rect(c, ui::rect(x, y, t, t), 3.0, ui::rgb(176, 126, 72));
            ui::fill_rect(c, ui::rect(x, y, t, t * 0.16), 3.0, ui::rgb(218, 172, 110));
            ui::fill_rect(c, ui::rect(x, y + t * 0.84, t, t * 0.16), 3.0, ui::rgb(126, 82, 42));
            ui::stroke_rect(c, ui::rect(x + t * 0.18, y + t * 0.22, t * 0.64, t * 0.56), 2.0, 2.0, ui::rgb(132, 86, 44));
            ui::fill_triangle(c, x + t * 0.5, y + t * 0.3, x + t * 0.7, y + t * 0.68, x + t * 0.3, y + t * 0.68, ui::rgb(198, 148, 88));
        },
        Sandbox => {
            // Clean workshop slate-metal pillar
            ui::fill_rect(c, ui::rect(x, y, t, t), 4.0, ui::rgb(94, 108, 128));
            ui::fill_rect(c, ui::rect(x + t * 0.1, y + t * 0.1, t * 0.8, t * 0.18), 2.0, ui::rgb(128, 144, 168));
            ui::stroke_rect(c, ui::rect(x + 1.0, y + 1.0, t - 2.0, t - 2.0), 4.0, 2.0, ui::rgb(58, 68, 84));
        },
    }
}

fn draw_brick(c: ui::Context, m: Map, x: f32, y: f32, t: f32) {
    match m {
        Island => {
            // Bamboo / driftwood crate
            ui::fill_rect(c, ui::rect(x, y, t, t), 5.0, ui::rgb(184, 146, 76));
            for k in 4 {
                let xx = x + t * (0.12 + 0.24 * k);
                ui::fill_rect(c, ui::rect(xx, y + t * 0.08, t * 0.16, t * 0.84), 3.0, ui::rgb(208, 174, 96));
            }
            ui::fill_rect(c, ui::rect(x + t * 0.06, y + t * 0.32, t * 0.88, t * 0.1), 2.0, ui::rgb(126, 92, 46));
            ui::fill_rect(c, ui::rect(x + t * 0.06, y + t * 0.62, t * 0.88, t * 0.1), 2.0, ui::rgb(126, 92, 46));
            ui::stroke_rect(c, ui::rect(x, y, t, t), 5.0, 2.0, ui::rgb(106, 78, 36));
        },
        Forest => {
            // Stacked wooden timber logs
            ui::fill_rect(c, ui::rect(x, y, t, t), 5.0, ui::rgb(114, 72, 42));
            for r in 3 {
                let yy = y + t * (0.06 + 0.31 * r);
                ui::fill_rect(c, ui::rect(x + t * 0.06, yy, t * 0.88, t * 0.25), t * 0.12, ui::rgb(148, 96, 56));
                ui::fill_circle(c, ui::rect(x + t * 0.72, yy + t * 0.03, t * 0.18, t * 0.18), ui::rgb(208, 166, 114));
            }
            ui::stroke_rect(c, ui::rect(x, y, t, t), 5.0, 2.0, ui::rgb(74, 46, 26));
        },
        Mountains => {
            // Frosted boulder / ice block
            ui::fill_rect(c, ui::rect(x, y, t, t), 6.0, ui::rgb(154, 198, 228));
            ui::fill_rect(c, ui::rect(x + t * 0.08, y + t * 0.08, t * 0.84, t * 0.22), 4.0, ui::rgb(218, 240, 255));
            ui::stroke_line(c, x + t * 0.2, y + t * 0.35, x + t * 0.55, y + t * 0.6, 2.0, ui::rgb(96, 140, 174));
            ui::stroke_line(c, x + t * 0.55, y + t * 0.6, x + t * 0.8, y + t * 0.45, 2.0, ui::rgb(96, 140, 174));
            ui::stroke_rect(c, ui::rect(x, y, t, t), 6.0, 2.0, ui::rgb(82, 118, 150));
        },
        _ => {
            // Classic terracotta bricks (Desert & Sandbox)
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
        },
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

fn draw_steel_dmg(c: ui::Context, x: f32, y: f32, t: f32) {
    let rim = ui::rgb(158, 124, 102);
    ui::fill_rect(c, ui::rect(x, y, t, t), 6.0, ui::rgb(64, 54, 58));
    ui::stroke_rect(c, ui::rect(x + 2.0, y + 2.0, t - 4.0, t - 4.0), 5.0, 3.0, rim);
    ui::stroke_line(c, x + t * 0.16, y + t * 0.18, x + t * 0.45, y + t * 0.48, 5.0, ui::rgb(225, 112, 52));
    ui::stroke_line(c, x + t * 0.45, y + t * 0.48, x + t * 0.82, y + t * 0.72, 5.0, ui::rgb(225, 112, 52));
    ui::stroke_line(c, x + t * 0.45, y + t * 0.48, x + t * 0.28, y + t * 0.82, 5.0, ui::rgb(225, 112, 52));
    ui::stroke_line(c, x + t * 0.16, y + t * 0.18, x + t * 0.45, y + t * 0.48, 2.5, ui::rgb(22, 16, 14));
    ui::stroke_line(c, x + t * 0.45, y + t * 0.48, x + t * 0.82, y + t * 0.72, 2.5, ui::rgb(22, 16, 14));
    ui::stroke_line(c, x + t * 0.45, y + t * 0.48, x + t * 0.28, y + t * 0.82, 2.5, ui::rgb(22, 16, 14));
    ui::stroke_line(c, x + t * 0.62, y + t * 0.2, x + t * 0.45, y + t * 0.48, 2.5, ui::rgb(22, 16, 14));
}

// Semi-permeable grate: blocks players & sheep, lets kicked bombs and flames pass straight through.
fn draw_grate(c: ui::Context, x: f32, y: f32, t: f32) {
    ui::fill_rect(c, ui::rect(x + 2.0, y + 2.0, t - 4.0, t - 4.0), 5.0, ui::rgba(50, 70, 92, 110));
    let bar = ui::rgb(168, 198, 224);
    ui::stroke_rect(c, ui::rect(x + 2.5, y + 2.5, t - 5.0, t - 5.0), 4.0, 3.0, bar);
    for k in 1..4 {
        let f = (k as f32) * 0.25;
        ui::stroke_line(c, x + t * f, y + 3.0, x + t * f, y + t - 3.0, 2.0, ui::rgba(195, 220, 240, 210));
        ui::stroke_line(c, x + 3.0, y + t * f, x + t - 3.0, y + t * f, 2.0, ui::rgba(195, 220, 240, 210));
    }
    // Corner bolts
    let bolt = ui::rgb(220, 235, 248);
    ui::fill_circle(c, ui::rect(x + 4.0, y + 4.0, 5.0, 5.0), bolt);
    ui::fill_circle(c, ui::rect(x + t - 9.0, y + 4.0, 5.0, 5.0), bolt);
    ui::fill_circle(c, ui::rect(x + 4.0, y + t - 9.0, 5.0, 5.0), bolt);
    ui::fill_circle(c, ui::rect(x + t - 9.0, y + t - 9.0, 5.0, 5.0), bolt);
}

// Walkable Forest/Brush canopy drawn OVER players so anyone inside is hidden from opponents (burns away).
fn draw_brush(c: ui::Context, map: Map, x: f32, y: f32, t: f32, tm: f32, viewer_inside: bool) {
    let a = if viewer_inside { 135 } else { 235 };
    let sway = sin(tm * 2.4 + x * 0.04 + y * 0.03) * t * 0.03;
    let dark = match map {
        Desert => ui::rgba(92, 118, 46, a),
        Island => ui::rgba(28, 128, 56, a),
        Forest => ui::rgba(26, 98, 42, a),
        _ => ui::rgba(36, 92, 64, a),
    };
    let mid = match map {
        Desert => ui::rgba(128, 152, 62, a),
        Island => ui::rgba(48, 168, 72, a),
        Forest => ui::rgba(46, 138, 58, a),
        _ => ui::rgba(52, 126, 86, a),
    };
    let hi = match map {
        Desert => ui::rgba(164, 186, 82, a),
        Island => ui::rgba(88, 206, 104, a),
        Forest => ui::rgba(82, 178, 86, a),
        _ => ui::rgba(82, 164, 114, a),
    };
    ui::fill_circle(c, ui::rect(x - t * 0.06 + sway, y + t * 0.06, t * 0.62, t * 0.62), dark);
    ui::fill_circle(c, ui::rect(x + t * 0.42 + sway, y + t * 0.08, t * 0.62, t * 0.62), dark);
    ui::fill_circle(c, ui::rect(x + t * 0.14 + sway, y + t * 0.36, t * 0.72, t * 0.64), dark);
    ui::fill_circle(c, ui::rect(x + t * 0.04 + sway, y - t * 0.04, t * 0.56, t * 0.56), mid);
    ui::fill_circle(c, ui::rect(x + t * 0.38 + sway, y + t * 0.02, t * 0.56, t * 0.56), mid);
    ui::fill_circle(c, ui::rect(x + t * 0.18 + sway, y + t * 0.24, t * 0.62, t * 0.56), mid);
    ui::fill_circle(c, ui::rect(x + t * 0.22 + sway, y + t * 0.06, t * 0.34, t * 0.3), hi);
    ui::fill_circle(c, ui::rect(x + t * 0.5 + sway, y + t * 0.26, t * 0.26, t * 0.24), hi);
}

// 2-hit chain-link boundary fences drawn on the edges between tiles (take up zero square space).
// State 2 = intact silver wire; state 1 = visibly damaged/scorched/bent wire (1 hit left before destruction).
fn draw_fences(c: ui::Context, s: State&, ox: f32, oy: f32, t: f32) {
    let wire = ui::rgb(212, 224, 238);
    let dark = ui::rgb(52, 62, 76);
    let post = ui::rgb(245, 210, 95);
    let dmg_wire = ui::rgb(225, 118, 56);
    let dmg_dark = ui::rgb(52, 24, 18);
    let dmg_post = ui::rgb(175, 92, 52);
    for ty in H {
        for tx in W {
            let st0 = fence_state(s, tx, ty, 0);
            if st0 > 0 {
                let x = ox + (tx + 1) * t;
                let y = oy + ty * t;
                if st0 >= 2 {
                    ui::stroke_line(c, x, y, x, y + t, 6.0, dark);
                    ui::stroke_line(c, x, y, x, y + t, 3.0, wire);
                    for k in 4 {
                        let yy = y + t * (0.12 + 0.25 * (k as f32));
                        ui::stroke_line(c, x - 3.5, yy - 3.5, x + 3.5, yy + 3.5, 1.5, wire);
                        ui::stroke_line(c, x + 3.5, yy - 3.5, x - 3.5, yy + 3.5, 1.5, wire);
                    }
                    ui::fill_circle(c, ui::rect(x - 4.0, y - 4.0, 8.0, 8.0), post);
                    ui::fill_circle(c, ui::rect(x - 4.0, y + t - 4.0, 8.0, 8.0), post);
                } else {
                    // Damaged vertical fence: scorched orange-rust wire split in the middle with bent jagged ends
                    ui::stroke_line(c, x, y, x - 2.0, y + t * 0.36, 6.0, dmg_dark);
                    ui::stroke_line(c, x, y, x - 2.0, y + t * 0.36, 3.0, dmg_wire);
                    ui::stroke_line(c, x + 2.0, y + t * 0.64, x, y + t, 6.0, dmg_dark);
                    ui::stroke_line(c, x + 2.0, y + t * 0.64, x, y + t, 3.0, dmg_wire);
                    ui::stroke_line(c, x - 5.0, y + t * 0.32, x + 3.0, y + t * 0.42, 2.0, dmg_wire);
                    ui::stroke_line(c, x - 3.0, y + t * 0.58, x + 5.0, y + t * 0.68, 2.0, dmg_wire);
                    ui::fill_circle(c, ui::rect(x - 3.5, y - 3.5, 7.0, 7.0), dmg_post);
                    ui::fill_circle(c, ui::rect(x - 3.5, y + t - 3.5, 7.0, 7.0), dmg_post);
                }
            }
            let st1 = fence_state(s, tx, ty, 1);
            if st1 > 0 {
                let x = ox + tx * t;
                let y = oy + (ty + 1) * t;
                if st1 >= 2 {
                    ui::stroke_line(c, x, y, x + t, y, 6.0, dark);
                    ui::stroke_line(c, x, y, x + t, y, 3.0, wire);
                    for k in 4 {
                        let xx = x + t * (0.12 + 0.25 * (k as f32));
                        ui::stroke_line(c, xx - 3.5, y - 3.5, xx + 3.5, y + 3.5, 1.5, wire);
                        ui::stroke_line(c, xx + 3.5, y - 3.5, xx - 3.5, y + 3.5, 1.5, wire);
                    }
                    ui::fill_circle(c, ui::rect(x - 4.0, y - 4.0, 8.0, 8.0), post);
                    ui::fill_circle(c, ui::rect(x + t - 4.0, y - 4.0, 8.0, 8.0), post);
                } else {
                    // Damaged horizontal fence: scorched orange-rust wire split in the middle with bent jagged ends
                    ui::stroke_line(c, x, y, x + t * 0.36, y - 2.0, 6.0, dmg_dark);
                    ui::stroke_line(c, x, y, x + t * 0.36, y - 2.0, 3.0, dmg_wire);
                    ui::stroke_line(c, x + t * 0.64, y + 2.0, x + t, y, 6.0, dmg_dark);
                    ui::stroke_line(c, x + t * 0.64, y + 2.0, x + t, y, 3.0, dmg_wire);
                    ui::stroke_line(c, x + t * 0.32, y - 5.0, x + t * 0.42, y + 3.0, 2.0, dmg_wire);
                    ui::stroke_line(c, x + t * 0.58, y - 3.0, x + t * 0.68, y + 5.0, 2.0, dmg_wire);
                    ui::fill_circle(c, ui::rect(x - 3.5, y - 3.5, 7.0, 7.0), dmg_post);
                    ui::fill_circle(c, ui::rect(x + t - 3.5, y - 3.5, 7.0, 7.0), dmg_post);
                }
            }
        }
    }
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
    let plate = if g == 3 { ui::rgb(200, 60, 40) }
                else if g == 4 { ui::rgb(70, 70, 84) }
                else if g == 8 { ui::rgb(120, 80, 190) }
                else if g == 9 { ui::rgb(205, 125, 40) }
                else if g == 10 { ui::rgb(210, 45, 75) }
                else if g == 11 { ui::rgb(220, 86, 20) }
                else if g == 12 { ui::rgb(64, 96, 68) }
                else if g == 13 { ui::rgb(185, 55, 165) }
                else if g == 14 { ui::rgb(96, 42, 112) }
                else if g == 15 { ui::rgb(52, 74, 98) }
                else if g == TILE_PWR_BUILD { ui::rgb(156, 94, 48) }
                else if g == TILE_PWR_DIRBOMB { ui::rgb(198, 148, 24) }
                else if g == TILE_PWR_FLAMER { ui::rgb(225, 68, 28) }
                else if g == TILE_PWR_FIREBALL { ui::rgb(235, 112, 18) }
                else { ui::rgb(30, 150, 205) };
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
    } else if g == 10 {  // heat-seeker missile
        ui::fill_triangle(c, x + t * 0.74, y + t * 0.26, x + t * 0.56, y + t * 0.58, x + t * 0.42, y + t * 0.44, ui::rgb(255, 255, 255));
        ui::fill_triangle(c, x + t * 0.74, y + t * 0.26, x + t * 0.65, y + t * 0.42, x + t * 0.58, y + t * 0.35, ui::rgb(255, 70, 50));
        ui::stroke_line(c, x + t * 0.3, y + t * 0.7, x + t * 0.46, y + t * 0.54, 4.0, ui::rgb(255, 215, 70));
        ui::stroke_circle(c, ui::rect(x + t * 0.22, y + t * 0.22, t * 0.56, t * 0.56), 1.5, ui::rgba(255, 255, 255, 160));
    } else if g == 11 {  // napalm (fire trail drops)
        for k in 3 {
            let xx = x + t * (0.28 + 0.22 * k);
            let yy = y + t * (0.64 - 0.08 * k);
            ui::fill_circle(c, ui::rect(xx - t * 0.1, yy - t * 0.1, t * 0.2, t * 0.2), ui::rgb(255, 195, 50));
            ui::fill_triangle(c, xx, yy - t * 0.24, xx + t * 0.1, yy, xx - t * 0.1, yy, ui::rgb(255, 240, 120));
        }
    } else if g == 12 {  // proximity mine
        ui::fill_circle(c, ui::rect(x + t * 0.26, y + t * 0.32, t * 0.48, t * 0.4), ui::rgb(35, 38, 42));
        ui::stroke_circle(c, ui::rect(x + t * 0.26, y + t * 0.32, t * 0.48, t * 0.4), 2.0, ui::rgb(180, 190, 195));
        ui::fill_circle(c, ui::rect(x + t * 0.42, y + t * 0.44, t * 0.16, t * 0.14), ui::rgb(255, 65, 55));
    } else if g == 13 {  // drunk (bubbly mug / potion + stars)
        ui::fill_rect(c, ui::rect(x + t * 0.32, y + t * 0.34, t * 0.32, t * 0.4), 4.0, ui::rgb(255, 200, 60));
        ui::fill_rect(c, ui::rect(x + t * 0.3, y + t * 0.26, t * 0.36, t * 0.12), 4.0, ui::rgb(255, 255, 255));
        ui::stroke_rect(c, ui::rect(x + t * 0.62, y + t * 0.42, t * 0.12, t * 0.2), 3.0, 2.5, ui::rgb(255, 255, 255));
        ui::fill_circle(c, ui::rect(x + t * 0.24, y + t * 0.22, t * 0.09, t * 0.09), ui::rgb(255, 160, 245));
        ui::fill_circle(c, ui::rect(x + t * 0.66, y + t * 0.2, t * 0.08, t * 0.08), ui::rgb(255, 240, 120));
    } else if g == 14 {  // bad / curse (skull + green-purple glow)
        ui::fill_circle(c, ui::rect(x + t * 0.3, y + t * 0.24, t * 0.4, t * 0.38), ui::rgb(190, 245, 145));
        ui::fill_rect(c, ui::rect(x + t * 0.38, y + t * 0.56, t * 0.24, t * 0.16), 2.0, ui::rgb(190, 245, 145));
        ui::fill_circle(c, ui::rect(x + t * 0.37, y + t * 0.37, t * 0.09, t * 0.1), ui::rgb(45, 18, 56));
        ui::fill_circle(c, ui::rect(x + t * 0.54, y + t * 0.37, t * 0.09, t * 0.1), ui::rgb(45, 18, 56));
    } else if g == 15 {  // unkickable bomb (iron anchor)
        ui::stroke_circle(c, ui::rect(x + t * 0.42, y + t * 0.22, t * 0.16, t * 0.16), 2.5, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.5, y + t * 0.38, x + t * 0.5, y + t * 0.74, 3.0, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.32, y + t * 0.46, x + t * 0.68, y + t * 0.46, 3.0, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.28, y + t * 0.64, x + t * 0.5, y + t * 0.76, 3.0, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.72, y + t * 0.64, x + t * 0.5, y + t * 0.76, 3.0, ui::rgb(225, 235, 245));
    } else if g == TILE_PWR_BUILD { // builder kit (brick + fence posts)
        ui::fill_rect(c, ui::rect(x + t * 0.24, y + t * 0.48, t * 0.52, t * 0.24), 2.0, ui::rgb(225, 122, 68));
        ui::stroke_rect(c, ui::rect(x + t * 0.24, y + t * 0.48, t * 0.52, t * 0.24), 2.0, 1.5, ui::rgb(255, 235, 200));
        ui::stroke_line(c, x + t * 0.34, y + t * 0.24, x + t * 0.34, y + t * 0.48, 3.0, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.66, y + t * 0.24, x + t * 0.66, y + t * 0.48, 3.0, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.34, y + t * 0.32, x + t * 0.66, y + t * 0.32, 2.0, ui::rgb(225, 235, 245));
        ui::stroke_line(c, x + t * 0.34, y + t * 0.41, x + t * 0.66, y + t * 0.41, 2.0, ui::rgb(225, 235, 245));
    } else if g == TILE_PWR_DIRBOMB { // directional bomb (big arrow)
        ui::fill_rect(c, ui::rect(x + t * 0.22, y + t * 0.42, t * 0.34, t * 0.16), 2.0, ui::rgb(255, 245, 140));
        ui::fill_triangle(c, x + t * 0.8, y + t * 0.5, x + t * 0.5, y + t * 0.24, x + t * 0.5, y + t * 0.76, ui::rgb(255, 245, 140));
    } else if g == TILE_PWR_FLAMER { // flamethrower nozzle + flame cone
        ui::fill_rect(c, ui::rect(x + t * 0.22, y + t * 0.44, t * 0.26, t * 0.14), 2.0, ui::rgb(210, 220, 230));
        ui::fill_triangle(c, x + t * 0.46, y + t * 0.51, x + t * 0.8, y + t * 0.26, x + t * 0.8, y + t * 0.76, ui::rgb(255, 210, 60));
        ui::fill_triangle(c, x + t * 0.5, y + t * 0.51, x + t * 0.76, y + t * 0.38, x + t * 0.76, y + t * 0.64, ui::rgb(255, 250, 200));
    } else if g == TILE_PWR_FIREBALL { // blazing fireball orb + comet tail
        ui::fill_triangle(c, x + t * 0.2, y + t * 0.62, x + t * 0.56, y + t * 0.32, x + t * 0.66, y + t * 0.68, ui::rgb(255, 130, 30));
        ui::fill_circle(c, ui::rect(x + t * 0.42, y + t * 0.28, t * 0.36, t * 0.36), ui::rgb(255, 225, 80));
        ui::fill_circle(c, ui::rect(x + t * 0.5, y + t * 0.36, t * 0.2, t * 0.2), ui::rgb(255, 255, 230));
    } else {             // bolt
        ui::fill_triangle(c, x + t * 0.56, y + t * 0.2, x + t * 0.34, y + t * 0.52, x + t * 0.52, y + t * 0.52, ui::rgb(255, 235, 90));
        ui::fill_triangle(c, x + t * 0.48, y + t * 0.46, x + t * 0.68, y + t * 0.46, x + t * 0.44, y + t * 0.8, ui::rgb(255, 235, 90));
    }
}

fn draw_flame(c: ui::Context, g: u8, x: f32, y: f32, t: f32, tm: f32) {
    if g >= 64 && g < 96 { // slowly-decaying napalm fire
        let life = ((g - 64) as f32 + 1.0) / 32.0;
        let fl = 0.05 * sin(tm * 24.0 + x * 0.3 + y * 0.2);
        let a = (110.0 + 135.0 * life) as i64;
        ui::fill_rect(c, ui::rect(x + t * 0.04, y + t * 0.04, t * 0.92, t * 0.92), t * 0.32, ui::rgba(205, 35, 15, a));
        ui::fill_rect(c, ui::rect(x + t * (0.16 - fl), y + t * (0.16 - fl), t * (0.68 + 2.0 * fl), t * (0.68 + 2.0 * fl)), t * 0.28, ui::rgba(255, 115, 20, a));
        ui::fill_circle(c, ui::rect(x + t * 0.32, y + t * 0.32, t * 0.36, t * 0.36), ui::rgba(255, 225, 90, a));
        return;
    }
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

// Fluffy side-profile sheep (facing left or right); catches fire and blazes with flames when on_fire > 0!
fn draw_sheep(c: ui::Context, q: Sheep, x: f32, y: f32, t: f32, tm: f32) {
    let k = t * 0.84;
    let fdir: f32 = if q.facing_left != 0 { -1.0 } else { 1.0 };
    let blazing = q.on_fire > 0;
    let spd: f32 = if blazing { 26.0 } else { 14.0 };
    let moving = q.dir != Dir.None || blazing;
    let bob = if moving { 0.04 * t * abs(sin(tm * spd)) } else { 0.0 };
    let stride = if moving { sin(tm * spd) * k * 0.1 } else { 0.0 };
    let wool = if blazing { ui::rgb(255, 206, 152) } else { ui::rgb(248, 246, 240) };
    let wool_sh = if blazing { ui::rgb(218, 122, 62) } else { ui::rgb(216, 214, 206) };
    let wool_hi = if blazing { ui::rgb(255, 238, 185) } else { ui::rgb(255, 255, 252) };
    // Ground shadow
    ui::fill_circle(c, ui::rect(x - k * 0.56, y + k * 0.28, k * 1.12, k * 0.3), ui::rgba(0, 0, 0, 105));
    // Four trotting legs (back pair darker, front pair lighter)
    let leg_dk = ui::rgb(42, 38, 44);
    let leg_lt = ui::rgb(64, 58, 66);
    ui::fill_rect(c, ui::rect(x - fdir * k * 0.28 - stride - k * 0.05, y + k * 0.16, k * 0.1, k * 0.3), 3.0, leg_dk);
    ui::fill_rect(c, ui::rect(x + fdir * k * 0.14 + stride - k * 0.05, y + k * 0.16, k * 0.1, k * 0.3), 3.0, leg_dk);
    ui::fill_rect(c, ui::rect(x - fdir * k * 0.18 + stride - k * 0.05, y + k * 0.18, k * 0.1, k * 0.3), 3.0, leg_lt);
    ui::fill_rect(c, ui::rect(x + fdir * k * 0.22 - stride - k * 0.05, y + k * 0.18, k * 0.1, k * 0.3), 3.0, leg_lt);
    // Fluffy tail puff at rear
    let tail_x = x - fdir * k * 0.44;
    let tail_y = y - k * 0.04 - bob;
    ui::fill_circle(c, ui::rect(tail_x - k * 0.14, tail_y - k * 0.12, k * 0.28, k * 0.24), wool_sh);
    ui::fill_circle(c, ui::rect(tail_x - k * 0.11, tail_y - k * 0.13, k * 0.22, k * 0.2), wool);
    // Scalloped fluffy wool cloud body (profile oval + layered wool puffs)
    ui::fill_circle(c, ui::rect(x - k * 0.46, y - k * 0.34 - bob, k * 0.88, k * 0.64), wool_sh);
    ui::fill_circle(c, ui::rect(x - k * 0.44, y - k * 0.36 - bob, k * 0.42, k * 0.38), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.2, y - k * 0.46 - bob, k * 0.44, k * 0.42), wool);
    ui::fill_circle(c, ui::rect(x + k * 0.04, y - k * 0.38 - bob, k * 0.42, k * 0.38), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.34, y - k * 0.16 - bob, k * 0.38, k * 0.34), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.06, y - k * 0.14 - bob, k * 0.4, k * 0.34), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.24, y - k * 0.42 - bob, k * 0.36, k * 0.28), wool_hi);
    ui::fill_circle(c, ui::rect(x - k * 0.02, y - k * 0.36 - bob, k * 0.32, k * 0.24), wool_hi);
    // Side-profile head & floppy ear
    let hx = x + fdir * k * 0.38;
    let hy = y - k * 0.14 - bob;
    ui::fill_circle(c, ui::rect(hx - k * 0.22, hy - k * 0.18, k * 0.44, k * 0.38), ui::rgb(58, 54, 62));
    ui::fill_circle(c, ui::rect(hx + fdir * k * 0.1 - k * 0.12, hy + k * 0.01, k * 0.24, k * 0.18), ui::rgb(82, 76, 86));
    // Floppy hanging ear on side of head
    let ear_x = hx - fdir * k * 0.12;
    ui::fill_circle(c, ui::rect(ear_x - k * 0.1, hy - k * 0.08, k * 0.2, k * 0.24), ui::rgb(44, 40, 48));
    // Fluffy wool crown puff on head
    ui::fill_circle(c, ui::rect(hx - fdir * k * 0.06 - k * 0.16, hy - k * 0.28, k * 0.32, k * 0.22), wool_hi);
    // Expressive side-profile eye
    let ex = hx + fdir * k * 0.08;
    let ey = hy - k * 0.04;
    if blazing {
        ui::fill_circle(c, ui::rect(ex - k * 0.08, ey - k * 0.08, k * 0.16, k * 0.16), ui::rgb(255, 235, 70));
        ui::fill_circle(c, ui::rect(ex - k * 0.03, ey - k * 0.03, k * 0.06, k * 0.06), ui::rgb(180, 20, 10));
        // Blazing flames dancing off the sheep's wool!
        for fl in 4 {
            let fx = x + ((fl as f32) - 1.5) * k * 0.22;
            let fh = k * (0.36 + 0.14 * sin(tm * 28.0 + (fl as f32) * 1.7));
            ui::fill_triangle(c, fx, y - k * 0.36 - bob - fh, fx + k * 0.16, y - k * 0.24 - bob, fx - k * 0.16, y - k * 0.24 - bob, ui::rgba(255, 95, 20, 225));
            ui::fill_triangle(c, fx, y - k * 0.34 - bob - fh * 0.65, fx + k * 0.09, y - k * 0.24 - bob, fx - k * 0.09, y - k * 0.24 - bob, ui::rgb(255, 235, 95));
        }
    } else {
        ui::fill_circle(c, ui::rect(ex - k * 0.06, ey - k * 0.06, k * 0.12, k * 0.12), ui::rgb(255, 255, 255));
        ui::fill_circle(c, ui::rect(ex + fdir * k * 0.02 - k * 0.03, ey - k * 0.03, k * 0.06, k * 0.06), ui::rgb(20, 18, 24));
    }
}

fn draw_bomb(c: ui::Context, s: State&, b: Bomb, ox: f32, oy: f32, t: f32, tm: f32) {
    let k = (0.72 + 0.06 * sin(tm * 10.0 + b.t)) * t;
    var cx = ox + (b.x + 0.5) * t;
    var cy = oy + (b.y + 0.5) * t;
    if b.dir != Dir.None {      // glide in from the tile it just left
        let sl = (1.0 - (b.m as f32) / SLIDE) * t;
        cx -= dir_dx(b.dir) * sl;
        cy -= dir_dy(b.dir) * sl;
    }
    match s.players[b.owner].kind {
        Goose => { draw_egg(c, b, cx, cy, k, tm); },
        Squirrel => { draw_acorn(c, b, cx, cy, k, tm); },
        Baby => { draw_diaper(c, b, cx, cy, k, tm); },
        Cow => { draw_patty(c, b, cx, cy, k, tm); },
        Pig => { draw_bacon(c, b, cx, cy, k, tm); },
        Farmer => { draw_haybale(c, b, cx, cy, k, tm); },
    }
    // Unkickable bomb: heavy iron anchor rim + four steel studs
    if (b.flags & BOMB_UNKICK) != 0 {
        ui::stroke_circle(c, ui::rect(cx - k * 0.54, cy - k * 0.54, k * 1.08, k * 1.08), 3.5, ui::rgb(50, 60, 74));
        for st in 4 {
            let a = st as f32 * 1.5708 + 0.7854;
            ui::fill_circle(c, ui::rect(cx + cos(a) * k * 0.52 - 3.5, cy + sin(a) * k * 0.52 - 3.5, 7.0, 7.0), ui::rgb(190, 205, 220));
        }
    }
    // Directional bomb: bold glowing arrow pointing in blast_dir
    if b.blast_dir != Dir.None {
        let dx: f32 = dir_dx(b.blast_dir);
        let dy: f32 = dir_dy(b.blast_dir);
        let px = -dy;
        let py = dx;
        let tipx = cx + dx * k * 0.48;
        let tipy = cy + dy * k * 0.48;
        let bx = cx - dx * k * 0.14;
        let by = cy - dy * k * 0.14;
        ui::fill_triangle(c, tipx, tipy, bx + px * k * 0.28, by + py * k * 0.28, bx - px * k * 0.28, by - py * k * 0.28, ui::rgb(255, 240, 80));
        ui::stroke_triangle(c, tipx, tipy, bx + px * k * 0.28, by + py * k * 0.28, bx - px * k * 0.28, by - py * k * 0.28, 2.0, ui::rgb(40, 20, 5));
    }
}

fn draw_fireball(c: ui::Context, fb: Fireball, ox: f32, oy: f32, t: f32, tm: f32) {
    let cx = ox + (fb.x as f32) / TILE * t;
    let cy = oy + (fb.y as f32) / TILE * t;
    let dx: f32 = dir_dx(fb.dir);
    let dy: f32 = dir_dy(fb.dir);
    let px = -dy;
    let py = dx;
    let r = t * (0.28 + 0.04 * sin(tm * 32.0));
    // Trailing flame cone
    ui::fill_triangle(c, cx - dx * r * 2.4, cy - dy * r * 2.4, cx + px * r * 0.9, cy + py * r * 0.9, cx - px * r * 0.9, cy - py * r * 0.9, ui::rgba(255, 85, 20, 210));
    ui::fill_circle(c, ui::rect(cx - r * 1.15, cy - r * 1.15, r * 2.3, r * 2.3), ui::rgba(255, 130, 30, 220));
    ui::fill_circle(c, ui::rect(cx - r * 0.8, cy - r * 0.8, r * 1.6, r * 1.6), ui::rgb(255, 220, 70));
    ui::fill_circle(c, ui::rect(cx - r * 0.4, cy - r * 0.4, r * 0.8, r * 0.8), ui::rgb(255, 255, 230));
}

fn draw_mine(c: ui::Context, s: State&, m: Mine, ox: f32, oy: f32, t: f32, tm: f32) {
    let cx = ox + (m.x + 0.5) * t;
    let cy = oy + (m.y + 0.5) * t;
    let r = t * 0.28;
    let mine_owner = m.owner == s.you;
    if m.arm > 0 {
        // Still arming: visible to everyone with blinking red LED
        ui::fill_circle(c, ui::rect(cx - r, cy - r * 0.75, r * 2.0, r * 1.5), ui::rgb(46, 52, 58));
        ui::stroke_circle(c, ui::rect(cx - r, cy - r * 0.75, r * 2.0, r * 1.5), 2.0, col(m.owner));
        let blink = (m.arm / 6) % 2 == 0;
        ui::fill_circle(c, ui::rect(cx - r * 0.3, cy - r * 0.25, r * 0.6, r * 0.5), if blink { ui::rgb(255, 60, 45) } else { ui::rgb(140, 30, 30) });
    } else if mine_owner {
        // Armed: clearly marked for owner
        ui::fill_circle(c, ui::rect(cx - r, cy - r * 0.75, r * 2.0, r * 1.5), ui::rgba(40, 44, 50, 170));
        ui::stroke_circle(c, ui::rect(cx - r * 1.15, cy - r * 0.9, r * 2.3, r * 1.8), 2.0, col(m.owner));
        ui::fill_circle(c, ui::rect(cx - r * 0.22, cy - r * 0.2, r * 0.44, r * 0.4), ui::rgba(255, 60, 45, 210));
    } else {
        // Armed: stealthy subtle bump to enemies!
        ui::fill_circle(c, ui::rect(cx - r * 0.75, cy - r * 0.55, r * 1.5, r * 1.1), ui::rgba(30, 34, 40, 62));
        if sin(tm * 5.0 + m.x as f32) > 0.85 {
            ui::fill_circle(c, ui::rect(cx - 2.5, cy - 2.5, 5.0, 5.0), ui::rgba(255, 70, 50, 110));
        }
    }
}

fn draw_missile(c: ui::Context, m: Missile, owner: i64, ox: f32, oy: f32, t: f32, tm: f32) {
    let cx = ox + (m.x as f32) / TILE * t;
    let cy = oy + (m.y as f32) / TILE * t;
    let k = t * 0.65;
    let dx: f32 = dir_dx(m.dir);
    let dy: f32 = dir_dy(m.dir);
    let px = -dy;
    let py = dx;
    // Rocket exhaust flame behind missile
    let fl = (0.35 + 0.14 * sin(tm * 45.0)) * k;
    ui::fill_circle(c, ui::rect(cx - dx * k * 0.45 - fl * 0.6, cy - dy * k * 0.45 - fl * 0.6, fl * 1.2, fl * 1.2), ui::rgba(255, 130, 30, 210));
    ui::fill_circle(c, ui::rect(cx - dx * k * 0.35 - fl * 0.35, cy - dy * k * 0.35 - fl * 0.35, fl * 0.7, fl * 0.7), ui::rgb(255, 245, 150));
    // Target crosshair ring around missile
    let rr = k * (0.68 + 0.06 * sin(tm * 18.0));
    ui::stroke_circle(c, ui::rect(cx - rr, cy - rr, rr * 2.0, rr * 2.0), 1.8, ui::rgba(255, 70, 60, 180));
    // Missile body + red nose cone + fins
    ui::stroke_line(c, cx - dx * k * 0.3, cy - dy * k * 0.3, cx + dx * k * 0.25, cy + dy * k * 0.25, k * 0.34, ui::rgb(240, 244, 250));
    ui::fill_triangle(c, cx + dx * k * 0.58, cy + dy * k * 0.58,
                         cx + dx * k * 0.16 + px * k * 0.2, cy + dy * k * 0.16 + py * k * 0.2,
                         cx + dx * k * 0.16 - px * k * 0.2, cy + dy * k * 0.16 - py * k * 0.2, ui::rgb(235, 50, 45));
    ui::fill_triangle(c, cx - dx * k * 0.42 + px * k * 0.34, cy - dy * k * 0.42 + py * k * 0.34,
                         cx - dx * k * 0.14, cy - dy * k * 0.14,
                         cx - dx * k * 0.42 - px * k * 0.34, cy - dy * k * 0.42 - py * k * 0.34, col(owner));
}

// Little VR/RC headset + blinking antenna worn while steering a heat-seeker missile.
fn draw_headset(c: ui::Context, x: f32, y: f32, k: f32, tm: f32) {
    let band = ui::rgb(42, 48, 62);
    // Headband + earmuffs
    ui::stroke_circle(c, ui::rect(x - k * 0.46, y - k * 0.58, k * 0.92, k * 0.52), 3.0, band);
    ui::fill_rect(c, ui::rect(x - k * 0.54, y - k * 0.34, k * 0.16, k * 0.28), 4.0, band);
    ui::fill_rect(c, ui::rect(x + k * 0.38, y - k * 0.34, k * 0.16, k * 0.28), 4.0, band);
    // Glowing cyan VR visor
    ui::fill_rect(c, ui::rect(x - k * 0.36, y - k * 0.32, k * 0.72, k * 0.22), 5.0, ui::rgb(30, 38, 52));
    ui::fill_rect(c, ui::rect(x - k * 0.3, y - k * 0.28, k * 0.6, k * 0.14), 3.0, ui::rgb(70, 235, 255));
    // Antenna with blinking red beacon
    ui::stroke_line(c, x + k * 0.44, y - k * 0.34, x + k * 0.5, y - k * 0.78, 2.5, ui::rgb(210, 220, 235));
    let on = sin(tm * 20.0) > 0.0;
    ui::fill_circle(c, ui::rect(x + k * 0.44, y - k * 0.84, k * 0.12, k * 0.12), if on { ui::rgb(255, 60, 50) } else { ui::rgb(120, 30, 30) });
}

fn draw_character(c: ui::Context, kind: Character, owner: i64, x: f32, y: f32, k: f32, fx: f32, fy: f32, walk: f32) {
    match kind {
        Goose => { draw_goose(c, owner, x, y, k, fx, fy, walk); },
        Squirrel => { draw_squirrel(c, owner, x, y, k, fx, fy, walk); },
        Baby => { draw_baby(c, owner, x, y, k, fx, fy, walk); },
        Cow => { draw_cow(c, owner, x, y, k, fx, fy, walk); },
        Pig => { draw_pig(c, owner, x, y, k, fx, fy, walk); },
        Farmer => { draw_farmer(c, owner, x, y, k, fx, fy, walk); },
    }
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
    let is_prey = s.match_mode == MatchMode.Prey && i == (s.vip_slot as i64);
    let is_pred_runner = s.match_mode == MatchMode.Predator && i != (s.vip_slot as i64);
    let is_predator = s.match_mode == MatchMode.Predator && i == (s.vip_slot as i64);
    if gh > 0 {          // ghosts are unseen; only their owner sees a faint, flickering outline
        if i == s.you && (gh > 120 || (gh / 6) % 2 == 0) {
            ui::stroke_circle(c, ui::rect(x - k * 0.5, y - k * 0.5 + walk, k, k), 2.0, ui::rgba(255, 255, 255, 70));
            ui::fill_circle(c, ui::rect(x - k * 0.5, y - k * 0.5 + walk, k, k), ui::rgba(255, 255, 255, 18));
        }
        return;
    }
    if is_prey {
        if i == s.you {
            ui::stroke_circle(c, ui::rect(x - k * 0.52, y - k * 0.52 + walk, k * 1.04, k * 1.04), 2.5, ui::rgba(110, 255, 190, 140));
            ui::fill_circle(c, ui::rect(x - k * 0.48, y - k * 0.48 + walk, k * 0.96, k * 0.96), ui::rgba(110, 255, 190, 35));
        }
        return;
    }
    if is_pred_runner {
        if i == s.you {
            ui::stroke_circle(c, ui::rect(x - k * 0.52, y - k * 0.52 + walk, k * 1.04, k * 1.04), 2.5, ui::rgba(140, 220, 255, 140));
            ui::fill_circle(c, ui::rect(x - k * 0.48, y - k * 0.48 + walk, k * 0.96, k * 0.96), ui::rgba(140, 220, 255, 32));
        } else if (bits & 15) != 0 {
            // Only slightly visible shimmer while moving!
            ui::stroke_circle(c, ui::rect(x - k * 0.46, y - k * 0.46 + walk, k * 0.92, k * 0.92), 2.0, ui::rgba(210, 235, 255, 48));
            ui::fill_circle(c, ui::rect(x - k * 0.36, y - k * 0.36 + walk, k * 0.72, k * 0.72), ui::rgba(210, 235, 255, 18));
        }
        return;
    }
    if is_predator {
        let pulse = 1.18 + 0.08 * sin(tm * 8.0);
        ui::stroke_circle(c, ui::rect(x - k * 0.55 * pulse, y - k * 0.55 * pulse, k * 1.1 * pulse, k * 1.1 * pulse), 3.5, ui::rgba(255, 50, 50, 210));
    }
    if s.match_mode == MatchMode.Teams2v2 {
        let tcol = if team_of(i) == 0 { ui::rgb(255, 110, 80) } else { ui::rgb(70, 195, 255) };
        ui::stroke_circle(c, ui::rect(x - k * 0.6, y + k * 0.14, k * 1.2, k * 0.46), 3.0, tcol);
    }
    if (bits & HOLD) != 0 { ui::stroke_rect(c, ui::rect(x - k * 0.62, y - k * 0.62, k * 1.24, k * 1.24), k * 0.3, 3.0, ui::rgba(255, 255, 255, 190)); }
    if s.players[i].napalm > 0 {
        ui::stroke_circle(c, ui::rect(x - k * 0.62, y - k * 0.56, k * 1.24, k * 1.2), 3.0, ui::rgba(255, 110, 25, 200));
    }
    if s.players[i].slow > 0 {
        ui::stroke_circle(c, ui::rect(x - k * 0.58, y + k * 0.16, k * 1.16, k * 0.44), 3.0, ui::rgba(160, 75, 210, 200));
    }
    ui::fill_circle(c, ui::rect(x - k * 0.5, y + k * 0.3, k, k * 0.4), ui::rgba(0, 0, 0, 110));
    let sway = if s.players[i].drunk > 0 { sin(tm * 16.0 + i as f32) * k * 0.1 } else { 0.0 };
    draw_character(c, s.players[i].kind, i, x + sway, y, k, fx, fy, walk);
    if s.missiles[i].active != 0 { draw_headset(c, x, y, k, tm); }
    if s.players[i].drunk > 0 {
        for b in 3 {
            let a = tm * 6.0 + b as f32 * 2.094;
            let bx = x + cos(a) * k * 0.48;
            let by = y - k * 0.58 + sin(a) * k * 0.16;
            ui::fill_circle(c, ui::rect(bx - 4.0, by - 4.0, 8.0, 8.0), if b % 2 == 0 { ui::rgb(255, 120, 235) } else { ui::rgb(255, 235, 90) });
        }
    }
    marker(c, i, x, y - k * 0.78 + walk, t * 0.13);
    if s.players[i].name.len > 0 {
        let nw = ui::text_width(ui::font(c), s.players[i].name[..]);
        ui::fill_rect(c, ui::rect(x - nw * 0.5 - 6.0, y + k * 0.44, nw + 12.0, 28.0), 5.0, ui::rgba(10, 12, 20, 175));
        text(c, x - nw * 0.5, y + k * 0.44, s.players[i].name[..], ui::rgb(245, 245, 250));
    }
    if i == s.you {
        let bob = 0.06 * t * sin(tm * 6.0);
        ui::fill_triangle(c, x, y - k * 1.0 + bob, x + t * 0.1, y - k * 1.2 + bob, x - t * 0.1, y - k * 1.2 + bob, ui::rgb(255, 255, 255));
    }
}

// Every 5 wins: spotlight zoom-in where the winner dances right in everyone's faces!
fn draw_dance(c: ui::Context, s: State&, who: i64, sw: f32, sh: f32, tm: f32) {
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
    ui::fill_rect(c, ui::rect((sw - sw2) * 0.5 - 18.0, sh - 74.0, sw2 + 36.0, 44.0), 8.0, ui::rgba(15, 18, 30, 215));
    text(c, (sw - sw2) * 0.5, sh - 67.0, sub, ui::rgb(255, 225, 90));
}

// Swirling glowing portal (idx 0 = Cyan, idx 1 = Orange).
fn draw_portal(c: ui::Context, idx: i64, x: f32, y: f32, t: f32, tm: f32) {
    let cx = x + t * 0.5;
    let cy = y + t * 0.5;
    let outer = if idx == 0 { ui::rgb(45, 205, 255) } else { ui::rgb(255, 145, 35) };
    let inner = if idx == 0 { ui::rgba(140, 240, 255, 190) } else { ui::rgba(255, 210, 120, 190) };
    let core = if idx == 0 { ui::rgb(20, 60, 110) } else { ui::rgb(110, 42, 15) };
    let pulse = 0.84 + 0.08 * sin(tm * 6.0 + idx as f32 * 3.14);
    let r = t * 0.44 * pulse;
    ui::fill_circle(c, ui::rect(cx - r * 1.15, cy - r * 1.15, r * 2.3, r * 2.3), if idx == 0 { ui::rgba(45, 205, 255, 55) } else { ui::rgba(255, 145, 35, 55) });
    ui::fill_circle(c, ui::rect(cx - r, cy - r, r * 2.0, r * 2.0), core);
    ui::stroke_circle(c, ui::rect(cx - r, cy - r, r * 2.0, r * 2.0), 3.5, outer);
    ui::stroke_circle(c, ui::rect(cx - r * 0.62, cy - r * 0.62, r * 1.24, r * 1.24), 2.5, inner);
    for k in 4 {
        let a = tm * (if idx == 0 { 4.2 } else { -4.2 }) + k as f32 * 1.5708;
        let sx = cx + cos(a) * r * 0.72;
        let sy = cy + sin(a) * r * 0.72;
        ui::fill_circle(c, ui::rect(sx - 3.5, sy - 3.5, 7.0, 7.0), ui::rgb(255, 255, 255));
    }
}

// Reincarnated dead player as a fluffy side-profile blocking Black Sheep.
fn draw_black_sheep(c: ui::Context, s: State&, i: i64, x: f32, y: f32, t: f32, tm: f32) {
    let k = t * 0.84;
    let bits = s.players[i].bits;
    let fdir: f32 = if s.players[i].facing == Dir.Left { -1.0 } else { 1.0 };
    let moving = (bits & 15) != 0;
    let bob = if moving { 0.04 * t * abs(sin(tm * 18.0)) } else { 0.0 };
    let stride = if moving { sin(tm * 18.0) * k * 0.1 } else { 0.0 };
    let wool = ui::rgb(40, 40, 50);
    let wool_sh = ui::rgb(22, 22, 28);
    let wool_hi = ui::rgb(64, 64, 78);
    ui::fill_circle(c, ui::rect(x - k * 0.56, y + k * 0.28, k * 1.12, k * 0.3), ui::rgba(0, 0, 0, 115));
    ui::fill_rect(c, ui::rect(x - fdir * k * 0.26 - stride - k * 0.05, y + k * 0.16, k * 0.1, k * 0.3), 3.0, ui::rgb(18, 16, 22));
    ui::fill_rect(c, ui::rect(x + fdir * k * 0.16 + stride - k * 0.05, y + k * 0.16, k * 0.1, k * 0.3), 3.0, ui::rgb(18, 16, 22));
    ui::fill_rect(c, ui::rect(x - fdir * k * 0.16 + stride - k * 0.05, y + k * 0.18, k * 0.1, k * 0.3), 3.0, ui::rgb(30, 28, 36));
    ui::fill_rect(c, ui::rect(x + fdir * k * 0.24 - stride - k * 0.05, y + k * 0.18, k * 0.1, k * 0.3), 3.0, ui::rgb(30, 28, 36));
    // Fluffy black tail
    ui::fill_circle(c, ui::rect(x - fdir * k * 0.44 - k * 0.12, y - k * 0.16 - bob, k * 0.24, k * 0.22), wool);
    // Scalloped dark wool body
    ui::fill_circle(c, ui::rect(x - k * 0.46, y - k * 0.34 - bob, k * 0.88, k * 0.64), wool_sh);
    ui::fill_circle(c, ui::rect(x - k * 0.44, y - k * 0.36 - bob, k * 0.42, k * 0.38), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.2, y - k * 0.46 - bob, k * 0.44, k * 0.42), wool);
    ui::fill_circle(c, ui::rect(x + k * 0.04, y - k * 0.38 - bob, k * 0.42, k * 0.38), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.34, y - k * 0.16 - bob, k * 0.38, k * 0.34), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.06, y - k * 0.14 - bob, k * 0.4, k * 0.34), wool);
    ui::fill_circle(c, ui::rect(x - k * 0.24, y - k * 0.42 - bob, k * 0.36, k * 0.28), wool_hi);
    ui::stroke_circle(c, ui::rect(x - k * 0.46, y - k * 0.42 - bob, k * 0.92, k * 0.78), 2.5, col(i));
    // Profile head + floppy ear + glowing yellow eye
    let hx = x + fdir * k * 0.38;
    let hy = y - k * 0.14 - bob;
    ui::fill_circle(c, ui::rect(hx - k * 0.22, hy - k * 0.18, k * 0.44, k * 0.38), ui::rgb(26, 24, 34));
    ui::fill_circle(c, ui::rect(hx - fdir * k * 0.12 - k * 0.1, hy - k * 0.08, k * 0.2, k * 0.24), ui::rgb(18, 16, 24));
    ui::fill_circle(c, ui::rect(hx - fdir * k * 0.06 - k * 0.16, hy - k * 0.28, k * 0.32, k * 0.22), wool_hi);
    ui::fill_circle(c, ui::rect(hx + fdir * k * 0.08 - k * 0.06, hy - k * 0.09, k * 0.12, k * 0.12), ui::rgb(255, 225, 65));
    marker(c, i, x, y - k * 0.74 - bob, t * 0.12);
    if s.players[i].name.len > 0 {
        let nw = ui::text_width(ui::font(c), s.players[i].name[..]);
        ui::fill_rect(c, ui::rect(x - nw * 0.5 - 6.0, y + k * 0.46, nw + 12.0, 28.0), 5.0, ui::rgba(10, 12, 20, 175));
        text(c, x - nw * 0.5, y + k * 0.46, s.players[i].name[..], ui::rgb(210, 210, 220));
    }
}

// Reincarnated dead player as a fast wall-phasing Fog Ghost.
fn draw_fog_ghost(c: ui::Context, s: State&, i: i64, x: f32, y: f32, t: f32, tm: f32) {
    let k = t * 0.78;
    let bob = sin(tm * 7.0 + i as f32) * k * 0.08;
    let body = ui::rgba(205, 225, 255, 165);
    let rim = col(i);
    ui::fill_circle(c, ui::rect(x - k * 0.38, y - k * 0.46 + bob, k * 0.76, k * 0.7), body);
    ui::fill_rect(c, ui::rect(x - k * 0.38, y - k * 0.12 + bob, k * 0.76, k * 0.44), 0.0, body);
    for w in 3 {
        let wx = x - k * 0.38 + (w as f32) * k * 0.253;
        let wy = y + k * 0.24 + bob + sin(tm * 12.0 + w as f32) * k * 0.05;
        ui::fill_circle(c, ui::rect(wx, wy, k * 0.26, k * 0.22), body);
    }
    ui::stroke_circle(c, ui::rect(x - k * 0.42, y - k * 0.5 + bob, k * 0.84, k * 0.84), 2.0, ui::rgba(rim.r, rim.g, rim.b, 170));
    // Glowing cyan eyes
    ui::fill_circle(c, ui::rect(x - k * 0.18, y - k * 0.2 + bob, k * 0.12, k * 0.15), ui::rgb(40, 235, 255));
    ui::fill_circle(c, ui::rect(x + k * 0.06, y - k * 0.2 + bob, k * 0.12, k * 0.15), ui::rgb(40, 235, 255));
    marker(c, i, x, y - k * 0.74 + bob, t * 0.11);
    if s.players[i].name.len > 0 {
        let nw = ui::text_width(ui::font(c), s.players[i].name[..]);
        ui::fill_rect(c, ui::rect(x - nw * 0.5 - 6.0, y + k * 0.46, nw + 12.0, 28.0), 5.0, ui::rgba(10, 12, 20, 155));
        text(c, x - nw * 0.5, y + k * 0.46, s.players[i].name[..], ui::rgb(190, 225, 255));
    }
}

// Thick fog clouds left behind by dead Fog Ghosts, obscuring the arena for alive players.
fn draw_fog(c: ui::Context, g: u8, x: f32, y: f32, t: f32, tm: f32, viewer_ghost: bool) {
    let life = ((g - 96) as f32 + 1.0) / 32.0;
    let base_a = if viewer_ghost { 115.0 } else { 235.0 };
    let a = (base_a * min(1.0, life * 1.4)) as i64;
    let drift = sin(tm * 2.2 + x * 0.05 + y * 0.04) * t * 0.08;
    let r = t * 0.68;
    ui::fill_circle(c, ui::rect(x + t * 0.5 - r + drift, y + t * 0.5 - r, r * 2.0, r * 2.0), ui::rgba(182, 196, 214, a));
    ui::fill_circle(c, ui::rect(x + t * 0.25 - r * 0.6 - drift, y + t * 0.35 - r * 0.6, r * 1.2, r * 1.2), ui::rgba(216, 226, 240, a));
    ui::fill_circle(c, ui::rect(x + t * 0.72 - r * 0.55 + drift * 0.6, y + t * 0.68 - r * 0.55, r * 1.1, r * 1.1), ui::rgba(164, 178, 198, a));
}

fn draw(hud: ui::Context, big: ui::Context, s: State&, shown: float2[:], fx: Fx&, mode: const u8[:], sc: f32, atlas: gfx::Texture, replay_age: f32) {
    let is_replay = replay_age >= 0.0;
    let detailed_tex = s.detailed_tex != 0;
    let size = gfx::screen_size();
    let vw = (size.x as f32) / sc;
    let vh = (size.y as f32) / sc;
    let tm = gfx::time() as f32;
    let top: f32 = 58.0;
    let t = min(vw / W, (vh - top) / H);
    let ox = (vw - t * W) / 2.0 + fx.shake * sin(tm * 90.0);
    let oy = top + fx.shake * cos(tm * 77.0);
    fx.shake *= 0.88;
    let mrow = map_row(s.map);
    if ui::begin(hud, "G", ui::rect(0, 0, vw, vh), ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        ui::fill_rect(hud, ui::rect(ox - 8.0, oy - 8.0, t * W + 16.0, t * H + 16.0), 10.0, map_border_color(s.map));
        for ty in H {
            for tx in W {
                let g = s.grid[ty * W + tx];
                let x = ox + tx * t;
                let y = oy + ty * t;
                if detailed_tex {
                    draw_atlas_tile(hud, atlas, 0, mrow, x, y, t, 255);
                    if g == 1 { draw_atlas_tile(hud, atlas, 1, mrow, x, y, t, 255); }
                    else if g == 2 { draw_atlas_tile(hud, atlas, 2, mrow, x, y, t, 255); }
                    else if g == 6 { draw_atlas_tile(hud, atlas, 4, 3, x, y, t, 255); }
                    else if g == TILE_STEEL_DMG { draw_atlas_tile(hud, atlas, 7, 3, x, y, t, 255); }
                    else if g == 7 { draw_atlas_tile(hud, atlas, 5, 3, x, y, t, 255); }
                    else if g == TILE_GRATE { draw_atlas_tile(hud, atlas, 6, 3, x, y, t, 255); }
                    else if is_power(g) { draw_power(hud, g, x, y, t, tm); }
                    else if is_flame(g) { draw_flame(hud, g, x, y, t, tm); }
                } else {
                    draw_floor(hud, s.map, tx, ty, x, y, t);
                    if g == 1 { draw_wall(hud, s.map, x, y, t); }
                    else if g == 2 { draw_brick(hud, s.map, x, y, t); }
                    else if g == 6 { draw_steel(hud, x, y, t); }
                    else if g == TILE_STEEL_DMG { draw_steel_dmg(hud, x, y, t); }
                    else if g == 7 { draw_gift(hud, x, y, t, tm); }
                    else if g == TILE_GRATE { draw_grate(hud, x, y, t); }
                    else if is_power(g) { draw_power(hud, g, x, y, t, tm); }
                    else if is_flame(g) { draw_flame(hud, g, x, y, t, tm); }
                }
            }
        }
        draw_fences(hud, s, ox, oy, t);
        if s.portals_on != 0 {
            draw_portal(hud, 0, ox + s.portals[0] * t, oy + s.portals[1] * t, t, tm);
            draw_portal(hud, 1, ox + s.portals[2] * t, oy + s.portals[3] * t, t, tm);
        }
        for m in s.mines { draw_mine(hud, s, m, ox, oy, t, tm); }
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
            let life = s.players[i].life;
            if life != Life.Off {
                let px = ox + shown[i].x / TILE * t;
                let py = oy + shown[i].y / TILE * t;
                let ptx = (s.players[i].x / TILE);
                let pty = (s.players[i].y / TILE);
                let in_brush = ptx >= 0 && ptx < W && pty >= 0 && pty < H && s.grid[pty * W + ptx] == TILE_BRUSH;
                if life == Life.Alive {
                    if !in_brush || i == s.you { draw_player(hud, s, i, px, py, t, tm); }
                } else if life == Life.BlackSheep { draw_black_sheep(hud, s, i, px, py, t, tm); }
            }
        }
        // Forests/Brush canopy drawn OVER players so anyone inside is hidden from opponents!
        let my_tx = s.players[s.you].x / TILE;
        let my_ty = s.players[s.you].y / TILE;
        for ty in H {
            for tx in W {
                if s.grid[ty * W + tx] == TILE_BRUSH {
                    let inside = s.players[s.you].life == Life.Alive && tx == my_tx && ty == my_ty;
                    if detailed_tex {
                        draw_atlas_tile(hud, atlas, 3, mrow, ox + tx * t, oy + ty * t, t, if inside { 145 } else { 245 });
                    } else {
                        draw_brush(hud, s.map, ox + tx * t, oy + ty * t, t, tm, inside);
                    }
                }
            }
        }
        for i in 4 {
            if s.missiles[i].active != 0 { draw_missile(hud, s.missiles[i], i, ox, oy, t, tm); }
        }
        for fb in s.fireballs { draw_fireball(hud, fb, ox, oy, t, tm); }
        // Fog clouds drawn OVER the arena so Fog Ghosts genuinely obscure vision!
        let viewer_ghost = s.players[s.you].life == Life.FogGhost;
        for ty in H {
            for tx in W {
                let g = s.grid[ty * W + tx];
                if is_fog(g) { draw_fog(hud, g, ox + tx * t, oy + ty * t, t, tm, viewer_ghost); }
            }
        }
        // Dead Fog Ghosts float above the fog clouds
        for i in 4 {
            if s.players[i].life == Life.FogGhost {
                draw_fog_ghost(hud, s, i, ox + shown[i].x / TILE * t, oy + shown[i].y / TILE * t, t, tm);
            }
        }
        // Day/Night cycle overlay: at night, blocks and bombs vanish into darkness — only glowing eyes & fire flashes show!
        let dark = night_darkness(s);
        if dark > 0.02 && mode != "lobby" && s.over == 0 {
            let da = min(253, (dark * 253.0) as i64);
            ui::fill_rect(hud, ui::rect(ox - 8.0, oy - 8.0, t * W + 16.0, t * H + 16.0), 10.0, ui::rgba(3, 5, 14, da));
            // Active flames, fireballs, and flaming sheep pierce the night darkness!
            if dark > 0.25 {
                for ty in H {
                    for tx in W {
                        let g = s.grid[ty * W + tx];
                        if is_flame(g) {
                            let gx = ox + tx * t;
                            let gy = oy + ty * t;
                            ui::fill_circle(hud, ui::rect(gx - t * 0.35, gy - t * 0.35, t * 1.7, t * 1.7), ui::rgba(255, 140, 40, (dark * 55.0) as i64));
                            draw_flame(hud, g, gx, gy, t, tm);
                        }
                    }
                }
                for fb in s.fireballs { draw_fireball(hud, fb, ox, oy, t, tm); }
                for k in 2 {
                    if s.sheep[k].alive != 0 && s.sheep[k].on_fire > 0 {
                        let sx = ox + (s.sheep[k].x as f32) / TILE * t;
                        let sy = oy + (s.sheep[k].y as f32) / TILE * t;
                        ui::fill_circle(hud, ui::rect(sx - t * 0.7, sy - t * 0.7, t * 1.4, t * 1.4), ui::rgba(255, 120, 30, 85));
                        draw_sheep(hud, s.sheep[k], sx, sy, t, tm);
                    }
                }
                // Only glowing player eyes are visible in the pitch dark!
                let ea = min(255, ((dark - 0.25) / 0.75 * 255.0) as i64);
                for i in 4 {
                    let pl = s.players[i];
                    if pl.life == Life.Off { continue; }
                    if pl.life == Life.Alive && pl.ghost > 0 && i != s.you { continue; }
                    let ptx = pl.x / TILE;
                    let pty = pl.y / TILE;
                    if pl.life == Life.Alive && ptx >= 0 && ptx < W && pty >= 0 && pty < H && s.grid[pty * W + ptx] == TILE_BRUSH && i != s.you { continue; }
                    let px = ox + shown[i].x / TILE * t;
                    let py = oy + shown[i].y / TILE * t - t * 0.12;
                    let lx: f32 = dir_dx(pl.facing) * t * 0.05;
                    let ly: f32 = dir_dy(pl.facing) * t * 0.04;
                    let eye_col = if pl.life == Life.FogGhost { ui::rgba(45, 240, 255, ea) }
                                  else if pl.life == Life.BlackSheep { ui::rgba(255, 225, 65, ea) }
                                  else if i == s.you { ui::rgba(255, 248, 210, ea) }
                                  else { ui::rgba(255, 195, 95, ea) };
                    ui::fill_circle(hud, ui::rect(px - t * 0.14 + lx, py - t * 0.06 + ly, t * 0.11, t * 0.13), eye_col);
                    ui::fill_circle(hud, ui::rect(px + t * 0.03 + lx, py - t * 0.06 + ly, t * 0.11, t * 0.13), eye_col);
                    ui::fill_circle(hud, ui::rect(px - t * 0.105 + lx * 1.3, py - t * 0.02 + ly * 1.3, t * 0.045, t * 0.055), ui::rgba(15, 15, 22, ea));
                    ui::fill_circle(hud, ui::rect(px + t * 0.065 + lx * 1.3, py - t * 0.02 + ly * 1.3, t * 0.045, t * 0.055), ui::rgba(15, 15, 22, ea));
                }
            }
        }
        // Bottom status strip for active power-ups or post-death controls
        let me = s.players[s.you];
        var st: u8[>..] = [];
        match me.life {
            BlackSheep => {
                st.append("BLACK SHEEP (block alive players!)  -  [Space] Switch to Fog Ghost");
            },
            FogGhost => {
                st.append("FOG GHOST (fast, phase through walls, leave fog!)  -  [Space] Switch to Black Sheep");
            },
            Alive => {
                if s.missiles[s.you].active != 0 { st.append("GUIDING MISSILE (Arrows/WASD steer, Space detonate)  "); }
                else if me.missiles > 0 { format(st, "Missile x", me.missiles, " [Space]  "); }
                if me.mines > 0 { format(st, "Mines x", me.mines, " [E/X]  "); }
                if me.builds > 0 { format(st, "Build x", me.builds, " [Q=Block, Shift+Q=Fence]  "); }
                if me.dir_bombs > 0 { format(st, "DirBomb x", me.dir_bombs, " [Space]  "); }
                if me.fireballs > 0 { format(st, "Fireball x", me.fireballs, " [F]  "); }
                else if me.flamer > 0 { format(st, "Flamethrower x", me.flamer, " [F]  "); }
                if me.napalm > 0 { st.append("NAPALM  "); }
                if me.drunk > 0 { st.append("DRUNK!  "); }
                if me.unkick != 0 { st.append("AnchorBombs  "); }
                if me.slow > 0 { st.append("CURSED(Slow+Range)  "); }
            },
            Off => {},
        }
        if st.len > 0 {
            let sw0 = ui::text_width(ui::font(hud), st);
            ui::fill_rect(hud, ui::rect((vw - sw0) * 0.5 - 14.0, vh - 40.0, sw0 + 28.0, 34.0), 7.0, ui::rgba(10, 12, 20, 200));
            text(hud, (vw - sw0) * 0.5, vh - 37.0, st, ui::rgb(255, 225, 110));
        }
        if mode != "lobby" {
            ui::fill_rect(hud, ui::rect(0, 0, vw, top - 8.0), 0.0, ui::rgba(10, 12, 20, 205));
            var x: f32 = 14.0;
            for i in 4 {
                guard s.players[i].life != Life.Off else { continue; }
                var nm: u8[>..] = [];
                player_name(s, i, nm);
                var line: u8[>..] = [];
                if s.match_mode == MatchMode.Teams2v2 {
                    format(line, if team_of(i) == 0 { "[T1] " } else { "[T2] " });
                } else if s.match_mode == MatchMode.Prey && i == (s.vip_slot as i64) {
                    line.append("[PREY] ");
                } else if s.match_mode == MatchMode.Predator && i == (s.vip_slot as i64) {
                    line.append("[PRED] ");
                }
                if s.players[i].streak >= 2 { format(line, nm[..], " ", s.players[i].wins, " [", s.players[i].streak, "x]"); }
                else { format(line, nm[..], " ", s.players[i].wins); }
                let lw = ui::text_width(ui::font(hud), line);
                let boxw = max(108.0, lw + 38.0);
                marker(hud, i, x + 12.0, 24.0, 10.0);
                text(hud, x + 28.0, 10.0, line, if s.players[i].life == Life.Alive { ui::rgb(240, 240, 245) } else { ui::rgb(120, 124, 140) });
                if i == s.you && mode != "solo" { ui::stroke_rect(hud, ui::rect(x - 6.0, 4.0, boxw, 40.0), 7.0, 2.5, ui::rgb(255, 255, 255)); }
                x += boxw + 12.0;
            }
            var tag: u8[>..] = [];
            if s.match_mode == MatchMode.Prey { format(tag, "PREY ", (s.round_timer as i64 + 59) / 60, "s  "); }
            else if s.match_mode == MatchMode.Teams2v2 { tag.append("2v2  "); }
            else if s.match_mode == MatchMode.Predator { tag.append("PREDATOR  "); }
            if mode == "solo" { tag.append("SOLO"); } else if mode == "host" { tag.append("HOST"); } else { format(tag, "CLIENT P", s.you + 1); if mode == "udp" { tag.append(" UDP"); } }
            if fx.lost { tag.append("  DISCONNECTED"); }
            text(hud, vw - 14.0 - ui::text_width(ui::font(hud), tag), 10.0, tag, ui::rgb(160, 168, 190));
        } else {
            ui::fill_rect(hud, ui::rect(0, 0, vw, vh), 0.0, ui::rgba(8, 10, 18, 165));
        }
        if is_replay {
            let subtle_p = 0.5 + 0.5 * sin(tm * 5.0);
            let rp_a = (75.0 + 65.0 * subtle_p) as i64;
            ui::stroke_rect(hud, ui::rect(ox - 8.0, oy - 8.0, t * W + 16.0, t * H + 16.0), 10.0, 3.0, ui::rgba(255, 72, 72, rp_a));
            // Subtle broadcast pill in the top HUD bar (never covers the arena action!)
            let btxt = "REPLAY 0.5x";
            let bw = ui::text_width(ui::font(hud), btxt) + 36.0;
            let bx = max(12.0, vw - bw - 165.0);
            ui::fill_rect(hud, ui::rect(bx, 7.0, bw, 34.0), 8.0, ui::rgba(36, 12, 16, 210));
            ui::stroke_rect(hud, ui::rect(bx, 7.0, bw, 34.0), 8.0, 1.5, ui::rgba(255, 82, 82, 160));
            let dot_a = (95.0 + 160.0 * subtle_p) as i64;
            ui::fill_circle(hud, ui::rect(bx + 10.0, 18.0, 12.0, 12.0), ui::rgba(255, 62, 62, dot_a));
            text(hud, bx + 28.0, 10.0, btxt, ui::rgba(255, 224, 210, 235));
        }
        let show_over = !is_replay && s.over > 0 && s.over <= (if s.dance_who < 4 { 495 } else { 405 });
        if show_over && s.dance_who < 4 {
            draw_dance(hud, s, s.dance_who as i64, vw, vh, tm);
        }
    }
    ui::end(hud);
    let show_big_over = !is_replay && s.over > 0 && s.over <= (if s.dance_who < 4 { 495 } else { 405 });
    if ui::begin(big, "B", ui::rect(0, 0, vw, vh), ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
        if is_replay && replay_age < 1.1 {
            // Brief bold "REPLAY!" flash across the screen on entry, then clear completely so action stays unobstructed!
            let fade = if replay_age > 0.85 { max(0.0, (1.1 - replay_age) / 0.25) } else { 1.0 };
            let flash = 0.5 + 0.5 * cos(replay_age * 16.0);
            let vis = (0.35 + 0.65 * flash) * fade;
            let rtxt = "REPLAY!";
            let rw = ui::text_width(ui::font(big), rtxt);
            let ry = vh * 0.40;
            let ba = (165.0 * vis) as i64;
            let ta = (255.0 * vis) as i64;
            ui::fill_rect(big, ui::rect(0.0, ry - 12.0, vw, 122.0), 0.0, ui::rgba(24, 6, 10, ba));
            ui::fill_rect(big, ui::rect(0.0, ry - 12.0, vw, 4.0), 0.0, ui::rgba(255, 72, 72, ta));
            ui::fill_rect(big, ui::rect(0.0, ry + 106.0, vw, 4.0), 0.0, ui::rgba(255, 72, 72, ta));
            let rx = (vw - rw) * 0.5;
            ui::fill_circle(big, ui::rect(rx - 44.0, ry + 36.0, 26.0, 26.0), ui::rgba(255, 58, 58, ta));
            ui::fill_circle(big, ui::rect(rx + rw + 18.0, ry + 36.0, 26.0, 26.0), ui::rgba(255, 58, 58, ta));
            text(big, rx + 4.0, ry + 4.0, rtxt, ui::rgba(0, 0, 0, ta));
            text(big, rx, ry, rtxt, ui::rgba(255, (215.0 + 40.0 * flash) as i64, (72.0 + 110.0 * flash) as i64, ta));
        } else if show_big_over {
            if s.dance_who < 4 {
                let who = s.dance_who as i64;
                var nm: u8[>..] = [];
                player_name(s, who, nm);
                var title: u8[>..] = [];
                format(title, nm[..], " - ", s.players[who].wins, " WINS!");
                let tw = ui::text_width(ui::font(big), title);
                text(big, (vw - tw) * 0.5, 42.0, title, col(who));
            } else {
                var who = -1;
                for i in 4 { if s.players[i].life == Life.Alive { who = i; } }
                var msg: u8[>..] = [];
                match s.match_mode {
                    Teams2v2 => {
                        var t0_al = 0; var t1_al = 0;
                        for i in 4 {
                            if s.players[i].life == Life.Alive {
                                if team_of(i) == 0 { t0_al += 1; } else { t1_al += 1; }
                            }
                        }
                        if t0_al > 0 && t1_al == 0 { msg.append("TEAM 1 WINS!"); }
                        else if t1_al > 0 && t0_al == 0 { msg.append("TEAM 2 WINS!"); }
                        else { msg.append("DRAW"); }
                    },
                    Prey => {
                        if s.players[s.vip_slot].life == Life.Alive { msg.append("PREY SURVIVED!"); }
                        else { msg.append("HUNTERS WIN!"); }
                    },
                    Predator => {
                        if s.players[s.vip_slot].life == Life.Alive { msg.append("PREDATOR WINS!"); }
                        else { msg.append("RUNNERS WIN!"); }
                    },
                    FreeForAll => {
                        if who >= 0 && s.players[who].life != Life.Off {
                            var nm: u8[>..] = [];
                            player_name(s, who, nm);
                            if s.players[who].streak >= 2 { format(msg, nm[..], " WINS! (", s.players[who].streak, "x)"); }
                            else { format(msg, nm[..], " WINS!"); }
                        } else { msg.append("DRAW"); }
                    },
                }
                let w = ui::text_width(ui::font(big), msg);
                ui::fill_rect(big, ui::rect(0, vh / 2.0 - 75.0, vw, 145.0), 0.0, ui::rgba(10, 12, 20, 195));
                text(big, (vw - w) / 2.0, vh / 2.0 - 60.0, msg, if who >= 0 { col(who) } else { ui::rgb(230, 230, 235) });
            }
        }
    }
    ui::end(big);
}

// ---- main -------------------------------------------------------------------------------------

fn keys() -> u16 {
    var b: u16 = 0;
    if gfx::key_down("Up") || gfx::key_down("W") { b |= UP as u16; }
    if gfx::key_down("Down") || gfx::key_down("S") { b |= DOWN as u16; }
    if gfx::key_down("Left") || gfx::key_down("A") { b |= LEFT as u16; }
    if gfx::key_down("Right") || gfx::key_down("D") { b |= RIGHT as u16; }
    if gfx::key_down("Space") { b |= BOMB as u16; }
    if gfx::key_down("Left Shift") || gfx::key_down("Right Shift") { b |= HOLD as u16; }
    if gfx::key_down("E") || gfx::key_down("X") { b |= MINE_KEY as u16; }
    if gfx::key_down("Q") { b |= BUILD_KEY as u16; }
    if gfx::key_down("F") { b |= FIRE_KEY as u16; }
    return b;
}

// A bot's keys: wander in changing directions and drop bombs now and then.
fn bot(frame: i64, seed: i64) -> u16 {
    let d = ((frame / 20 + seed) * 7) % 4;
    var b: u16 = (1 << d) as u16;
    if frame % 45 == 0 { b |= BOMB as u16; }
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

fn parse_port(s: const u8[:], fallback: i64) -> i64 {
    var v = 0;
    var any = false;
    for i in s.len {
        let c = s[i];
        if c >= 48 && c <= 57 {
            v = v * 10 + (c - 48);
            any = true;
            if v > 65535 { return fallback; }
        } else if c != 32 && c != 13 && c != 10 {
            return fallback;
        }
    }
    if !any || v < 1 || v > 65535 { return fallback; }
    return v;
}

// Parses "HOST" or "HOST:PORT" (stripping optional ws:// or http:// and trailing /path).
fn parse_host_port(raw: const u8[:], host_out: u8[..96]&, default_port: i64) -> i64 {
    host_out.resize(0);
    var a = 0;
    var b = raw.len;
    while a < b && (raw[a] == 32 || raw[a] == 9 || raw[a] == 13 || raw[a] == 10) { a += 1; }
    while b > a && (raw[b - 1] == 32 || raw[b - 1] == 9 || raw[b - 1] == 13 || raw[b - 1] == 10) { b -= 1; }
    // Strip optional scheme like "ws://" or "http://"
    for i in a..b - 2 {
        if raw[i] == 58 && raw[i + 1] == 47 && raw[i + 2] == 47 { a = i + 3; break; }
    }
    // Strip optional path suffix "/..."
    for i in a..b {
        if raw[i] == 47 { b = i; break; }
    }
    var colon = -1;
    for i in a..b {
        if raw[i] == 58 { colon = i; }
    }
    let hend = if colon > a { colon } else { b };
    let hlen = min(96, max(0, hend - a));
    for k in hlen { host_out.push(raw[a + k]); }
    if colon > a && colon + 1 < b {
        return parse_port(raw[colon + 1..b], default_port);
    }
    return default_port;
}

fn format_host_port(host: const u8[:], port: i64, out: u8[>..]&) {
    out.resize(0);
    if port == 8080 { out.append(host); }
    else { format(out, host, ":", port); }
}

fn prefs_path(out: u8[>..]&) -> bool {
    out.resize(0);
    if !env("HOME", out) {
        out.resize(0);
        if !env("USERPROFILE", out) { return false; }
    }
    out.append("/.bomberman");
    make_dir(out[..]);
    out.append("/prefs.txt");
    return true;
}

fn load_prefs(name: u8[..12]&, kind: Character&, has_name_cli: bool, join_addr: u8[..96]&, has_join_cli: bool, playit_addr: u8[..96]&, has_playit_cli: bool) {
    var path: u8[>..] = [];
    guard prefs_path(path) && file_exists(path[..]) else { return; }
    var raw: u8[>..] = [];
    guard read_file(path[..], raw) else { return; }
    var line = 0;
    var start = 0;
    for i in raw.len + 1 {
        if i == raw.len || raw[i] == 10 {
            var end = i;
            if end > start && raw[end - 1] == 13 { end -= 1; }
            let seg = raw[start..end];
            if line == 0 && !has_name_cli && seg.len > 0 {
                name.resize(0);
                for k in min(12, seg.len) { name.push(seg[k]); }
            } else if line == 1 && seg.len > 0 {
                let kv = parse_port(seg, 0);
                if seg.len == 1 && seg[0] == 48 { kind = Character.Goose; }
                else if kv >= 1 && kv <= 5 { kind = char_from_u8(kv as u8); }
            } else if line == 2 && !has_join_cli && seg.len > 0 {
                join_addr.resize(0);
                for k in min(96, seg.len) { join_addr.push(seg[k]); }
            } else if line == 3 && !has_playit_cli && seg.len > 0 {
                playit_addr.resize(0);
                for k in min(96, seg.len) { playit_addr.push(seg[k]); }
            }
            line += 1;
            start = i + 1;
        }
    }
}

fn save_prefs(name: const u8[:], kind: Character, join_addr: const u8[:], playit_addr: const u8[:]) {
    var path: u8[>..] = [];
    guard prefs_path(path) else { return; }
    var data: u8[>..] = [];
    format(data, name, "\n", char_to_u8(kind), "\n", join_addr, "\n", playit_addr, "\n");
    write_file_atomic(path[..], data[..]);
}

fn replays_dir(out: u8[>..]&) -> bool {
    out.resize(0);
    if !env("HOME", out) {
        out.resize(0);
        if !env("USERPROFILE", out) { return false; }
    }
    out.append("/.bomberman");
    make_dir(out[..]);
    out.append("/replays");
    make_dir(out[..]);
    return true;
}

fn format_kill_label(s: State&, victim: i64, killer: i64, cause: u8, out: u8[..64]&) {
    out.resize(0);
    var vn: u8[>..] = [];
    player_name(s, victim, vn);
    var tmp: u8[>..] = [];
    if cause == CAUSE_SHEEP {
        format(tmp, "R", s.round_num, ": ", vn[..], " burned by Flaming Sheep!");
    } else if cause == CAUSE_SUICIDE || killer == victim {
        format(tmp, "R", s.round_num, ": ", vn[..], " self-destructed!");
    } else if killer >= 0 && killer < 4 {
        var kn: u8[>..] = [];
        player_name(s, killer, kn);
        format(tmp, "R", s.round_num, ": ", kn[..], " eliminated ", vn[..], "!");
    } else {
        format(tmp, "R", s.round_num, ": ", vn[..], " eliminated!");
    }
    for k in min(64, tmp.len) { out.push(tmp[k]); }
}

fn save_kill_clip(clip: KillClip&, idx: i64) -> bool {
    var dir: u8[>..] = [];
    guard replays_dir(dir) else { return false; }
    var path: u8[>..] = [];
    format(path, dir[..], "/kill_R", clip.round, "_", idx, ".brep");
    var one = [clip];
    var raw: u8[>..] = [];
    one.to_bytes(raw);
    return write_file_atomic(path[..], raw[..]);
}

fn load_kill_clip(filename: const u8[:], out: KillClip&) -> bool {
    var dir: u8[>..] = [];
    guard replays_dir(dir) else { return false; }
    var path: u8[>..] = [];
    format(path, dir[..], "/", filename);
    var raw: u8[>..] = [];
    guard file_exists(path[..]) && read_file(path[..], raw) else { return false; }
    return http::mail_value(raw[..], out);
}

fn print_join_hint(label: const u8[:], addr: const u8[:]) {
    print(label, " - friends can join with: ", addr);
    print("  Mac:     ./bomberman-portable join ", addr);
    print("  Windows: bomberman.exe join ", addr);
}

fn main() {
    let argv = args();
    var mode: GameMode = GameMode.Lobby;
    var host_net: HostNet = HostNet.Lan;
    var host_port = 8080;
    var frames = -1;
    var init_map: Map = Map.Island;
    var force_tcp = false;
    var my_name: u8[..12] = [];
    var has_name_cli = false;
    var join_addr: u8[..96] = [];
    var has_join_cli = false;
    var playit_addr: u8[..96] = [];
    var has_playit_cli = false;
    if argv.len > 1 {
        if argv[1] == "solo" { mode = GameMode.Solo; }
        else if argv[1] == "host" { mode = GameMode.Host; }
        else if argv[1] == "join" && argv.len > 2 {
            mode = GameMode.Join;
            has_join_cli = true;
            for k in min(96, argv[2].len) { join_addr.push(argv[2][k]); }
        } else {
            abort("usage: bomberman [solo | host [--port N] [--upnp | --lan | --playit ADDR] | join HOST[:PORT] [tcp]]");
        }
    }
    var my_kind: Character = if mode == GameMode.Join { Character.Goose } else { default_kind(0) };
    for i in argv.len {
        if argv[i] == "tcp" { force_tcp = true; }
        if argv[i] == "--upnp" { host_net = HostNet.Upnp; }
        if argv[i] == "--lan" { host_net = HostNet.Lan; }
        if argv[i] == "--port" && i + 1 < argv.len { host_port = parse_port(argv[i + 1], 8080); }
        if argv[i] == "--playit" && i + 1 < argv.len {
            host_net = HostNet.Playit;
            has_playit_cli = true;
            playit_addr.resize(0);
            for k in min(96, argv[i + 1].len) { playit_addr.push(argv[i + 1][k]); }
        }
        if argv[i] == "--frames" && i + 1 < argv.len { frames = parse_int(argv[i + 1]); }
        if argv[i] == "--map" && i + 1 < argv.len { init_map = map_from_int(parse_int(argv[i + 1])); }
        if argv[i] == "--name" && i + 1 < argv.len {
            has_name_cli = true;
            my_name.resize(0);
            let ln = min(12, argv[i + 1].len);
            for k in ln { my_name.push(argv[i + 1][k]); }
        }
    }
    if frames < 0 {
        load_prefs(my_name, my_kind, has_name_cli, join_addr, has_join_cli, playit_addr, has_playit_cli);
    }
    var port_str: u8[..8] = [];
    format(port_str, host_port);
    var lan_ip: u8[..64] = [];
    {
        var ipbuf: u8[>..] = [];
        ipbuf.resize(64, 0);
        let iplen = udp_local_ip(ipbuf[..]);
        if iplen > 0 { for k in min(64, iplen) { lan_ip.push(ipbuf[k]); } }
        else { let fb = "<YOUR_IP>"; for k in fb.len { lan_ip.push(fb[k]); } }
    }
    var s = State { .. };
    var prev = State { .. };
    var r = rng { random_seed() };
    var ack: i64[4] = [0, 0, 0, 0];
    var inp_max: i64[4] = [-1, -1, -1, -1];    // host: highest input seq received from each client
    var inp_bits: u16[>..] = [];
    inp_bits.resize(128, 0);                   // host: 32-slot seq input ring per player
    var inp_seq: i64[>..] = [];
    inp_seq.resize(128, -1);
    var usock: i64 = -1;
    var upeer: i64[4] = [-1, -1, -1, -1];      // host: where each client's datagrams come from
    var uage: i64[4] = [999, 999, 999, 999];   // host: ticks since a client's last datagram
    var uok: bool[4] = [false, false, false, false]; // host: client confirmed receiving UDP snapshots
    var rbuf: u8[>..] = [];
    rbuf.resize(4096, 0);
    var csock: i64 = -1;
    var hostpeer: i64 = -1;
    var use_udp = false;
    var udp_rx_age = 999; // client: ticks since last UDP snapshot received from host
    var joined = false;  // client: got the first snapshot, so we know our slot
    var lasttick = 0;
    var n_udp = 0;       // datagrams received (host: inputs, client: snapshots)
    var n_applied = 0;       // snapshots applied (from either channel)
    var upnp_busy = false;
    var upnp_mapped = false;
    var upnp_code = -1;
    var upnp_ip: u8[..64] = [];
    var upnp_status: u8[..128] = [];
    var host_started = false;
    var join_started = false;
    var lobby_err: u8[..96] = [];
    let none = http::MailAddress { .. };
    var addr: http::MailAddress[4] = [none, none, none, none];
    for i in 4 { s.players[i].kind = default_kind(i); }
    s.players[0].life = Life.Alive;
    s.players[0].name = my_name;
    s.players[0].kind = my_kind;
    s.drops = 33;
    s.regrow = 35;
    s.map = init_map;
    s.portals_on = 1;
    s.power_mask = PWR_ALL;
    s.fuse_ticks = FUSE as u16;
    s.fuse_rand = 0;
    s.fire_ticks = 16;
    s.fire_rand = 0;
    s.fire_range = 2;
    s.range_rand = 0;
    s.day_night_on = 1;
    s.detailed_tex = 1;
    s.friendly_fire = 1;
    s.match_mode = MatchMode.FreeForAll;
    reset_round(s, r);
    var start_host = mode == GameMode.Host;
    var start_join = mode == GameMode.Join;
    if start_host {
        start_host = false;
        host_started = true;
        usock = udp_open(host_port);
        let cfg = http::Config { port: host_port as i32, workers: 1, mail_slots: 64, mail_size: 4096, max_waiting: 16, .. };
        thread_spawn(server, cfg);
        var lan_disp: u8[>..] = [];
        format_host_port(lan_ip[..], host_port, lan_disp);
        print_join_hint("Hosting (LAN/Tailscale)", lan_disp[..]);
        if host_net == HostNet.Upnp {
            upnp_busy = true;
            upnp_status.resize(0);
            let st = "Mapping port via UPnP / NAT-PMP...";
            for k in st.len { upnp_status.push(st[k]); }
            thread_spawn(upnp_worker, UpnpReq { port: host_port, enable: true });
        } else if host_net == HostNet.Playit && playit_addr.len > 0 {
            print_join_hint("Hosting (playit.gg)", playit_addr[..]);
        }
    }
    if start_join {
        start_join = false;
        join_started = true;
        var jhost: u8[..96] = [];
        let jport = parse_host_port(join_addr[..], jhost, 8080);
        if !force_tcp {
            csock = udp_open(0);
            hostpeer = udp_peer(jhost[..], jport);
            use_udp = csock >= 0 && hostpeer >= 0;
        }
        var url: u8[..128] = [];
        format(url, "ws://", jhost[..], ":", jport, "/ws");
        thread_spawn(client, url);
        if my_name.len > 0 { qput(Profile { my_kind, my_name }); }
    }
    guard gfx::open("Bomberman", 960, 720, gfx::WINDOW_RESIZABLE) else { abort(str("gfx: ", gfx::error())); }
    audio::open();
    let sfx = make_sfx(r);
    let night_snd = make_night_sfx(r);
    let atlas = make_tile_atlas();
    // Your own music: put a 16-bit PCM WAV named music.wav next to the game and it plays instead of the chiptune.
    var wav: u8[>..] = [];
    var pcm: f32[>..] = [];
    var info: i64[>..] = [];
    let own = file_exists("music.wav") && read_file("music.wav", wav) && wav_pcm(wav, pcm, info);
    if own { print("playing music.wav: ", info[0], " Hz, ", info[1], " channels"); }
    let mvol: f32 = if own { 0.5 } else { 0.2 };
    let songs: audio::Sound[6] = [make_music_forest(r), make_music_mountains(r), make_music_desert(r), make_music(r), make_dark(r), make_music_island(r)];
    var track = 0;
    var last_map = s.map;
    var tune = if own { audio::play(audio::create_sound(pcm, info[0], info[1]), mvol, 0.0, 1.0, true) } else { audio::play(songs[track], mvol, 0.0, 1.0, true) };
    let night_voice = audio::play(night_snd, 0.0, 0.0, 1.0, true);
    var muted = false;
    let hud = overlay(28.0);
    let big = overlay(104.0);
    let panel = overlay(24.0);
    let menu = ui::create_from_memory(ROBOTO, 24.0);
    let check_tex = make_check_tex();
    {
        var mstyle = ui::style(menu);
        mstyle.checkbox.normal = ui::style_item_color(ui::rgb(24, 28, 38));
        mstyle.checkbox.hover = ui::style_item_color(ui::rgb(38, 44, 60));
        mstyle.checkbox.active = ui::style_item_color(ui::rgb(32, 38, 52));
        mstyle.checkbox.border_color = ui::rgb(138, 152, 180);
        mstyle.checkbox.border = 2.0;
        mstyle.checkbox.padding = float2 { 1.0, 1.0 };
        mstyle.checkbox.cursor_normal = ui::style_item_image(ui::texture_image(check_tex));
        mstyle.checkbox.cursor_hover = ui::style_item_image(ui::texture_image(check_tex));
        mstyle.option.normal = ui::style_item_color(ui::rgb(24, 28, 38));
        mstyle.option.hover = ui::style_item_color(ui::rgb(38, 44, 60));
        mstyle.option.active = ui::style_item_color(ui::rgb(32, 38, 52));
        mstyle.option.border_color = ui::rgb(138, 152, 180);
        mstyle.option.border = 2.0;
        mstyle.option.cursor_normal = ui::style_item_color(ui::rgb(52, 204, 114));
        mstyle.option.cursor_hover = ui::style_item_color(ui::rgb(82, 224, 138));
        ui::set_style(menu, mstyle);
    }
    let init_sz = gfx::screen_size();
    var sc: f32 = max(1.0, min(3.5, min((init_sz.x as f32) / 960.0, (init_sz.y as f32) / 720.0)));
    if sc != 1.0 {
        ui::set_scale(hud, sc);
        ui::set_scale(big, sc);
        ui::set_scale(panel, sc);
        ui::set_scale(menu, sc);
    }
    var menu_open = mode != GameMode.Lobby && frames < 0 && my_name.len == 0;
    var host_open = false;
    var stats_open = false;
    var replays_open = false;
    var ring: State[>..] = [];
    var clips: KillClip[>..] = [];
    var active_rec = KillClip { .. };
    var rec_post = 0;
    var last_rec_tick = -1;
    var prev_over_rec: i64 = 0;
    var prev_life: Life[4] = [Life.Off, Life.Off, Life.Off, Life.Off];
    var round_clip_start = 0;
    var reel_active = false;
    var reel_wait = 0;
    var reel_idx = 0;
    var reel_end = 0;
    var reel_f = 0;
    var reel_acc = 0.0;
    var reel_age = 0.0;
    var single_watch = false;
    var watch_clip = KillClip { .. };
    var replay_msg: u8[..80] = [];
    var saved_list: u8[>..] = [];
    let z = float2 { 0.0, 0.0 };
    var shown: float2[4] = [z, z, z, z];
    var fx = Fx { .. };
    var seq = 0;         // client: number of the latest input step
    var hist: u16[..240] = [];       // the key bits of the last steps, to replay on top of a snapshot
    var px = 0;          // client: where this player is predicted to be
    var py = 0;
    var acc = 0.0;
    var n = 0;
    var frame = 0;
    while gfx::frame() {
        if frame == frames { break; }
        // Poll background UPnP / NAT-PMP worker results without blocking the UI.
        loop {
            let ur, ugot = qpoll<UpnpRes>();
            guard ugot else { break; }
            upnp_busy = false;
            upnp_code = ur.code;
            upnp_status = ur.msg;
            if ur.code == 0 || ur.code == 1 {
                upnp_mapped = true;
                upnp_ip = ur.pub_ip;
                if ur.code == 0 && upnp_ip.len > 0 {
                    var pub_disp: u8[>..] = [];
                    format_host_port(upnp_ip[..], host_port, pub_disp);
                    print_join_hint("Public Internet (UPnP/NAT-PMP)", pub_disp[..]);
                } else if upnp_status.len > 0 {
                    print("Port-forward: ", upnp_status[..]);
                }
            } else {
                upnp_mapped = false;
                upnp_ip.resize(0);
                if upnp_status.len > 0 { print("Port-forward: ", upnp_status[..]); }
            }
        }
        if start_host && !host_started {
            start_host = false;
            host_started = true;
            mode = GameMode.Host;
            s.players[0].name = my_name;
            s.players[0].kind = my_kind;
            usock = udp_open(host_port);
            let cfg = http::Config { port: host_port as i32, workers: 1, mail_slots: 64, mail_size: 4096, max_waiting: 16, .. };
            thread_spawn(server, cfg);
            var lan_disp: u8[>..] = [];
            format_host_port(lan_ip[..], host_port, lan_disp);
            print_join_hint("Hosting (LAN/Tailscale)", lan_disp[..]);
            if host_net == HostNet.Upnp && !upnp_busy {
                upnp_busy = true;
                upnp_status.resize(0);
                let st = "Mapping port via UPnP / NAT-PMP...";
                for k in st.len { upnp_status.push(st[k]); }
                thread_spawn(upnp_worker, UpnpReq { port: host_port, enable: true });
            } else if host_net == HostNet.Playit && playit_addr.len > 0 {
                print_join_hint("Hosting (playit.gg)", playit_addr[..]);
            }
            if frames < 0 { save_prefs(my_name[..], my_kind, join_addr[..], playit_addr[..]); }
        }
        if start_join && !join_started {
            start_join = false;
            join_started = true;
            mode = GameMode.Join;
            var jhost: u8[..96] = [];
            let jport = parse_host_port(join_addr[..], jhost, 8080);
            if !force_tcp {
                csock = udp_open(0);
                hostpeer = udp_peer(jhost[..], jport);
                use_udp = csock >= 0 && hostpeer >= 0;
            }
            var url: u8[..128] = [];
            format(url, "ws://", jhost[..], ":", jport, "/ws");
            thread_spawn(client, url);
            qput(Profile { my_kind, my_name });
            if frames < 0 { save_prefs(my_name[..], my_kind, join_addr[..], playit_addr[..]); }
        }
        if gfx::key_pressed("Escape") {
            if single_watch { single_watch = false; }
            else if reel_active { reel_active = false; }
            else if replays_open { replays_open = false; }
            else if stats_open { stats_open = false; }
            else if host_open { host_open = false; }
            else if menu_open { menu_open = false; }
            else { break; }
        }
        if (single_watch || reel_active) && gfx::key_pressed("Space") {
            if single_watch { single_watch = false; }
            else {
                reel_idx += 1;
                reel_f = 0;
                reel_acc = 0.0;
                reel_age = 0.0;
                if reel_idx >= reel_end { reel_active = false; }
            }
        }
        let typing = mode == GameMode.Lobby || menu_open || host_open || stats_open || replays_open || single_watch || reel_active || ui::wants_keyboard(menu);
        if !typing && gfx::key_pressed("Tab") { stats_open = !stats_open; }
        if !typing && gfx::key_pressed("N") && !own {          // cycle through all map themes + classic & dark tracks
            track = (track + 1) % 6;
            audio::stop(tune);
            tune = audio::play(songs[track], if muted { 0.0 } else { mvol }, 0.0, 1.0, true);
        }
        if !typing && gfx::key_pressed("M") { muted = !muted; audio::set_voice(tune, if muted { 0.0 } else { mvol }, 0.0, 1.0); }
        if !typing && mode != GameMode.Join && gfx::key_pressed("T") { s.detailed_tex = if s.detailed_tex != 0 { 0 } else { 1 }; }
        let ndark = night_darkness(s);
        audio::set_voice(night_voice, if muted || mode == GameMode.Lobby { 0.0 } else { ndark * 0.45 }, 0.0, 1.0);
        ui::input_from_gfx(hud);
        ui::input_from_gfx(big);
        ui::input_from_gfx(panel);
        ui::input_from_gfx(menu);
        if frames >= 0 { sleep(0.016); }
        let bits: u16 = if frames >= 0 { bot(frame, if mode == GameMode.Join { 3 } else { 0 }) } else if typing { 0 as u16 } else { keys() };
        acc += if frames >= 0 { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.1) };
        if mode == GameMode.Lobby {
            acc = 0.0;
        } else if mode == GameMode.Join {
            if use_udp {
                loop {          // datagram snapshots join the WebSocket's in one stream
                    var from = 0;
                    let got = udp_recv(csock, rbuf[..], from);
                    if got < 0 { break; }
                    var f = State { .. };
                    if http::mail_value(rbuf[0..got], f) { qput(f); n_udp += 1; udp_rx_age = 0; }
                }
            }
            var got_snap = false;
            loop {
                let f, got = qpoll<State>();
                guard got else { break; }
                if f.tick <= lasttick { continue; }
                lasttick = f.tick;
                n_applied += 1;
                joined = true;
                got_snap = true;
                s = f;
                hear(prev, s, sfx, fx);
                prev = s;
            }
            // Reconcile once per frame against the newest snapshot (never against intermediate burst ticks).
            if got_snap {
                if s.over > 0 {
                    px = s.players[s.you].x;
                    py = s.players[s.you].y;
                    hist.resize(0);
                } else {
                    var c = s;
                    let back = min((seq - s.ack) & 65535, hist.len);
                    if c.players[s.you].life == Life.Alive {
                        for j in hist.len - back..hist.len { c.players[s.you].bits = hist[j]; step_player(c, s.you); }
                    } else if is_dead(c.players[s.you].life) {
                        for j in hist.len - back..hist.len { c.players[s.you].bits = hist[j]; step_dead(c, s.you); }
                    }
                    let ex = c.players[s.you].x - px;
                    let ey = c.players[s.you].y - py;
                    let err = abs(ex) + abs(ey);
                    if err > TILE { px = c.players[s.you].x; py = c.players[s.you].y; }
                    else if err > 2 {
                        let sx = if ex > 0 { max(1, ex / 4) } else if ex < 0 { min(-1, ex / 4) } else { 0 };
                        let sy = if ey > 0 { max(1, ey / 4) } else if ey < 0 { min(-1, ey / 4) } else { 0 };
                        px += sx;
                        py += sy;
                    }
                }
            }
            let l, gone = qpoll<Lost>();
            if gone { fx.lost = true; }
            // Predict our own player at 60 Hz and send redundant 8-tick UDP input packets at 60 Hz.
            while acc >= 1.0 / 60.0 {
                acc -= 1.0 / 60.0;
                if udp_rx_age < 999 { udp_rx_age += 1; }
                seq = (seq + 1) & 65535;
                if hist.len >= 240 { remove_at(hist, 0); }
                hist.push(bits);
                if joined && s.over == 0 {
                    var c = s;
                    c.players[s.you].x = px;
                    c.players[s.you].y = py;
                    c.players[s.you].bits = bits;
                    if c.players[s.you].life == Life.Alive { step_player(c, s.you); }
                    else if is_dead(c.players[s.you].life) { step_dead(c, s.you); }
                    px = c.players[s.you].x;
                    py = c.players[s.you].y;
                }
                qput(Pad { bits, seq });
                if use_udp && joined {
                    let cnt = min(8, hist.len);
                    var d: u8[>..] = [];
                    d.push(68);                                  // 'D': redundant 16-bit input ring packet
                    d.push(s.you);
                    d.push(if udp_rx_age < 45 { 1 } else { 0 }); // bidirectional UDP health bit
                    d.push((seq & 255) as u8);
                    d.push((seq >> 8) as u8);
                    d.push(cnt as u8);
                    for k in cnt {
                        let bk = hist[hist.len - 1 - k];
                        d.push((bk & 255) as u8);
                        d.push((bk >> 8) as u8);
                    }
                    udp_send(csock, d[..], hostpeer);
                }
            }
        } else {
            s.players[0].bits = bits;
            loop {
                let m, ok = qpoll<Msg>();
                guard ok else { break; }
                var reply = none;
                var is_leave = false;
                match m {
                    Input inp => { reply = inp.reply; },
                    Profile pr => { reply = pr.reply; },
                    Leave lv => { reply = lv.reply; is_leave = true; },
                }
                var who = -1;
                for i in 1..4 { if s.players[i].life != Life.Off && addr[i].key == reply.key { who = i; } }
                if who < 0 && !is_leave {
                    for i in 1..4 { if who < 0 && s.players[i].life == Life.Off { who = i; } }
                    if who >= 0 {
                        addr[who] = reply;
                        s.players[who].life = Life.Alive;
                        s.players[who].name.resize(0);
                        s.players[who].kind = default_kind(who);
                        s.players[who].wins = 0;
                        s.players[who].streak = 0;
                        s.players[who].kills = 0;
                        s.players[who].suicides = 0;
                        s.players[who].sheep_deaths = 0;
                        s.players[who].deaths = 0;
                        upeer[who] = -1;
                        uage[who] = 999;
                        uok[who] = false;
                        inp_max[who] = -1;
                        ack[who] = 0;
                        for k in 32 { inp_seq[who * 32 + k] = -1; }
                        reset_round(s, r);
                    }
                }
                if who < 0 { continue; }
                match m {
                    Leave lv => {
                        s.players[who].life = Life.Off;
                        upeer[who] = -1;
                        uage[who] = 999;
                        uok[who] = false;
                        inp_max[who] = -1;
                    },
                    Profile pr => {
                        s.players[who].name = pr.name;
                        s.players[who].kind = pr.kind;
                    },
                    Input inp => {
                        if uage[who] >= 30 {   // TCP carries input when UDP is not active
                            if inp_max[who] < 0 { ack[who] = (inp.seq - 1) & 65535; inp_max[who] = inp.seq; }
                            let df = (inp.seq - ack[who]) & 65535;
                            if df > 0 && df < 32 {
                                let sl = who * 32 + (inp.seq & 31);
                                inp_bits[sl] = inp.bits;
                                inp_seq[sl] = inp.seq;
                            }
                            if ((inp.seq - inp_max[who]) & 65535) < 32768 { inp_max[who] = inp.seq; }
                        }
                    },
                }
            }
            loop {          // datagrams: 'D' (16-bit bits), 'C' (8-bit bits), 'B' (legacy)
                var from = 0;
                let got = udp_recv(usock, rbuf[..], from);
                if got < 0 { break; }
                if got >= 8 && rbuf[0] == 68 {
                    let who = rbuf[1] as i64;
                    guard who >= 1 && who < 4 && s.players[who].life != Life.Off else { continue; }
                    let sq = (rbuf[3] as i64) | ((rbuf[4] as i64) << 8);
                    let cnt = min(8, min(rbuf[5] as i64, (got - 6) / 2));
                    n_udp += 1;
                    upeer[who] = from;
                    uage[who] = 0;
                    uok[who] = rbuf[2] != 0;
                    if inp_max[who] < 0 { ack[who] = (sq - 1) & 65535; inp_max[who] = sq; }
                    for k in cnt {
                        let sk = (sq - k) & 65535;
                        let df = (sk - ack[who]) & 65535;
                        if df > 0 && df < 32 {
                            let sl = who * 32 + (sk & 31);
                            inp_bits[sl] = (rbuf[6 + k * 2] as u16) | ((rbuf[7 + k * 2] as u16) << 8);
                            inp_seq[sl] = sk;
                        }
                    }
                    if ((sq - inp_max[who]) & 65535) < 32768 { inp_max[who] = sq; }
                } else if got >= 7 && rbuf[0] == 67 {
                    let who = rbuf[1] as i64;
                    guard who >= 1 && who < 4 && s.players[who].life != Life.Off else { continue; }
                    let sq = (rbuf[3] as i64) | ((rbuf[4] as i64) << 8);
                    let cnt = min(8, min(rbuf[5] as i64, got - 6));
                    n_udp += 1;
                    upeer[who] = from;
                    uage[who] = 0;
                    uok[who] = rbuf[2] != 0;
                    if inp_max[who] < 0 { ack[who] = (sq - 1) & 65535; inp_max[who] = sq; }
                    for k in cnt {
                        let sk = (sq - k) & 65535;
                        let df = (sk - ack[who]) & 65535;
                        if df > 0 && df < 32 {
                            let sl = who * 32 + (sk & 31);
                            inp_bits[sl] = rbuf[6 + k] as u16;
                            inp_seq[sl] = sk;
                        }
                    }
                    if ((sq - inp_max[who]) & 65535) < 32768 { inp_max[who] = sq; }
                } else if got >= 5 && rbuf[0] == 66 {
                    let who = rbuf[1] as i64;
                    guard who >= 1 && who < 4 && s.players[who].life != Life.Off else { continue; }
                    let sq = (rbuf[3] as i64) | ((rbuf[4] as i64) << 8);
                    n_udp += 1;
                    upeer[who] = from;
                    uage[who] = 0;
                    if inp_max[who] < 0 { ack[who] = (sq - 1) & 65535; inp_max[who] = sq; }
                    let df = (sq - ack[who]) & 65535;
                    if df > 0 && df < 32 {
                        let sl = who * 32 + (sq & 31);
                        inp_bits[sl] = rbuf[2] as u16;
                        inp_seq[sl] = sq;
                    }
                    if ((sq - inp_max[who]) & 65535) < 32768 { inp_max[who] = sq; }
                }
            }
            while acc >= 1.0 / 60.0 {
                acc -= 1.0 / 60.0;
                if s.over > 0 {
                    for i in 1..4 {
                        if s.players[i].life != Life.Off && inp_max[i] >= 0 {
                            ack[i] = inp_max[i];
                            let sl = i * 32 + (inp_max[i] & 31);
                            s.players[i].bits = if inp_seq[sl] == inp_max[i] { inp_bits[sl] } else { 0 };
                        }
                    }
                    tick(s, r, n);
                } else {
                    // Consume each client's inputs in exact seq order so ack always matches simulated movement.
                    for i in 1..4 {
                        guard s.players[i].life != Life.Off else { continue; }
                        if inp_max[i] < 0 { s.players[i].bits = 0; continue; }
                        var pend = (inp_max[i] - ack[i]) & 65535;
                        if pend >= 32768 { pend = 0; }
                        if pend > 24 { ack[i] = (inp_max[i] - 2) & 65535; pend = 2; }
                        var extra = min(3, max(0, pend - 2));
                        while extra > 0 {
                            let nsq = (ack[i] + 1) & 65535;
                            let sl = i * 32 + (nsq & 31);
                            let b = if inp_seq[sl] == nsq { inp_bits[sl] } else { s.players[i].bits };
                            s.players[i].bits = b;
                            ack[i] = nsq;
                            if s.players[i].life == Life.Alive { step_player(s, i); }
                            else if is_dead(s.players[i].life) { step_dead(s, i); }
                            extra -= 1;
                            pend -= 1;
                        }
                        if pend >= 1 {
                            let nsq = (ack[i] + 1) & 65535;
                            let sl = i * 32 + (nsq & 31);
                            let b = if inp_seq[sl] == nsq { inp_bits[sl] } else { s.players[i].bits };
                            s.players[i].bits = b;
                            ack[i] = nsq;
                        } else {
                            // Waiting on a delayed packet: do not move extra unacknowledged pixels.
                            s.players[i].bits = s.players[i].bits & HOLD;
                        }
                    }
                    tick(s, r, n);
                }
                n += 1;
                s.tick = n;
                for i in 1..4 {
                    guard s.players[i].life != Life.Off else { continue; }
                    var c = s;
                    c.you = i as u8;
                    c.ack = ack[i];
                    uage[i] += 1;
                    let send_udp = uage[i] < 30 && upeer[i] >= 0;
                    let bidir_udp = send_udp && uok[i];
                    if send_udp {
                        var one = [c];
                        var image: u8[>..] = [];
                        one.to_bytes(image);
                        udp_send(usock, image[..], upeer[i]);
                    }
                    if !bidir_udp || n % 30 == 0 {          // TCP carries 60 Hz until both directions of UDP are confirmed
                        if http::mail_send_value(addr[i], 0, c) == http::STALE {
                            s.players[i].life = Life.Off;
                            upeer[i] = -1;
                            uage[i] = 999;
                            uok[i] = false;
                            inp_max[i] = -1;
                        }
                    }
                }
            }
            hear(prev, s, sfx, fx);
            prev = s;
        }
        for i in 4 {
            let tgt = float2 { s.players[i].x as f32, s.players[i].y as f32 };
            if mode == GameMode.Join {
                if i == s.you { shown[i] = float2 { px as f32, py as f32 }; }
                else if abs(tgt.x - shown[i].x) + abs(tgt.y - shown[i].y) > TILE * 2.0 { shown[i] = tgt; }
                else { shown[i] = shown[i] + (tgt - shown[i]) * 0.4; }
            } else { shown[i] = tgt; }
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
                track = map_track(s.map);
                audio::stop(tune);
                tune = audio::play(songs[track], if muted { 0.0 } else { mvol }, 0.0, 1.0, true);
            }
        }
        // Record 30 Hz rolling ring buffer + per-kill replay clips for end-of-round reel & session archive.
        if mode != GameMode.Lobby && s.tick != last_rec_tick {
            if s.tick % 2 == 0 {
                last_rec_tick = s.tick;
                if s.over == 0 {
                    if ring.len >= 65 { remove_at(ring, 0); }
                    ring.push(s);
                }
                for i in 4 {
                    if prev_life[i] == Life.Alive && s.players[i].life != Life.Alive && prev_over_rec == 0 {
                        if rec_post > 0 && active_rec.frames.len > 0 {
                            if clips.len >= 32 { remove_at(clips, 0); if round_clip_start > 0 { round_clip_start -= 1; } }
                            clips.push(active_rec);
                            rec_post = 0;
                        }
                        active_rec = KillClip { round: s.round_num as i64, victim: i as u8, killer: s.last_kill_killer, cause: s.last_kill_cause, .. };
                        let kc = if s.last_kill_victim == (i as u8) { s.last_kill_cause } else { CAUSE_BOMB };
                        let kk = if s.last_kill_victim == (i as u8) { s.last_kill_killer as i64 } else { -1 };
                        format_kill_label(s, i, kk, kc, active_rec.label);
                        let start_f = max(0, ring.len - 40);
                        for ri in start_f..ring.len {
                            if active_rec.frames.len < 90 { active_rec.frames.push(ring[ri]); }
                        }
                        rec_post = 28;
                    }
                    prev_life[i] = s.players[i].life;
                }
                if rec_post > 0 {
                    if active_rec.frames.len < 90 { active_rec.frames.push(s); }
                    rec_post -= 1;
                    if rec_post == 0 {
                        if clips.len >= 32 { remove_at(clips, 0); if round_clip_start > 0 { round_clip_start -= 1; } }
                        clips.push(active_rec);
                    }
                }
                if prev_over_rec == 0 && s.over > 0 {
                    // Let the live explosion, audio, and black-sheep transformation play out (~1.6s) before starting the Kill Reel!
                    reel_wait = 48;
                }
                if reel_wait > 0 && s.over > 0 {
                    reel_wait -= 1;
                    if reel_wait == 0 {
                        if rec_post > 0 && active_rec.frames.len > 0 {
                            if clips.len >= 32 { remove_at(clips, 0); if round_clip_start > 0 { round_clip_start -= 1; } }
                            clips.push(active_rec);
                            rec_post = 0;
                        }
                        if frames < 0 && clips.len > round_clip_start && !single_watch {
                            reel_active = true;
                            reel_idx = round_clip_start;
                            reel_end = clips.len;
                            reel_f = 0;
                            reel_acc = 0.0;
                            reel_age = 0.0;
                        }
                    }
                }
                if prev_over_rec > 0 && s.over == 0 {
                    round_clip_start = clips.len;
                    ring.resize(0);
                    reel_active = false;
                    reel_wait = 0;
                }
                prev_over_rec = s.over;
            }
        }
        let draw_mode = match mode {
            Lobby => "lobby",
            Solo => "solo",
            Host => "host",
            Join => if use_udp && udp_rx_age < 45 { "udp" } else { "join" },
        };
        let sz = gfx::screen_size();
        let vw = (sz.x as f32) / sc;
        let vh = (sz.y as f32) / sc;
        if single_watch && watch_clip.frames.len > 0 {
            let rf = min(watch_clip.frames.len - 1, reel_f);
            var rs = watch_clip.frames[rf];
            var rshown: float2[4] = [z, z, z, z];
            for i in 4 { rshown[i] = float2 { rs.players[i].x as f32, rs.players[i].y as f32 }; }
            var rfx = Fx { .. };
            draw(hud, big, rs, rshown, rfx, draw_mode, sc, atlas, reel_age as f32);
            if ui::begin(panel, "ReplayBar", ui::rect(14.0, vh - 56.0, vw - 28.0, 44.0), ui::WINDOW_NO_SCROLLBAR) {
                var rtxt: u8[>..] = [];
                format(rtxt, "REPLAY (1/2x): ", watch_clip.label[..], "   [Space / Esc to close]");
                ui::layout_row_dynamic(panel, 32.0, 1);
                ui::label(panel, rtxt[..], ui::TEXT_CENTERED);
            }
            ui::end(panel);
            let rdt = min(gfx::delta_time(), 0.1);
            reel_age += rdt;
            reel_acc += rdt;
            while reel_acc >= 1.0 / 15.0 {
                reel_acc -= 1.0 / 15.0;
                reel_f += 1;
                if reel_f >= watch_clip.frames.len { reel_f = 0; }
            }
        } else if reel_active && reel_idx < reel_end && reel_idx < clips.len && clips[reel_idx].frames.len > 0 {
            let rf = min(clips[reel_idx].frames.len - 1, reel_f);
            var rs = clips[reel_idx].frames[rf];
            var rshown: float2[4] = [z, z, z, z];
            for i in 4 { rshown[i] = float2 { rs.players[i].x as f32, rs.players[i].y as f32 }; }
            var rfx = Fx { .. };
            draw(hud, big, rs, rshown, rfx, draw_mode, sc, atlas, reel_age as f32);
            if ui::begin(panel, "ReelBar", ui::rect(14.0, vh - 56.0, vw - 28.0, 44.0), ui::WINDOW_NO_SCROLLBAR) {
                var rtxt: u8[>..] = [];
                format(rtxt, "KILL REPLAY (1/2x) ", reel_idx - round_clip_start + 1, "/", reel_end - round_clip_start, " - ", clips[reel_idx].label[..], "  [Space: Skip]");
                ui::layout_row_dynamic(panel, 32.0, 1);
                ui::label(panel, rtxt[..], ui::TEXT_CENTERED);
            }
            ui::end(panel);
            let rdt = min(gfx::delta_time(), 0.1);
            reel_age += rdt;
            reel_acc += rdt;
            while reel_acc >= 1.0 / 15.0 {
                reel_acc -= 1.0 / 15.0;
                reel_f += 1;
                if reel_f >= clips[reel_idx].frames.len {
                    reel_idx += 1;
                    reel_f = 0;
                    reel_age = 0.0;
                    if reel_idx >= reel_end { reel_active = false; break; }
                }
            }
        } else {
            draw(hud, big, s, shown, fx, draw_mode, sc, atlas, -1.0);
        }
        if mode != GameMode.Lobby && !single_watch && !reel_active {
            let is_host_or_solo = mode != GameMode.Join;
            let bar_w: f32 = if is_host_or_solo { 440.0 } else { 300.0 };
            let bar_x = max(12.0, vw - bar_w - (if mode == GameMode.Join { 196.0 } else { 152.0 }));
            if ui::begin(panel, "Bar", ui::rect(bar_x, 5.0, bar_w, 40.0), ui::WINDOW_NO_SCROLLBAR) {
                if is_host_or_solo {
                    let rat: f32[4] = [0.22, 0.22, 0.24, 0.32];
                    ui::layout_row(panel, ui::DYNAMIC, 32.0, rat);
                    if ui::button_label(panel, "Stats") { stats_open = !stats_open; if stats_open { menu_open = false; host_open = false; replays_open = false; } }
                    if ui::button_label(panel, "Replays") {
                        replays_open = !replays_open;
                        if replays_open {
                            menu_open = false; host_open = false; stats_open = false;
                            saved_list.resize(0);
                            var rd: u8[>..] = [];
                            if replays_dir(rd) { list_dir(rd[..], saved_list); }
                        }
                    }
                    if ui::button_label(panel, "Profile") { menu_open = !menu_open; if menu_open { host_open = false; stats_open = false; replays_open = false; } }
                    if ui::button_label(panel, "Host Settings") { host_open = !host_open; if host_open { menu_open = false; stats_open = false; replays_open = false; } }
                } else {
                    let rat: f32[3] = [0.30, 0.36, 0.34];
                    ui::layout_row(panel, ui::DYNAMIC, 32.0, rat);
                    if ui::button_label(panel, "Stats") { stats_open = !stats_open; if stats_open { menu_open = false; replays_open = false; } }
                    if ui::button_label(panel, "Replays") {
                        replays_open = !replays_open;
                        if replays_open {
                            menu_open = false; stats_open = false;
                            saved_list.resize(0);
                            var rd: u8[>..] = [];
                            if replays_dir(rd) { list_dir(rd[..], saved_list); }
                        }
                    }
                    if ui::button_label(panel, "Profile") { menu_open = !menu_open; if menu_open { stats_open = false; replays_open = false; } }
                }
            }
            ui::end(panel);
        }
        if stats_open && mode != GameMode.Lobby {
            let sw: f32 = min(680.0, vw - 24.0);
            let sh: f32 = min(330.0, vh - 24.0);
            if ui::begin(menu, "Session Kill & Suicide Stats (Tab)", ui::rect((vw - sw) * 0.5, (vh - sh) * 0.5, sw, sh), ui::WINDOW_BORDER | ui::WINDOW_TITLE | ui::WINDOW_NO_SCROLLBAR) {
                let srat: f32[7] = [0.24, 0.12, 0.12, 0.12, 0.14, 0.14, 0.12];
                ui::layout_row(menu, ui::DYNAMIC, 30.0, srat);
                ui::label(menu, "Player", ui::TEXT_LEFT);
                ui::label(menu, "Wins", ui::TEXT_CENTERED);
                ui::label(menu, "Streak", ui::TEXT_CENTERED);
                ui::label(menu, "Kills", ui::TEXT_CENTERED);
                ui::label(menu, "Suicides", ui::TEXT_CENTERED);
                ui::label(menu, "Sheep", ui::TEXT_CENTERED);
                ui::label(menu, "Deaths", ui::TEXT_CENTERED);
                for i in 4 {
                    if s.players[i].life == Life.Off { continue; }
                    var nm: u8[>..] = [];
                    player_name(s, i, nm);
                    ui::layout_row(menu, ui::DYNAMIC, 32.0, srat);
                    ui::label(menu, nm[..], ui::TEXT_LEFT);
                    var b0: u8[>..] = []; format(b0, s.players[i].wins); ui::label(menu, b0[..], ui::TEXT_CENTERED);
                    var b1: u8[>..] = []; format(b1, s.players[i].streak); ui::label(menu, b1[..], ui::TEXT_CENTERED);
                    var b2: u8[>..] = []; format(b2, s.players[i].kills); ui::label(menu, b2[..], ui::TEXT_CENTERED);
                    var b3: u8[>..] = []; format(b3, s.players[i].suicides); ui::label(menu, b3[..], ui::TEXT_CENTERED);
                    var b4: u8[>..] = []; format(b4, s.players[i].sheep_deaths); ui::label(menu, b4[..], ui::TEXT_CENTERED);
                    var b5: u8[>..] = []; format(b5, s.players[i].deaths); ui::label(menu, b5[..], ui::TEXT_CENTERED);
                }
                ui::layout_row_dynamic(menu, 38.0, 1);
                if ui::button_label(menu, "Close") { stats_open = false; }
            }
            ui::end(menu);
        }
        if replays_open && mode != GameMode.Lobby {
            let rw: f32 = min(680.0, vw - 24.0);
            let rh: f32 = min(560.0, vh - 24.0);
            if ui::begin(menu, "Session Kill Replays", ui::rect((vw - rw) * 0.5, (vh - rh) * 0.5, rw, rh), ui::WINDOW_BORDER | ui::WINDOW_TITLE) {
                let top_rat: f32[3] = [0.52, 0.24, 0.24];
                ui::layout_row(menu, ui::DYNAMIC, 34.0, top_rat);
                var hdr: u8[>..] = [];
                format(hdr, "Session Kills (", clips.len, "):");
                ui::label(menu, hdr[..], ui::TEXT_LEFT);
                if ui::button_label(menu, "Save All") {
                    var ok_n = 0;
                    for ci in clips.len { if save_kill_clip(clips[ci], ci + 1) { ok_n += 1; } }
                    replay_msg.resize(0);
                    var tmp: u8[>..] = [];
                    format(tmp, "Saved ", ok_n, " replays to ~/.bomberman/replays/");
                    for k in min(80, tmp.len) { replay_msg.push(tmp[k]); }
                    saved_list.resize(0);
                    var rd: u8[>..] = [];
                    if replays_dir(rd) { list_dir(rd[..], saved_list); }
                }
                if ui::button_label(menu, "Close") { replays_open = false; }
                if replay_msg.len > 0 {
                    ui::layout_row_dynamic(menu, 24.0, 1);
                    ui::label(menu, replay_msg[..], ui::TEXT_LEFT);
                }
                let crat: f32[3] = [0.64, 0.18, 0.18];
                if clips.len == 0 {
                    ui::layout_row_dynamic(menu, 28.0, 1);
                    ui::label(menu, "No kills recorded yet this session.", ui::TEXT_LEFT);
                }
                for ci in clips.len {
                    ui::layout_row(menu, ui::DYNAMIC, 32.0, crat);
                    ui::label(menu, clips[ci].label[..], ui::TEXT_LEFT);
                    if ui::button_label(menu, "Watch") {
                        watch_clip = clips[ci];
                        single_watch = true;
                        reel_f = 0;
                        reel_acc = 0.0;
                        reel_age = 0.0;
                        replays_open = false;
                    }
                    if ui::button_label(menu, "Save") {
                        let ok = save_kill_clip(clips[ci], ci + 1);
                        replay_msg.resize(0);
                        let m = if ok { "Saved replay to ~/.bomberman/replays/" } else { "Failed to save replay" };
                        for k in min(80, m.len) { replay_msg.push(m[k]); }
                        saved_list.resize(0);
                        var rd: u8[>..] = [];
                        if replays_dir(rd) { list_dir(rd[..], saved_list); }
                    }
                }
                ui::layout_row_dynamic(menu, 28.0, 1);
                ui::label(menu, "--- Saved Replays on Disk (~/.bomberman/replays/) ---", ui::TEXT_LEFT);
                let frat: f32[2] = [0.76, 0.24];
                var lstart = 0;
                var any_saved = false;
                for li in saved_list.len + 1 {
                    if li == saved_list.len || saved_list[li] == 10 {
                        let fname = saved_list[lstart..li];
                        if fname.len > 5 && fname[fname.len - 5] == 46 && fname[fname.len - 4] == 98 {
                            any_saved = true;
                            ui::layout_row(menu, ui::DYNAMIC, 32.0, frat);
                            ui::label(menu, fname, ui::TEXT_LEFT);
                            if ui::button_label(menu, "Watch") {
                                var lc = KillClip { .. };
                                if load_kill_clip(fname, lc) && lc.frames.len > 0 {
                                    watch_clip = lc;
                                    single_watch = true;
                                    reel_f = 0;
                                    reel_acc = 0.0;
                                    reel_age = 0.0;
                                    replays_open = false;
                                }
                            }
                        }
                        lstart = li + 1;
                    }
                }
                if !any_saved {
                    ui::layout_row_dynamic(menu, 26.0, 1);
                    ui::label(menu, "No saved .brep files yet.", ui::TEXT_LEFT);
                }
            }
            ui::end(menu);
        }
        if mode == GameMode.Lobby {
            let lw: f32 = min(650.0, vw - 24.0);
            let lh: f32 = min(650.0, vh - 24.0);
            if ui::begin(menu, "Goose Bomberman", ui::rect((vw - lw) * 0.5, (vh - lh) * 0.5, lw, lh), ui::WINDOW_BORDER | ui::WINDOW_TITLE) {
                let nrat: f32[2] = [0.24, 0.76];
                ui::layout_row(menu, ui::DYNAMIC, 36.0, nrat);
                ui::label(menu, "Your Name:", ui::TEXT_LEFT);
                ui::edit_string(menu, ui::EDIT_FIELD, my_name, ui::FILTER_ASCII);
                ui::layout_row_dynamic(menu, 30.0, 3);
                if ui::option_label(menu, "Goose", my_kind == Character.Goose) { my_kind = Character.Goose; }
                if ui::option_label(menu, "Squirrel", my_kind == Character.Squirrel) { my_kind = Character.Squirrel; }
                if ui::option_label(menu, "Baby", my_kind == Character.Baby) { my_kind = Character.Baby; }
                ui::layout_row_dynamic(menu, 30.0, 3);
                if ui::option_label(menu, "Cow", my_kind == Character.Cow) { my_kind = Character.Cow; }
                if ui::option_label(menu, "Pig", my_kind == Character.Pig) { my_kind = Character.Pig; }
                if ui::option_label(menu, "Farmer", my_kind == Character.Farmer) { my_kind = Character.Farmer; }

                ui::layout_row_dynamic(menu, 42.0, 1);
                if ui::button_label(menu, "Play Solo") {
                    s.players[0].name = my_name;
                    s.players[0].kind = my_kind;
                    mode = GameMode.Solo;
                    if frames < 0 { save_prefs(my_name[..], my_kind, join_addr[..], playit_addr[..]); }
                }

                ui::layout_row_dynamic(menu, 26.0, 1);
                ui::label(menu, "--- Join a Friend's Game ---", ui::TEXT_LEFT);
                let jrat: f32[2] = [0.72, 0.28];
                ui::layout_row(menu, ui::DYNAMIC, 38.0, jrat);
                let jed = ui::edit_string(menu, ui::EDIT_FIELD | ui::EDIT_SIG_ENTER, join_addr, ui::FILTER_ASCII);
                let do_join = ui::button_label(menu, "Join Game") || (jed & ui::EDIT_COMMITTED) != 0;
                ui::layout_row_dynamic(menu, 26.0, 1);
                ui::checkbox_label(menu, "Force TCP only (default: fast UDP + TCP fallback)", force_tcp);
                if do_join {
                    var test_host: u8[..96] = [];
                    parse_host_port(join_addr[..], test_host, 8080);
                    if test_host.len == 0 {
                        lobby_err.resize(0);
                        let em = "Enter a host IP or host:port (e.g. 10.0.0.5 or foo.ply.gg:12345)";
                        for k in min(96, em.len) { lobby_err.push(em[k]); }
                    } else {
                        lobby_err.resize(0);
                        start_join = true;
                    }
                }
                if lobby_err.len > 0 {
                    ui::layout_row_dynamic(menu, 24.0, 1);
                    ui::label(menu, lobby_err[..], ui::TEXT_LEFT);
                }

                ui::layout_row_dynamic(menu, 26.0, 1);
                ui::label(menu, "--- Host a Game (Choose Networking Method) ---", ui::TEXT_LEFT);
                ui::layout_row_dynamic(menu, 32.0, 3);
                if ui::option_label(menu, "LAN / Tailscale", host_net == HostNet.Lan) { host_net = HostNet.Lan; }
                if ui::option_label(menu, "UPnP Port-Fwd", host_net == HostNet.Upnp) { host_net = HostNet.Upnp; }
                if ui::option_label(menu, "playit.gg", host_net == HostNet.Playit) { host_net = HostNet.Playit; }
                if host_net == HostNet.Playit {
                    let prat2: f32[2] = [0.34, 0.66];
                    ui::layout_row(menu, ui::DYNAMIC, 36.0, prat2);
                    ui::label(menu, "playit.gg addr:", ui::TEXT_LEFT);
                    ui::edit_string(menu, ui::EDIT_FIELD, playit_addr, ui::FILTER_ASCII);
                    ui::layout_row_dynamic(menu, 24.0, 1);
                    ui::label(menu, "Point a playit.gg TCP+UDP tunnel to local port below.", ui::TEXT_LEFT);
                } else if host_net == HostNet.Upnp {
                    ui::layout_row_dynamic(menu, 24.0, 1);
                    ui::label(menu, "Auto-opens router port via UPnP/NAT-PMP (closed on exit).", ui::TEXT_LEFT);
                } else {
                    ui::layout_row_dynamic(menu, 24.0, 1);
                    var lnote: u8[>..] = [];
                    format(lnote, "Local IP: ", lan_ip[..], " (same Wi-Fi, Tailscale, or manual port-fwd)");
                    ui::label(menu, lnote[..], ui::TEXT_LEFT);
                }
                let hrat: f32[3] = [0.16, 0.24, 0.60];
                ui::layout_row(menu, ui::DYNAMIC, 40.0, hrat);
                ui::label(menu, "Port:", ui::TEXT_LEFT);
                ui::edit_string(menu, ui::EDIT_FIELD, port_str, ui::FILTER_ASCII);
                if ui::button_label(menu, "Start Hosting") {
                    host_port = parse_port(port_str[..], 8080);
                    port_str.resize(0);
                    format(port_str, host_port);
                    start_host = true;
                }
            }
            ui::end(menu);
        }
        if host_open && (mode == GameMode.Host || mode == GameMode.Solo) {
            let hw: f32 = min(650.0, vw - 24.0);
            let hh: f32 = min(660.0, vh - 24.0);
            if ui::begin(menu, "Host Settings", ui::rect((vw - hw) * 0.5, (vh - hh) * 0.5, hw, hh), ui::WINDOW_BORDER | ui::WINDOW_TITLE) {
                if mode == GameMode.Host {
                    ui::layout_row_dynamic(menu, 28.0, 1);
                    ui::label(menu, "Server Networking (switch anytime):", ui::TEXT_LEFT);
                    let prev_net = host_net;
                    ui::layout_row_dynamic(menu, 32.0, 3);
                    if ui::option_label(menu, "LAN / Tailscale", host_net == HostNet.Lan) { host_net = HostNet.Lan; }
                    if ui::option_label(menu, "UPnP Port-Fwd", host_net == HostNet.Upnp) { host_net = HostNet.Upnp; }
                    if ui::option_label(menu, "playit.gg", host_net == HostNet.Playit) { host_net = HostNet.Playit; }
                    if host_net != prev_net {
                        if host_net == HostNet.Upnp && !upnp_busy && !upnp_mapped {
                            upnp_busy = true;
                            upnp_status.resize(0);
                            let st = "Mapping port via UPnP / NAT-PMP...";
                            for k in st.len { upnp_status.push(st[k]); }
                            thread_spawn(upnp_worker, UpnpReq { port: host_port, enable: true });
                        } else if prev_net == HostNet.Upnp && upnp_mapped && !upnp_busy {
                            upnp_busy = true;
                            upnp_status.resize(0);
                            let st = "Closing router port mapping...";
                            for k in st.len { upnp_status.push(st[k]); }
                            thread_spawn(upnp_worker, UpnpReq { port: host_port, enable: false });
                        }
                    }
                    if host_net == HostNet.Playit {
                        let prat3: f32[2] = [0.34, 0.66];
                        ui::layout_row(menu, ui::DYNAMIC, 34.0, prat3);
                        ui::label(menu, "playit.gg addr:", ui::TEXT_LEFT);
                        ui::edit_string(menu, ui::EDIT_FIELD, playit_addr, ui::FILTER_ASCII);
                    }
                    var share_line: u8[>..] = [];
                    var disp: u8[>..] = [];
                    match host_net {
                        Lan => {
                            format_host_port(lan_ip[..], host_port, disp);
                            format(share_line, "Join address (LAN): ", disp[..]);
                        },
                        Upnp => {
                            if upnp_mapped && upnp_code == 0 && upnp_ip.len > 0 {
                                format_host_port(upnp_ip[..], host_port, disp);
                                format(share_line, "Public Join address: ", disp[..]);
                            } else {
                                format_host_port(lan_ip[..], host_port, disp);
                                format(share_line, "LAN fallback: ", disp[..]);
                            }
                        },
                        Playit => {
                            if playit_addr.len > 0 { format(share_line, "playit.gg Join: ", playit_addr[..]); }
                            else { format(share_line, "Point playit.gg TCP+UDP tunnel -> localhost:", host_port); }
                        },
                    }
                    ui::layout_row_dynamic(menu, 26.0, 1);
                    ui::label(menu, share_line[..], ui::TEXT_LEFT);
                    if upnp_status.len > 0 {
                        ui::layout_row_dynamic(menu, 24.0, 1);
                        ui::label(menu, upnp_status[..], ui::TEXT_LEFT);
                    }
                }
                ui::layout_row_dynamic(menu, 28.0, 1);
                ui::label(menu, "Game Mode:", ui::TEXT_LEFT);
                let prev_mm = s.match_mode;
                ui::layout_row_dynamic(menu, 32.0, 4);
                if ui::option_label(menu, "FFA", s.match_mode == MatchMode.FreeForAll) { s.match_mode = MatchMode.FreeForAll; }
                if ui::option_label(menu, "2v2 Teams", s.match_mode == MatchMode.Teams2v2) { s.match_mode = MatchMode.Teams2v2; }
                if ui::option_label(menu, "Prey", s.match_mode == MatchMode.Prey) { s.match_mode = MatchMode.Prey; }
                if ui::option_label(menu, "Predator", s.match_mode == MatchMode.Predator) { s.match_mode = MatchMode.Predator; }
                if s.match_mode != prev_mm { reset_round(s, r); }
                if s.match_mode == MatchMode.Teams2v2 {
                    ui::layout_row_dynamic(menu, 28.0, 1);
                    var ff_on = s.friendly_fire != 0;
                    if ui::checkbox_label(menu, "2v2 Friendly Fire (teammates can bomb each other)", ff_on) {
                        s.friendly_fire = if ff_on { 1 } else { 0 };
                    }
                }
                ui::layout_row_dynamic(menu, 28.0, 1);
                ui::label(menu, "Map (changes music & theme):", ui::TEXT_LEFT);
                let prev_map = s.map;
                ui::layout_row_dynamic(menu, 32.0, 3);
                if ui::option_label(menu, "Island", s.map == Map.Island) { s.map = Map.Island; }
                if ui::option_label(menu, "Forest", s.map == Map.Forest) { s.map = Map.Forest; }
                if ui::option_label(menu, "Mountains", s.map == Map.Mountains) { s.map = Map.Mountains; }
                ui::layout_row_dynamic(menu, 32.0, 2);
                if ui::option_label(menu, "Desert", s.map == Map.Desert) { s.map = Map.Desert; }
                if ui::option_label(menu, "Sandbox (All Items)", s.map == Map.Sandbox) { s.map = Map.Sandbox; }
                if s.map != prev_map { reset_round(s, r); }
                ui::layout_row_dynamic(menu, 28.0, 1);
                var dlbl: u8[>..] = [];
                format(dlbl, "Power-Up Drop Rate: ", s.drops, "%");
                ui::label(menu, dlbl, ui::TEXT_LEFT);
                ui::layout_row_dynamic(menu, 26.0, 1);
                s.drops = ui::slide_int(menu, 0, s.drops as i64, 100, 1) as u8;
                ui::layout_row_dynamic(menu, 28.0, 1);
                var rlbl: u8[>..] = [];
                if s.regrow == 0 { rlbl.append("Wall Regrowth when Empty: OFF"); }
                else { format(rlbl, "Wall Regrowth when Empty: ", s.regrow, "%"); }
                ui::label(menu, rlbl, ui::TEXT_LEFT);
                ui::layout_row_dynamic(menu, 26.0, 1);
                s.regrow = ui::slide_int(menu, 0, s.regrow as i64, 100, 5) as u8;
                // Bomb & Fire Tuning: sliders + per-bomb randomize toggles
                let trat: f32[2] = [0.70, 0.30];
                ui::layout_row(menu, ui::DYNAMIC, 28.0, trat);
                var flbl: u8[>..] = [];
                let fs_tenths = (s.fuse_ticks as i64) * 10 / 60;
                format(flbl, "Bomb Fuse Wait: ", fs_tenths / 10, ".", fs_tenths % 10, "s");
                ui::label(menu, flbl, ui::TEXT_LEFT);
                var fr_on = s.fuse_rand != 0;
                if ui::checkbox_label(menu, "Randomize", fr_on) { s.fuse_rand = if fr_on { 1 } else { 0 }; }
                ui::layout_row_dynamic(menu, 26.0, 1);
                s.fuse_ticks = ui::slide_int(menu, 30, s.fuse_ticks as i64, 300, 15) as u16;

                ui::layout_row(menu, ui::DYNAMIC, 28.0, trat);
                var fdlbl: u8[>..] = [];
                let fd_tenths = max(1, (s.fire_ticks as i64) / 8) * 160 / 60;
                format(fdlbl, "Fire Duration: ", fd_tenths / 10, ".", fd_tenths % 10, "s");
                ui::label(menu, fdlbl, ui::TEXT_LEFT);
                var fdr_on = s.fire_rand != 0;
                if ui::checkbox_label(menu, "Randomize", fdr_on) { s.fire_rand = if fdr_on { 1 } else { 0 }; }
                ui::layout_row_dynamic(menu, 26.0, 1);
                s.fire_ticks = ui::slide_int(menu, 8, s.fire_ticks as i64, 48, 8) as u8;

                ui::layout_row(menu, ui::DYNAMIC, 28.0, trat);
                var erlbl: u8[>..] = [];
                format(erlbl, "Base Fire Extent: ", s.fire_range, " tiles");
                ui::label(menu, erlbl, ui::TEXT_LEFT);
                var rr_on = s.range_rand != 0;
                if ui::checkbox_label(menu, "Randomize", rr_on) { s.range_rand = if rr_on { 1 } else { 0 }; }
                ui::layout_row_dynamic(menu, 26.0, 1);
                let prev_rng = s.fire_range;
                s.fire_range = ui::slide_int(menu, 1, s.fire_range as i64, 6, 1) as u8;
                if s.fire_range != prev_rng {
                    for i in 4 {
                        if s.players[i].life != Life.Off {
                            let adj = (s.players[i].range as i64) + (s.fire_range as i64) - (prev_rng as i64);
                            s.players[i].range = max(1, min(12, adj)) as u8;
                        }
                    }
                }
                let prat: f32[4] = [0.40, 0.18, 0.24, 0.18];
                ui::layout_row(menu, ui::DYNAMIC, 34.0, prat);
                ui::label(menu, "Enabled Power-Ups:", ui::TEXT_LEFT);
                if ui::button_label(menu, "All") { s.power_mask = PWR_ALL; }
                if ui::button_label(menu, "Classic") { s.power_mask = PWR_CLASSIC; }
                if ui::button_label(menu, "None") { s.power_mask = 0; }
                var p0 = (s.power_mask & PWR_FLAME) != 0;
                var p1 = (s.power_mask & PWR_BOMB) != 0;
                var p2 = (s.power_mask & PWR_SPEED) != 0;
                var p3 = (s.power_mask & PWR_GHOST) != 0;
                var p4 = (s.power_mask & PWR_KICK) != 0;
                var p5 = (s.power_mask & PWR_MISSILE) != 0;
                var p6 = (s.power_mask & PWR_NAPALM) != 0;
                var p7 = (s.power_mask & PWR_MINES) != 0;
                var p8 = (s.power_mask & PWR_DRUNK) != 0;
                var p9 = (s.power_mask & PWR_BAD) != 0;
                var p10 = (s.power_mask & PWR_UNKICK) != 0;
                var p11 = (s.power_mask & PWR_BUILD) != 0;
                var p12 = (s.power_mask & PWR_DIRBOMB) != 0;
                var p13 = (s.power_mask & PWR_FLAMER) != 0;
                var p14 = (s.power_mask & PWR_FIREBALL) != 0;
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Flame (Range+)", p0);
                ui::checkbox_label(menu, "Extra Bomb", p1);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Speed Bolt", p2);
                ui::checkbox_label(menu, "Ghost (Invisible)", p3);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Kick Boot", p4);
                ui::checkbox_label(menu, "Heat-Seeker Missile", p5);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Napalm Fire Trail", p6);
                ui::checkbox_label(menu, "Proximity Mines", p7);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Drunk (All + Jitter)", p8);
                ui::checkbox_label(menu, "Curse (Slow + Range)", p9);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Unkickable Bombs", p10);
                ui::checkbox_label(menu, "Builder Kit (Q/Shift+Q)", p11);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Directional Bombs", p12);
                ui::checkbox_label(menu, "Flamethrower (F)", p13);
                ui::layout_row_dynamic(menu, 30.0, 2);
                ui::checkbox_label(menu, "Fireball Thrower (F)", p14);
                var p_on = s.portals_on != 0;
                if ui::checkbox_label(menu, "Portals Enabled", p_on) {
                    s.portals_on = if p_on { 1 } else { 0 };
                    if s.portals_on != 0 {
                        s.grid[(s.portals[1] as i64) * W + (s.portals[0] as i64)] = 0;
                        s.grid[(s.portals[3] as i64) * W + (s.portals[2] as i64)] = 0;
                    }
                }
                ui::layout_row_dynamic(menu, 30.0, 2);
                var dn_on = s.day_night_on != 0;
                if ui::checkbox_label(menu, "Day/Night Cycle", dn_on) {
                    s.day_night_on = if dn_on { 1 } else { 0 };
                    if s.day_night_on == 0 { s.day_phase = 0; }
                }
                var dt_on = s.detailed_tex != 0;
                if ui::checkbox_label(menu, "Detailed Textures (T)", dt_on) {
                    s.detailed_tex = if dt_on { 1 } else { 0 };
                }
                var nm: u32 = 0;
                if p0 { nm |= PWR_FLAME; }
                if p1 { nm |= PWR_BOMB; }
                if p2 { nm |= PWR_SPEED; }
                if p3 { nm |= PWR_GHOST; }
                if p4 { nm |= PWR_KICK; }
                if p5 { nm |= PWR_MISSILE; }
                if p6 { nm |= PWR_NAPALM; }
                if p7 { nm |= PWR_MINES; }
                if p8 { nm |= PWR_DRUNK; }
                if p9 { nm |= PWR_BAD; }
                if p10 { nm |= PWR_UNKICK; }
                if p11 { nm |= PWR_BUILD; }
                if p12 { nm |= PWR_DIRBOMB; }
                if p13 { nm |= PWR_FLAMER; }
                if p14 { nm |= PWR_FIREBALL; }
                s.power_mask = nm;
                ui::layout_row_dynamic(menu, 38.0, 2);
                if ui::button_label(menu, "New Round") { reset_round(s, r); host_open = false; }
                if ui::button_label(menu, "Close") {
                    host_open = false;
                    if frames < 0 { save_prefs(my_name[..], my_kind, join_addr[..], playit_addr[..]); }
                }
            }
            ui::end(menu);
        }
        if menu_open && mode != GameMode.Lobby {
            let mw: f32 = min(560.0, vw - 24.0);
            let mh: f32 = min(400.0, vh - 24.0);
            if ui::begin(menu, "Player Setup", ui::rect((vw - mw) * 0.5, (vh - mh) * 0.5, mw, mh), ui::WINDOW_BORDER | ui::WINDOW_TITLE | ui::WINDOW_NO_SCROLLBAR) {
                ui::layout_row_dynamic(menu, 28.0, 1);
                ui::label(menu, "Your Name (max 12 chars):", ui::TEXT_LEFT);
                ui::layout_row_dynamic(menu, 40.0, 1);
                let ed = ui::edit_string(menu, ui::EDIT_FIELD | ui::EDIT_SIG_ENTER, my_name, ui::FILTER_ASCII);
                ui::layout_row_dynamic(menu, 28.0, 1);
                ui::label(menu, "Pick your Farm Character:", ui::TEXT_LEFT);
                let prev_kind = my_kind;
                ui::layout_row_dynamic(menu, 36.0, 2);
                if ui::option_label(menu, "Goose (Eggs)", my_kind == Character.Goose) { my_kind = Character.Goose; }
                if ui::option_label(menu, "Squirrel (Acorns)", my_kind == Character.Squirrel) { my_kind = Character.Squirrel; }
                ui::layout_row_dynamic(menu, 36.0, 2);
                if ui::option_label(menu, "Baby (Diapers)", my_kind == Character.Baby) { my_kind = Character.Baby; }
                if ui::option_label(menu, "Cow (Patties)", my_kind == Character.Cow) { my_kind = Character.Cow; }
                ui::layout_row_dynamic(menu, 36.0, 2);
                if ui::option_label(menu, "Pig (Bacon)", my_kind == Character.Pig) { my_kind = Character.Pig; }
                if ui::option_label(menu, "Farmer (Hay Bales)", my_kind == Character.Farmer) { my_kind = Character.Farmer; }
                let changed = my_kind != prev_kind;
                ui::layout_row_dynamic(menu, 42.0, 1);
                let done = ui::button_label(menu, "Play!") || (ed & ui::EDIT_COMMITTED) != 0;
                if mode == GameMode.Join {
                    if changed || (ed & ui::EDIT_ACTIVE) != 0 || done { qput(Profile { my_kind, my_name }); }
                } else {
                    s.players[0].name = my_name;
                    s.players[0].kind = my_kind;
                }
                if done {
                    menu_open = false;
                    if frames < 0 { save_prefs(my_name[..], my_kind, join_addr[..], playit_addr[..]); }
                }
            }
            ui::end(menu);
        }
        gfx::begin_screen(map_clear_color(s.map));
        gfx::end_pass();
        ui::render(hud);
        ui::render(big);
        ui::render(panel);
        ui::render(menu);
        let nsz = gfx::screen_size();
        let want_sc = max(1.0, min(3.5, min((nsz.x as f32) / 960.0, (nsz.y as f32) / 720.0)));
        if abs(want_sc - sc) > 0.05 {
            sc = want_sc;
            ui::set_scale(hud, sc);
            ui::set_scale(big, sc);
            ui::set_scale(panel, sc);
            ui::set_scale(menu, sc);
        }
        frame += 1;
    }
    if upnp_mapped { upnp_unmap(host_port); }
    for i in 4 { if s.players[i].life != Life.Off { print("player ", i, " at ", s.players[i].x / TILE, ",", s.players[i].y / TILE, " alive ", if s.players[i].life == Life.Alive { 1 } else { 0 }, " wins ", s.players[i].wins, " streak ", s.players[i].streak); } }
    if mode == GameMode.Host || mode == GameMode.Join { print("datagrams ", n_udp, ", snapshots applied ", n_applied); }
    ui::destroy(hud);
    ui::destroy(big);
    ui::destroy(panel);
    ui::destroy(menu);
    gfx::release(atlas);
    audio::close();
    gfx::close();
}
