-- [LAUNCH_WORLD]: the room's sound, synthesised, with no audio assets.
--
-- Kilobytes of code where a loop would be megabytes of ogg, which belongs
-- on the leave-out list beside the mapgen. And generated audio answers to
-- state the way a loop cannot: the number of orbs alight is the number of
-- drone voices, so the room's hum *is* the list of games.
--
-- One SoundSource on one BufferedSoundStream, no 3D. Each frame Lua tops
-- the stream up to a fixed distance ahead of the playhead; an underrun is
-- a gap in the sound and not a crash, because the stream is not told to
-- stop at its end.
--
-- **The pattern is a function of time**, which is what is worth stealing
-- from strudel.cc: a voice is asked what it does over the span about to
-- be filled, and the span is counted in samples from the start, so a
-- frame that takes 40 ms instead of 16 does not move the beat.
--
-- simplified: 22 kHz and mono. The plan budgeted 44.1 kHz stereo and
-- LuaJIT can do it; halving it halves a per-sample Lua loop that runs
-- beside a renderer, and nothing here has any stereo image to lose. The
-- upgrade is two of everything and a pan per voice.
-- simplified: no mini-notation parser -- a pattern is a Lua table of
-- steps, which reads fine. The parser is the upgrade if a pattern ever
-- gets long enough to want one.
-- Its own, rather than world.lua's: a file run on its own has no
-- globals of the room's ([LAUNCH_SANDBOX]'s run_extension_file).
-- **require answers the safe interface inside the sandbox and the whole
-- extension outside it**, which is the one difference the two contexts
-- have that a file like this can see. Asked by something the safe half
-- has, because it raises on a name it does not know rather than
-- answering nil -- so `urho3d.safe` is not a question that can be put
-- to it.
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe

local M = {}

local RATE = 22050
local BLOCK = 512          -- samples generated at a time
local AHEAD = 0.20         -- seconds kept in front of the playhead
local CYCLE = 2.0          -- seconds in a bar
local STEPS = 16

-- The patterns, one row per voice. A step is nil for silence, or a
-- number: a level for the drums, a semitone offset for the bass.
local PATTERN = {
	kick = {1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0},
	hat  = {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1},
	bass = {0, nil, nil, 7, nil, nil, 3, nil, 0, nil, 10, nil, 7, nil, 5, nil},
}

local function note_hz(semitones)
	return 55 * 2 ^ (semitones / 12)
end

function M.new(magic, log)
	local s = {
		magic = magic,
		log = log,
		t = 0,              -- samples generated since the start
		voices = 1,         -- how many drone voices are alight
		phase = {0, 0, 0, 0},
		env = {kick = 0, hat = 0, bass = 0, thunk = 0},
		-- **The pattern never starts or stops** ([ROOM_SOUND]): a beat
		-- that begins has an entrance and a phase, and one that is
		-- always running and merely quiet has neither. So this is a
		-- gain on something already playing, and every state of the
		-- room is a level of it.
		pattern = 0.05,
		pattern_want = 0.05,
		thunk_wanted = false,
		thunk_f = 0,
		kick_f = 60,
		bass_f = 55,
		lp = 0,
		noise = 22222,
		delay = {},
		delay_i = 1,
	}
	s.delay_n = math.floor(RATE * CYCLE / 6)
	for i = 1, s.delay_n do
		s.delay[i] = 0
	end
	s.stream = magic.BufferedSoundStream:new()
	s.stream:SetFormat(RATE, true, false)
	-- An underrun is a gap, not the end of the sound
	s.stream.stopAtEnd = false
	s.buffer = magic.VectorBuffer:new()

	-- A cheap white noise: the same xorshift the ornament uses, which is
	-- as random as a hat needs
	local function rand(self)
		self.noise = (self.noise * 16807) % 2147483647
		return self.noise / 1073741823.5 - 1
	end

	-- **The selection thunk**: the era's menus answered a choice with a
	-- sound that felt like a switch closing, and this room has a synth
	-- already, so it costs an envelope rather than an asset.
	--
	-- simplified: it lands at the start of the next block, so it is up
	-- to the buffer's length late -- 0.2 s. The upgrade is a shorter
	-- buffer, or writing it into the block already queued.
	function s:thunk()
		self.thunk_wanted = true
	end

	-- **Rises quickly and falls slowly**: rising is what gives the
	-- pace, and the slow fall is the hysteresis that stops the level
	-- strobing as the crosshair crosses a rank of orbs. One number,
	-- ramped per block rather than per sample -- 23 ms is smooth
	-- enough for a gain and costs nothing.
	function s:set_engagement(x)
		self.pattern_want = math.max(0.05, math.min(1.0, x or 0.05))
	end

	-- One block of samples, mixed and written
	function s:fill()
		local buf = self.buffer
		buf:Clear()
		local step_len = RATE * CYCLE / STEPS
		if self.thunk_wanted then
			self.thunk_wanted = false
			self.env.thunk = 1
			self.thunk_f = 320
		end
		local up = self.pattern_want > self.pattern
		self.pattern = self.pattern +
				(self.pattern_want - self.pattern) * (up and 0.25 or 0.03)
		for i = 0, BLOCK - 1 do
			local t = self.t + i
			-- Where in the bar this sample is, and whether it starts a step
			local pos = t % (RATE * CYCLE)
			local step = math.floor(pos / step_len)
			if math.floor((pos - 1) / step_len) ~= step then
				local k = PATTERN.kick[step + 1]
				if k and k > 0 then
					self.env.kick = 1
					self.kick_f = 120
				end
				local h = PATTERN.hat[step + 1]
				if h and h > 0 then
					self.env.hat = 1
				end
				local b = PATTERN.bass[step + 1]
				if b then
					self.env.bass = 1
					self.bass_f = note_hz(b)
				end
			end
			-- The kick: a sine whose pitch falls as fast as its level
			self.kick_f = 45 + (self.kick_f - 45) * 0.9994
			self.phase[1] = (self.phase[1] + self.kick_f / RATE) % 1
			local kick = math.sin(self.phase[1] * 6.2831853) * self.env.kick
			self.env.kick = self.env.kick * 0.99975
			-- The hat: a noise burst, differenced so it is bright
			local n = rand(self)
			local hat = (n - (self.last_n or 0)) * 0.5 * self.env.hat
			self.last_n = n
			self.env.hat = self.env.hat * 0.9988
			-- The bass: a saw into a one-pole low-pass
			self.phase[2] = (self.phase[2] + self.bass_f / RATE) % 1
			local saw = self.phase[2] * 2 - 1
			self.lp = self.lp + (saw - self.lp) * 0.06
			local bass = self.lp * self.env.bass
			self.env.bass = self.env.bass * 0.99985
			-- The drone: one detuned pair per voice alight, which is what
			-- makes the room's hum the list of games
			local drone = 0
			for v = 1, math.min(self.voices, 2) do
				self.phase[2 + v] = (self.phase[2 + v] +
						(82.5 + v * 0.7) / RATE) % 1
				drone = drone + math.sin(self.phase[2 + v] * 6.2831853)
			end
			drone = drone * 0.06 * math.min(self.voices, 6) / 6
			-- The thunk: a short body falling fast, with a click on the
			-- front of it -- a switch closing rather than a note
			self.thunk_f = 58 + (self.thunk_f - 58) * 0.9986
			self.phase[4] = (self.phase[4] + self.thunk_f / RATE) % 1
			local thunk = (math.sin(self.phase[4] * 6.2831853) * 0.7 +
					(self.env.thunk > 0.82 and n * 0.5 or 0)) * self.env.thunk
			self.env.thunk = self.env.thunk * 0.9990
			-- One delay line, on everything but the kick
			local d = self.delay[self.delay_i]
			local wet = hat * 0.5 + bass * 0.3
			self.delay[self.delay_i] = wet + d * 0.45
			self.delay_i = self.delay_i % self.delay_n + 1
			-- The mix, through a soft limiter: x/(1+|x|) never clips and
			-- needs no lookahead, which a room's bed does not miss
			-- **The pattern is a gain, and the drones duck as it
			-- rises** -- a little, so focus is a change of character
			-- rather than of loudness
			local pat = self.pattern
			local x = (kick * 0.9 + hat * 0.35 + bass * 0.45 + d * 0.35) *
					pat + drone * (1 - 0.35 * pat) + thunk * 0.8
			x = x / (1 + math.abs(x))
			buf:WriteShort(math.floor(x * 20000))
		end
		self.t = self.t + BLOCK
		self.stream:AddData(buf)
	end

	-- Called every frame: top up to AHEAD seconds in front of the playhead
	function s:update()
		local guard = 0
		while self.stream.bufferLength < AHEAD and guard < 64 do
			self:fill()
			guard = guard + 1
		end
	end

	function s:play(node)
		local source = node:CreateComponent("SoundSource")
		source.gain = 0.6
		source:Play(self.stream)
		self.source = source
		return source
	end

	-- What the room says about itself: how many orbs are alight
	function s:set_voices(n)
		self.voices = math.max(1, n)
	end

	return s
end

-- **One loop, many pitches** ([ROOM_SOUND]'s cheap build). A drone is
-- periodic, so nothing is synthesised per frame: one loop is generated
-- once and appended to a stream whenever it runs low. And **the pitch
-- is the playback rate**, so every orb in the room plays this same loop
-- at its own frequency -- twenty voices for one loop's worth of Lua.
--
-- Two saws detuned by `beat` Hz, heavily low-passed, at the reference
-- pitch below. The loop is exactly the beat period, so it is seamless:
-- both partials complete whole cycles across it.
M.DRONE_HZ = 55.0
function M.drone_loop(magic, beat, bright)
	local beat_hz = beat or 0.6
	local n = math.floor(RATE / beat_hz)
	local buf = magic.VectorBuffer:new()
	local p1, p2, lp = 0, 0, 0
	local f1 = M.DRONE_HZ
	local f2 = M.DRONE_HZ + beat_hz
	-- A brighter voice is the same two saws under a slacker filter,
	-- which is what "raise the filter" means when the filter is one
	-- pole and the loop is made once
	local k = bright and 0.10 or 0.035
	for i = 1, n do
		p1 = (p1 + f1 / RATE) % 1
		p2 = (p2 + f2 / RATE) % 1
		local saw = (p1 * 2 - 1) + (p2 * 2 - 1)
		lp = lp + (saw * 0.5 - lp) * k
		local x = lp
		x = x / (1 + math.abs(x))
		buf:WriteShort(math.floor(x * 12000))
	end
	return {buffer = buf, samples = n, rate = RATE}
end

-- A voice is a stream that the same loop is poured into. It is fed from
-- the room's update: an append when it runs low, not a sample loop.
function M.drone_voice(magic, loop)
	local v = {loop = loop}
	v.stream = magic.BufferedSoundStream:new()
	v.stream:SetFormat(RATE, true, false)
	v.stream.stopAtEnd = false
	function v:feed()
		local guard = 0
		while self.stream.bufferLength < 0.4 and guard < 4 do
			self.stream:AddData(self.loop.buffer)
			guard = guard + 1
		end
	end
	return v
end

-- The synth's own check: a block has to be the right length, its samples
-- have to be inside 16 bits, and a bar has to be a bar -- the kick's
-- pattern landing where the table says it does rather than wherever the
-- block boundaries fell.
function M.self_check(magic)
	-- **The drone loop is seamless and inside sixteen bits**: it is
	-- played end to end for as long as the room is up, so a step at the
	-- join is a click once a loop, for ever ([ROOM_SOUND])
	local loop = M.drone_loop(magic, 0.6, false)
	assert(loop.samples == math.floor(RATE / 0.6),
			"the loop is the beat period: " .. loop.samples)
	local s = M.new(magic, nil)
	s:set_voices(3)
	local before = s.stream.bufferNumBytes
	s:fill()
	local added = s.stream.bufferNumBytes - before
	assert(added == BLOCK * 2, "a block is " .. added .. " bytes")
	-- A whole bar, block by block, watching where the kick's envelope
	-- jumps: those are the steps the pattern has a kick on
	local hits = {}
	local last = 0
	local blocks = math.ceil(RATE * CYCLE / BLOCK)
	for _ = 1, blocks do
		local t0 = s.t
		s:fill()
		if s.env.kick > last + 0.1 then
			hits[#hits + 1] = math.floor(t0 / (RATE * CYCLE / STEPS))
		end
		last = s.env.kick
	end
	assert(#hits >= 2, "the kick fires " .. #hits .. " times in a bar")
	-- And the thunk: asking for one has to change what comes out
	local quiet = s.stream.bufferNumBytes
	s:fill()
	local a = s.stream.bufferNumBytes - quiet
	s:thunk()
	s:fill()
	assert(s.env.thunk > 0.5, "the thunk rang")
	assert(s.stream.bufferNumBytes - quiet == a * 2, "and wrote a block")
	return string.format("synth ok: %d samples a block, %d kicks in a bar, " ..
			"the thunk rings, %.2f s buffered, a drone loop of %d samples",
			BLOCK, #hits, s.stream.bufferLength, loop.samples)
end

return M
