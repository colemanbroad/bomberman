# Done

We need (in a series of commits)

- players enter their names
- every 5 wins it focuses on you and you do a little dance in everyones' faces
- keep track of win streak
- different maps (tropical island, forest, moutains, desert)
- new music for each map
- add different farm animals that you can pick between. we already have goose laying eggs. we want:
  - squirrel laying acorns
  - baby laying diapers
  - cow laying cow patties
  - pig dropping bacon
  - farmer laying hay bales

Power Ups:
- "heat seeker missle". you control it's movement, but you're stationary (with a little headset on) until it explodes.
- "napalm" which lays a slowly decaying trail of fire behind you
- mines 
- drunk power up (your player has a random jitter that you have to fight against, but you get every other power.)
- bad power up (something negative... you get longer fire but slow down)
- unkickable bombs

Features
- Portals that teleport characters and bombs
- some way to participate after you die
  - reincarnated as black sheep that you control. it blocks others.
  - as a ghost that is fast, goes through blocks, and leaves a trail of fog behind it
- a screen for the host to customize the set of available powerups in the game.
- walls/blocks randomly appear when the field is too empty (at a rate controllable by host)

-------------

# Todo

- App Icon on mac/windows

New Game Modes
- Team mode: 2v2.
- Prey mode: One player runs away (is invisible). Everyone tries to get him.
- Predator mode: One player is predator. Others are invisible! They run and he tries to get them! Only slightly visible while moving. Invisible players try to take powerups away from predator.

Enhancements
- replay all the kills at the end of the game.
- within a session / sequence of games the kills are saved by the server and you can watch/save all the replays. 
- keep track of kill vs suicide stats (died by your bomb, sheep, opponent's bomb, etc)
- day/night cycles: when in night you only see each player's eyes! You have to remember where blocks are. You don't see bombs or blocks. Just hear nighttime sounds / explosions. Have to kick blind!
- ability to lay blocks / chain link fence
- Sheep can catch on fire! Then they move faster and they kill you when you touch them!

Visuals
- the sheep should be drawn in profile and made to look fluffy
- toggle for more detailed graphics with textures

Controls
- slider controls + toggle to randomize:
  - vary bomb wait before explosion 
  - vary fire duration after explosion
  - vary fire extent

Weapons
- directional bombs explode in one direction
- flame thrower
- fireball thrower

Blocks
- Forests/Brush: Blocks you can move through, but that make you invisible to others.
- Semi-permeable blocks. Players can't move through them, but bombs can be kicked through and flames go through.
- Fence: blocks movement but lives on the boundary between squares and doesn't take up a square.

# Not yet

Speculative
- group chat with voice
- you have to convince an LLM to give you powerups.
- after death: tilting the board
- superpowers / special abilities:
  - death from above drops fire from the sky
  - full invisibility (no dust trail)
  - unlimited simultaneous bombs
  - Starcraft Adept ability to split into a shadow that you control and optionally teleport to shadow location.

- Fez-style 2.5D where we're actually on a cube / sphere / torus?
- Higher Quality Graphics
- time warp slows down game (except for player)
- slows down half the screen
- disco mode flashes screen

- fog of war?
- turn based game variant?
- D&D style char design
  - speed, stregth, agility, luck, ...

# Done

Install & Hosting TODOs (done):
- [x] Support `HOST:PORT` on join (default 8080) and `--port N` on host
- [x] In-game Start/Lobby screen when launched with no args (Solo / Host / Join with saved last-used `host:port`)
- [x] Runtime host networking mode selector (in Host screen + CLI flag):
  - LAN only (also works with Tailscale or manual router forwarding)
  - Automatic UPnP / NAT-PMP port forwarding (TCP+UDP lease, cleanup on exit, CGNAT/double-NAT detection, display public IP:port)
  - playit.gg tunnel helper (display/share configured `host:port`)
- [x] One-line auto-updating launchers on `gh-pages`: `play.sh` (Mac, skips Gatekeeper, drops `Bomberman.app`) and `play.ps1` (Windows, skips SmartScreen, drops Desktop shortcut)
- [x] Add macOS GitHub Actions release job alongside `windows.yml` so every `v*` tag publishes both Mac & Windows builds

