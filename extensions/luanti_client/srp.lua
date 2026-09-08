-- Buildat: extension/luanti_client/srp.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The client half of Luanti's login: SRP-6a with SHA-256 and the 2048-bit
-- group of RFC 5054. The password itself never goes to the server; what does
-- is A = g^a, and then a proof M that we know x = H(salt, H(name:password)).
--
--   x = H(salt | H(username : password))
--   k = H(PAD(N) | PAD(g)),  u = H(PAD(A) | PAD(B))
--   A = g^a mod N,  S = (B - k*g^x)^(a + u*x) mod N,  K = H(S)
--   M = H( (H(N) xor H(g)) | H(username) | salt | A | B | K )
--   The server answers with H(A | M | K), which proves it knew the verifier.
--
-- Numbers are big-endian byte strings with no leading zero bytes, which is
-- what buildat.bignum gives back; only k and u hash their inputs zero-padded
-- to the length of N. The name in x is lowercase (that is how the verifier was
-- made), the one in M is as the player typed it.
--
-- M.self_test() checks all of this against vectors from util/srp_reference.py.

local bignum = buildat.bignum
local H = buildat.sha256
local M = {}

local function unhex(hex)
	return (hex:gsub("%x%x", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

-- The 2048-bit group
local N = unhex(
	"AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294"..
	"3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D"..
	"CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB"..
	"D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74"..
	"7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A"..
	"436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D"..
	"5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73"..
	"03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"..
	"94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F"..
	"9E4AFF73")
local g = string.char(2)

local function pad(bytes)
	return string.rep("\0", #N - #bytes)..bytes
end

local function H_nn(n1, n2)
	return H(pad(n1)..pad(n2))
end

local function calculate_x(salt, username_for_verifier, password)
	return H(salt..H(username_for_verifier..":"..password))
end

local function xor_bytes(a, b)
	local out = {}
	for i = 1, #a do
		-- No bit operations in plain Lua 5.1; a byte at a time with arithmetic
		local p, q = a:byte(i), b:byte(i)
		local r, bit = 0, 1
		for _ = 1, 8 do
			if (p % 2) ~= (q % 2) then
				r = r + bit
			end
			p, q, bit = math.floor(p / 2), math.floor(q / 2), bit * 2
		end
		out[i] = string.char(r)
	end
	return table.concat(out)
end

-- salt (16 random bytes if not given) and the verifier the server stores
function M.create_verifier(username_for_verifier, password, salt)
	salt = salt or buildat.random_bytes(16)
	local x = calculate_x(salt, username_for_verifier, password)
	return salt, bignum.mod_exp(g, x, N)
end

-- bytes_a is the private exponent; leave it out for a random one (only the
-- self-test wants to set it)
function M.client(username, username_for_verifier, password, bytes_a)
	local self = {}
	local a = bytes_a or buildat.random_bytes(32)
	local A = bignum.mod_exp(g, a, N)
	local session_key = nil
	local proof = nil
	local expected_H_AMK = nil

	function self:bytes_A()
		return A
	end

	-- The server's salt and B, giving M to send back. nil if B failed the
	-- SRP-6a safety check, which means the exchange has to be dropped.
	function self:process_challenge(salt, B)
		local u = H_nn(A, B)
		if bignum.mod(B, N) == "" or u == string.rep("\0", #u) then
			return nil
		end
		local x = calculate_x(salt, username_for_verifier, password)
		local k = H_nn(N, g)
		-- S = (B - k*(g^x)) ^ (a + u*x) mod N
		local exponent = bignum.add(a, bignum.mul(u, x))
		local gx = bignum.mod_exp(g, x, N)
		local base = bignum.sub_mod(B, bignum.mul_mod(k, gx, N), N)
		local S = bignum.mod_exp(base, exponent, N)

		session_key = H(S)
		proof = H(xor_bytes(H(N), H(g))..H(username)..salt..A..B..session_key)
		expected_H_AMK = H(A..proof..session_key)
		return proof
	end

	-- What the server sends after it has checked M
	function self:verify_session(bytes_H_AMK)
		return expected_H_AMK ~= nil and bytes_H_AMK == expected_H_AMK
	end

	function self:session_key()
		return session_key
	end

	return self
end

function M.self_test()
	local username = "TestPlayer"
	local username_for_verifier = "testplayer"
	local password = "hunter2"
	local salt = unhex("000102030405060708090a0b0c0d0e0f")
	local bytes_a = unhex(
			"01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da")
	local expect_v = unhex(
			"5556c74a85142ef78293ebf581be799ae8b7100146335d1f3bd64e6109532ead"..
			"06cf576db851d90e1a8820e468aca19631aefe83733147cc9bafccce54e17c77"..
			"7d039e02869e7a40c00ef1fecf97018b629a3711785e7b5648db04dacca13c74"..
			"4bb9daae0b1e6eb1820576cdea5835361301b3f571e19044756fe47116f008f3"..
			"786a256af7b9c4c55ee78e50b022bd11aa67c3f3b7ae34d5ce08835c1ae2e31b"..
			"48ee7b52106ec8c4e5dcc1622567cf3dedcf7b945d06cafddd56094f1d301fd5"..
			"15fe1a8eebd8d3840e2e9a95ade499e65c8d00836d7cafe358362c5e2d5ffc53"..
			"b9bf9b3c1439a51d65673c650919cfd3edb22a52b22ac119a638c9f75e4cd044")
	local expect_A = unhex(
			"a249e76cf6551322a46dfa72c7462074d3de372bbcb5b86ed747c65302c5d06b"..
			"d7e43002a8c663084400ed0430c7122f6c0187e73ba7749cb7e18d8a76da5f8d"..
			"512858c292526b373a2073297f334bc9771247efcbf034771521b4abc0e79642"..
			"4622869a66e8643707bad3c243afad7d807f1092a5165f7a41d72cb925eca2ce"..
			"e1c717bd7434f3ca8de66550d5cdd39e6ca20c508124d0fd0f46c7e930893077"..
			"7137ed06debb95a8f61bcbb22fab9667fa0c653624202e35e3c6c601b86a3e4d"..
			"1c705db6c3b573894bdfc2792a7576485927b56a81d50907aa82c07a9ffb5b8b"..
			"54adfb3b97fb68695aa4cb18f928265d981b34f7d4c677bd6f35e096a5faa197")
	local B = unhex(
			"2159059886f4f4c5f8bf66076a909a15f2b9c290453ef5d4e8716f5897071ac7"..
			"8c35046dddfbd8ccfc7b4a164e4fb03039b0a908b69ec3b609deea4c9eea9db7"..
			"f28b357919d495ff232f71589b691359c8455530bac6f5c8543d675306cea0de"..
			"16bbf26016228d881d5ee45cc1e7fdf5473b075c140092209a26631f1ac7864f"..
			"0983ae47de26b2599afe7b8a9109f5b3643f092f45199c88927edd7e4ad14117"..
			"9fa7a0af5000324eeac88ae6240fcf84ac2058289ab51cecf8eed4f496594065"..
			"6deb7536e79ba0e7c3ed5c9707fb9f8caa6a4250eedc5284ec4f669a4d27271d"..
			"d9cc44971569b48f054ad31170b50a92ddbb9bdb68db43f09eb7b61ad5de1146")
	local expect_M = unhex(
			"319c2922f230e9ce123bde1e735efb6e3d036145fe1d54a91f83667972016038")
	local H_AMK = unhex(
			"6e4d763070faa7cc233d71ee8a0655a5dcfe5026b61ed8b1ea3f1b9b07b4f126")

	local salt_out, verifier = M.create_verifier(username_for_verifier,
			password, salt)
	assert(salt_out == salt, "srp: salt came back changed")
	assert(verifier == expect_v, "srp: wrong verifier")

	local client = M.client(username, username_for_verifier, password, bytes_a)
	assert(client:bytes_A() == expect_A, "srp: wrong A")
	assert(client:process_challenge(salt, B) == expect_M, "srp: wrong M")
	assert(client:verify_session(H_AMK), "srp: rejected the server's proof")
	assert(not client:verify_session(string.rep("x", 32)),
			"srp: accepted a bad proof")

	-- A server sending B = 0 must not get a proof
	local client2 = M.client(username, username_for_verifier, password, bytes_a)
	assert(client2:process_challenge(salt, "\0") == nil,
			"srp: B = 0 got through the safety check")

	-- The random private exponent differs between logins
	assert(M.client(username, username_for_verifier, password):bytes_A() ~=
			M.client(username, username_for_verifier, password):bytes_A(),
			"srp: A is not random")
end

return M
-- vim: set noet ts=4 sw=4:
