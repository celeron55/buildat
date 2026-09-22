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
		env = {kick = 0, hat = 0, bass = 0},
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

	-- One block of samples, mixed and written
	function s:fill()
		local buf = self.buffer
		buf:Clear()
		local step_len = RATE * CYCLE / STEPS
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
			-- One delay line, on everything but the kick
			local d = self.delay[self.delay_i]
			local wet = hat * 0.5 + bass * 0.3
			self.delay[self.delay_i] = wet + d * 0.45
			self.delay_i = self.delay_i % self.delay_n + 1
			-- The mix, through a soft limiter: x/(1+|x|) never clips and
			-- needs no lookahead, which a room's bed does not miss
			local x = kick * 0.9 + hat * 0.35 + bass * 0.45 + drone + d * 0.35
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

-- The synth's own check: a block has to be the right length, its samples
-- have to be inside 16 bits, and a bar has to be a bar -- the kick's
-- pattern landing where the table says it does rather than wherever the
-- block boundaries fell.
function M.self_check(magic)
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
	return string.format("synth ok: %d samples a block, %d kicks in a bar, " ..
			"%.2f s buffered", BLOCK, #hits, s.stream.bufferLength)
end

return M
