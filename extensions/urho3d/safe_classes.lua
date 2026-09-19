-- Buildat: extension/urho3d/safe_classes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local dump = buildat.dump
local log = buildat.Logger("safe_classes")
local M = {}

function M.define(dst, util)
	util.wc("StringHash", {
		unsafe_constructor = util.wrap_function({{"string"}},
		function(value)
			return util.wrap_instance("StringHash", StringHash(value))
		end),
		instance = {
		}
	})

	util.wc("VectorBuffer", {
		class = {
			new = function()
				return util.wrap_instance("VectorBuffer", VectorBuffer())
			end,
		},
		instance = {
			-- Writing, for handing a shader a float array: a Variant made of
			-- one of these is VAR_BUFFER, which Urho sets as a float array of
			-- whatever length the uniform declares
			WriteFloat = util.self_function(
					"WriteFloat", {"boolean"}, {"VectorBuffer", "number"}),
			Clear = util.self_function(
					"Clear", {}, {"VectorBuffer"}),
			GetSize = util.self_function(
					"GetSize", {"number"}, {"VectorBuffer"}),
			ReadString = util.self_function(
					"ReadString", {"string"}, {"VectorBuffer"}),
			ReadInt = util.self_function(
					"ReadInt", {"number"}, {"VectorBuffer"}),
			ReadFloat = util.self_function(
					"ReadFloat", {"number"}, {"VectorBuffer"}),
			ReadVector3 = util.wrap_function({"VectorBuffer"},
				function(self)
					return util.wrap_instance("Vector3", self:ReadVector3())
				end
			),
		},
		properties = {
			size = util.simple_property("number"),
			eof = util.simple_property("boolean"),
		},
	})

	util.wc("Variant", {
		unsafe_constructor = util.wrap_function({{"Color", "VectorBuffer"}},
		function(value)
			return util.wrap_instance("Variant", Variant(value))
		end),
		instance = {
			IsEmpty = util.self_function(
					"IsEmpty", {"boolean"}, {"Variant"}),
			GetString = util.self_function(
					"GetString", {"string"}, {"Variant"}),
			GetInt = util.self_function(
					"GetInt", {"number"}, {"Variant"}),
			GetBool = util.self_function(
					"GetBool", {"boolean"}, {"Variant"}),
			GetBuffer = util.wrap_function({"Variant"},
				function(self)
					return util.wrap_instance("VectorBuffer", self:GetBuffer())
				end
			),
		}
	})

	util.wc("VariantMap", {
		unsafe_constructor = util.wrap_function({},
		function()
			return util.wrap_instance("VariantMap", VariantMap())
		end),
		instance = {
			-- 1.7 Lua VariantMap has no Get/Set methods; values are Variants
			-- via eventData["Key"]. Keep the 2014 method names for games.
			SetFloat = util.wrap_function({"VariantMap", "string", "number"},
				function(self, key, value)
					self[key] = value
				end),
			GetFloat = util.wrap_function({"number"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetFloat("..tostring(key)..
								"): missing or empty")
					end
					return v:GetFloat()
				end),
			SetInt = util.wrap_function({"VariantMap", "string", "number"},
				function(self, key, value)
					self[key] = value
				end),
			GetInt = util.wrap_function({"number"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetInt("..tostring(key)..
								"): missing or empty")
					end
					return v:GetInt()
				end),
			SetBool = util.wrap_function({"VariantMap", "string", "boolean"},
				function(self, key, value)
					self[key] = value
				end),
			GetBool = util.wrap_function({"boolean"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetBool("..tostring(key)..
								"): missing or empty")
					end
					return v:GetBool()
				end),
			SetString = util.wrap_function({"VariantMap", "string", "string"},
				function(self, key, value)
					self[key] = value
				end),
			GetString = util.wrap_function({"string"}, {"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetString("..tostring(key)..
								"): missing or empty")
					end
					return v:GetString()
				end),
			SetBuffer = util.wrap_function({"VariantMap", "string", "VectorBuffer"},
				function(self, key, value)
					self[key] = value
				end),
			GetBuffer = util.wrap_function({dst.VectorBuffer},
					{"VariantMap", "string"},
				function(self, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetBuffer("..tostring(key)..
								"): missing or empty")
					end
					return v:GetBuffer()
				end),
			SetPtr = util.wrap_function({"VariantMap", "string",
					{"Node", "Component"}},
				function(self, key, value)
					self[key] = value
				end),
			GetPtr = util.wrap_function({"VariantMap", "string", "string"},
				function(self, type, key)
					local v = self[key]
					if v == nil or (v.IsEmpty and v:IsEmpty()) then
						error("VariantMap:GetPtr("..tostring(key)..
								"): missing or empty")
					end
					local ptr = v:GetPtr(type)
					if ptr == nil then
						error("VariantMap:GetPtr("..tostring(key)..", "..
								tostring(type).."): ptr is nil")
					end
					return util.wrap_instance(type, ptr)
				end),
		}
	})

	util.wc("Quaternion", {
		unsafe_constructor = util.wrap_function({
				"number", {"number", "Vector3"}, {"number", "__nil"},
						{"number", "__nil"}},
		function(w, x, y, z)
			if type(w) == "number" and type(x) == "number" and
					type(y) == "number" and type(z) == "number" then
				return util.wrap_instance("Quaternion", Quaternion(w, x, y, z))
			elseif type(w) == "number" and type(x) == "number" and
					type(y) == "number" and z == nil then
				-- y, x, z (euler angles)
				return util.wrap_instance("Quaternion", Quaternion(w, x, y))
			else
				-- angle: float, axis: Vector3
				return util.wrap_instance("Quaternion", Quaternion(w, x))
			end
		end),
		instance = {
			YawAngle = util.self_function(
					"YawAngle", {"number"}, {"Quaternion"}),
			PitchAngle = util.self_function(
					"PitchAngle", {"number"}, {"Quaternion"}),
			RollAngle = util.self_function(
					"RollAngle", {"number"}, {"Quaternion"}),
			EulerAngles = util.wrap_function({"Quaternion"},
				function(self)
					return util.wrap_instance("Vector3", self:EulerAngles())
				end
			),
		},
		instance_meta = {
			__mul = util.wrap_function({"Quaternion", "number"}, function(self, n)
				return util.wrap_instance("Quaternion", self * n)
			end),
			__add = util.wrap_function({"Quaternion", "Quaternion"}, function(self, other)
				return util.wrap_instance("Quaternion", self + other)
			end),
			__sub = util.wrap_function({"Quaternion", "Quaternion"}, function(self, other)
				return util.wrap_instance("Quaternion", self - other)
			end),
			__eq = util.wrap_function({"Quaternion", "Quaternion"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			w = util.simple_property("number"),
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	util.wc("Vector3", {
		unsafe_constructor = util.wrap_function({"number", "number", "number"},
		function(x, y, z)
			return util.wrap_instance("Vector3", Vector3(x, y, z))
		end),
		class = {
			from_buildat = function(v)
				return util.wrap_instance("Vector3", Vector3(v.x, v.y, v.z))
			end,
		},
		instance = {
			Length = util.self_function(
					"Length", {"number"}, {"Vector3"}),
			CrossProduct = util.wrap_function({"Vector3", "Vector3"},
				function(self, other)
					return util.wrap_instance("Vector3", self:CrossProduct(other))
				end
			),
			Normalized = util.wrap_function({"Vector3"},
				function(self)
					return util.wrap_instance("Vector3", self:Normalized())
				end
			),
		},
		instance_meta = {
			__mul = util.wrap_function({"Vector3", "number"}, function(self, n)
				return util.wrap_instance("Vector3", self * n)
			end),
			__div = util.wrap_function({"Vector3", "number"}, function(self, n)
				return util.wrap_instance("Vector3", self / n)
			end),
			__add = util.wrap_function({"Vector3", "Vector3"}, function(self, other)
				return util.wrap_instance("Vector3", self + other)
			end),
			__sub = util.wrap_function({"Vector3", "Vector3"}, function(self, other)
				return util.wrap_instance("Vector3", self - other)
			end),
			__eq = util.wrap_function({"Vector3", "Vector3"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	-- Whole-number coordinates, which is what a voxel world counts in.
	-- Added 2026-09-15 with the Math batch of [URHO_SWEEP]; arithmetic draws
	-- nothing and reaches nothing, which is the policy's clearest yes.
	util.wc("IntVector3", {
		unsafe_constructor = util.wrap_function({"number", "number", "number"},
		function(x, y, z)
			return util.wrap_instance("IntVector3", IntVector3(x, y, z))
		end),
		class = {
			from_buildat = function(v)
				return util.wrap_instance("IntVector3",
						IntVector3(v.x, v.y, v.z))
			end,
		},
		instance = {
			Length = util.self_function("Length", {"number"},
					{"IntVector3"}),
		},
		instance_meta = {
			__add = util.wrap_function({"IntVector3", "IntVector3"},
			function(self, other)
				return util.wrap_instance("IntVector3", self + other)
			end),
			__sub = util.wrap_function({"IntVector3", "IntVector3"},
			function(self, other)
				return util.wrap_instance("IntVector3", self - other)
			end),
			__mul = util.wrap_function({"IntVector3", "number"},
			function(self, n)
				return util.wrap_instance("IntVector3", self * n)
			end),
			__eq = util.wrap_function({"IntVector3", "IntVector3"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	-- The fourth component is what a shader parameter and a homogeneous
	-- coordinate want; Material:SetShaderParameter() already takes the
	-- others.
	util.wc("Vector4", {
		unsafe_constructor = util.wrap_function(
				{"number", "number", "number", "number"},
		function(x, y, z, w)
			return util.wrap_instance("Vector4", Vector4(x, y, z, w))
		end),
		instance = {
			DotProduct = util.self_function("DotProduct", {"number"},
					{"Vector4", "Vector4"}),
			Length = util.self_function("Length", {"number"}, {"Vector4"}),
		},
		instance_meta = {
			__add = util.wrap_function({"Vector4", "Vector4"},
			function(self, other)
				return util.wrap_instance("Vector4", self + other)
			end),
			__sub = util.wrap_function({"Vector4", "Vector4"},
			function(self, other)
				return util.wrap_instance("Vector4", self - other)
			end),
			__mul = util.wrap_function({"Vector4", "number"},
			function(self, n)
				return util.wrap_instance("Vector4", self * n)
			end),
			__eq = util.wrap_function({"Vector4", "Vector4"},
			function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
			w = util.simple_property("number"),
		},
	})

	-- A point and a direction, and what it runs into. This is what a game
	-- does its own picking with -- Camera:WorldToScreenPoint() is the other
	-- direction of the same question -- and the HitDistance family answers
	-- in distance along the ray, with a huge number for a miss rather than
	-- a nil.
	--
	-- simplified: the box and the sphere, which are the shapes this sandbox
	-- has. Urho3D also tests a frustum, a plane and a triangle; the first
	-- two are not whitelisted classes and the third wants three vectors and
	-- has no consumer.
	util.wc("Ray", {
		unsafe_constructor = util.wrap_function({"Vector3", "Vector3"},
		function(origin, direction)
			return util.wrap_instance("Ray", Ray(origin, direction))
		end),
		instance = {
			Define = util.self_function("Define", {},
					{"Ray", "Vector3", "Vector3"}),
			-- How far along the ray the point is, and how far off it
			Project = util.wrap_function({"Ray", "Vector3"},
				function(self, point)
					return util.wrap_instance("Vector3", self:Project(point))
				end
			),
			Distance = util.self_function("Distance", {"number"},
					{"Ray", "Vector3"}),
			HitDistanceBox = util.self_function("HitDistance", {"number"},
					{"Ray", "BoundingBox"}),
			HitDistanceSphere = util.self_function("HitDistance", {"number"},
					{"Ray", "Sphere"}),
		},
		properties = {
			origin = util.simple_property(dst.Vector3),
			direction = util.simple_property(dst.Vector3),
		},
	})

	-- A centre and a radius: what a thing occupies, for anything deciding
	-- whether to bother with it.
	util.wc("Sphere", {
		unsafe_constructor = util.wrap_function({"Vector3", "number"},
		function(center, radius)
			return util.wrap_instance("Sphere", Sphere(center, radius))
		end),
		instance = {
			Define = util.self_function("Define", {},
					{"Sphere", "Vector3", "number"}),
			Merge = util.self_function("Merge", {}, {"Sphere", "Vector3"}),
			Clear = util.self_function("Clear", {}, {"Sphere"}),
			Distance = util.self_function("Distance", {"number"},
					{"Sphere", "Vector3"}),
		},
		properties = {
			center = util.simple_property(dst.Vector3),
			radius = util.simple_property("number"),
		},
	})

	-- A rectangle of two corners. What wants it is a particle's texture
	-- frames, which are the parts of an image an animation runs through.
	util.wc("Rect", {
		unsafe_constructor = util.wrap_function(
				{"number", "number", "number", "number"},
		function(left, top, right, bottom)
			return util.wrap_instance("Rect", Rect(left, top, right, bottom))
		end),
		properties = {
			min = util.simple_property(dst.Vector2),
			max = util.simple_property(dst.Vector2),
		},
	})

	util.wc("Vector2", {
		unsafe_constructor = util.wrap_function({"number", "number"},
		function(x, y)
			return util.wrap_instance("Vector2", Vector2(x, y))
		end),
		instance = {
			Length = util.self_function(
					"Length", {"number"}, {"Vector2"}),
			Normalized = util.wrap_function({"Vector2"},
				function(self)
					return util.wrap_instance("Vector2", self:Normalized())
				end
			),
		},
		instance_meta = {
			__mul = util.wrap_function({"Vector2", "number"}, function(self, n)
				return util.wrap_instance("Vector2", self * n)
			end),
			__div = util.wrap_function({"Vector2", "number"}, function(self, n)
				return util.wrap_instance("Vector2", self / n)
			end),
			__add = util.wrap_function({"Vector2", "Vector2"}, function(self, other)
				return util.wrap_instance("Vector2", self + other)
			end),
			__sub = util.wrap_function({"Vector2", "Vector2"}, function(self, other)
				return util.wrap_instance("Vector2", self - other)
			end),
			__eq = util.wrap_function({"Vector2", "Vector2"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
		},
	})

	util.wc("IntVector2", {
		unsafe_constructor = util.wrap_function({"number", "number"},
		function(x, y)
			return util.wrap_instance("IntVector2", IntVector2(x, y))
		end),
		instance = {
		},
		instance_meta = {
			__mul = util.wrap_function({"IntVector2", "number"}, function(self, n)
				return util.wrap_instance("IntVector2", self * n)
			end),
			__add = util.wrap_function({"IntVector2", "IntVector2"}, function(self, other)
				return util.wrap_instance("IntVector2", self + other)
			end),
			__sub = util.wrap_function({"IntVector2", "IntVector2"}, function(self, other)
				return util.wrap_instance("IntVector2", self - other)
			end),
			__eq = util.wrap_function({"IntVector2", "IntVector2"}, function(self, other)
				return (self == other)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
		},
	})

	util.wc("IntRect", {
		unsafe_constructor = util.wrap_function({"number", "number", "number", "number"},
		function(left, top, right, bottom)
			return util.wrap_instance("IntRect", IntRect(left, top, right, bottom))
		end),
		properties = {
			left = util.simple_property("number"),
			top = util.simple_property("number"),
			right = util.simple_property("number"),
			bottom = util.simple_property("number"),
		},
	})

	util.wc("Color", {
		unsafe_constructor = util.wrap_function({"number", "number", "number",
				{"number", "__nil"}},
		function(r, g, b, a)
			a = a or 1.0
			return util.wrap_instance("Color", Color(r, g, b, a))
		end),
		instance_meta = {
			__mul = util.wrap_function({"Color", "number"}, function(self, n)
				return util.wrap_instance("Color", self * n)
			end),
		},
		properties = {
			r = util.simple_property("number"),
			g = util.simple_property("number"),
			b = util.simple_property("number"),
			a = util.simple_property("number"),
		},
	})

	util.wc("BoundingBox", {
		unsafe_constructor = util.wrap_function({
				{"number", "Vector3"}, {"number", "Vector3"}},
		function(min, max)
			return util.wrap_instance("BoundingBox", BoundingBox(min, max))
		end),
		instance_meta = {
		},
		properties = {
		},
	})

	util.wc("BiasParameters", {
		-- The third one is Urho3D's normal offset, which moves the lookup
		-- along the surface normal instead of along the light: it is what
		-- keeps a large flat face out of its own shadow without pushing the
		-- shadow off the foot of what casts it
		unsafe_constructor = util.wrap_function(
		{"number", "number", {"number", "__nil"}},
		function(constant_bias, slope_scaled_bias, normal_offset)
			return util.wrap_instance("BiasParameters",
					BiasParameters(constant_bias, slope_scaled_bias,
							normal_offset or 0.0))
		end),
	})

	util.wc("CascadeParameters", {
		unsafe_constructor = util.wrap_function({"number", "number", "number", "number", "number", {"number", "__nil"}},
		function(split1, split2, split3, split4, fadeStart, biasAutoAdjust)
			biasAutoAdjust = biasAutoAdjust or 1.0
			return util.wrap_instance("CascadeParameters",
					CascadeParameters(split1, split2, split3, split4, fadeStart, biasAutoAdjust))
		end),
	})

	util.wc("Resource", {
		properties = {
			-- The resource's name, which is its path under a resource dir:
			-- read-only here (writing one raises), for what reports which
			-- picture an element shows ([SCAN_EVENT])
			name = {get = util.simple_property("string").get},
		},
	})

	util.wc("Component", {
	})

	util.wc("Octree", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			GetDrawables = util.wrap_function({"table"}, {"Octree", "BoundingBox"},
				function(self, query)
					local unsafe_result = self:GetDrawables(query)
					-- The result is a list of OctreeQueryResults; we will
					-- convert it to a list of tables that contain the fields of
					-- OctreeQueryResult.
					local result = {}
					if unsafe_result == nil then
						log:error("GetDrawables returned nil")
						return result
					end
					for _, v in ipairs(unsafe_result) do
						if v.drawable ~= nil and v.node ~= nil then
							table.insert(result, {
								drawable = util.wrap_instance("Drawable",
										v.drawable),
								node = util.wrap_instance("Node", v.node),
							})
						end
					end
					return result
				end
			),
		},
	})

	util.wc("Drawable", {
		inherited_from_by_wrapper = dst.Component,
		properties = {
			-- Urho3D has this on Drawable, so a billboard set has it as
			-- much as a static model does
			castShadows = util.simple_property("boolean"),
		},
	})

	util.wc("CustomGeometry", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			SetNumGeometries = util.self_function(
					"SetNumGeometries", {}, {"CustomGeometry", "number"}),
			BeginGeometry = util.self_function(
					"BeginGeometry", {}, {"CustomGeometry", "number", "number"}),
			DefineVertex = util.self_function(
					"DefineVertex", {}, {"CustomGeometry", "Vector3"}),
			DefineNormal = util.self_function(
					"DefineNormal", {}, {"CustomGeometry", "Vector3"}),
			DefineTexCoord = util.self_function(
					"DefineTexCoord", {}, {"CustomGeometry", "Vector2"}),
			DefineColor = util.self_function(
					"DefineColor", {}, {"CustomGeometry", "Color"}),
			Commit = util.self_function(
					"Commit", {}, {"CustomGeometry"}),
			-- Urho returns null past the last geometry, which is how a caller
			-- finds out how many there are
			GetMaterial = util.wrap_function({"CustomGeometry", "number"},
			function(self, index)
				local material = self:GetMaterial(index)
				if not material then
					return nil
				end
				return util.wrap_instance("Material", material)
			end),
			SetMaterial = util.self_function(
					"SetMaterial", {}, {"CustomGeometry", "number", "Material"}),
		},
		properties = {
			dynamic = util.simple_property("boolean"),
		},
	})

	util.wc("Camera", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			-- Where a point in the world lands on the screen, as a
			-- fraction of it. What wants it is anything a game draws over
			-- a place rather than over a corner: Luanti's waypoints are
			-- that, and a marker over another player would be.
			WorldToScreenPoint = util.self_function("WorldToScreenPoint",
					{dst.Vector2}, {"Camera", "Vector3"}),
		},
		properties = {
			nearClip = util.simple_property("number"),
			farClip = util.simple_property("number"),
			fov = util.simple_property("number"),
			orthographic = util.simple_property("boolean"),
			orthoSize = util.simple_property("number"),
		},
	})

	util.wc("RigidBody", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			ApplyForce = util.self_function(
					"ApplyForce", {}, {"RigidBody", "Vector3"}),
			ApplyImpulse = util.self_function(
					"ApplyImpulse", {}, {"RigidBody", "Vector3"}),
		},
		properties = {
			mass = util.simple_property("number"),
			gravityOverride = util.simple_property(dst.Vector3),
			friction = util.simple_property("number"),
			angularFactor = util.simple_property(dst.Vector3),
			kinematic = util.simple_property("boolean"),
			linearVelocity = util.simple_property(dst.Vector3),
			angularVelocity = util.simple_property(dst.Vector3),
			collisionEventMode = util.simple_property("number"),
			restitution = util.simple_property("number"),
			linearDamping = util.simple_property("number"),
			angularDamping = util.simple_property("number"),
			useGravity = util.simple_property("boolean"),
			-- Which layers this body is in and which it collides with.
			-- What wants them from a game is a free camera: a body that
			-- collides with nothing goes through the terrain, which is the
			-- escape hatch from every way of ending up inside it.
			collisionLayer = util.simple_property("number"),
			collisionMask = util.simple_property("number"),
		},
	})

	util.wc("CollisionShape", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			SetBox = util.self_function(
					"SetBox", {}, {"CollisionShape", "Vector3"}),
			SetCapsule = util.self_function(
					"SetCapsule", {}, {"CollisionShape", "number", "number"}),
			SetSphere = util.self_function(
					"SetSphere", {}, {"CollisionShape", "number"}),
			SetStaticPlane = util.self_function(
					"SetStaticPlane", {}, {"CollisionShape"}),
			SetCylinder = util.self_function(
					"SetCylinder", {}, {"CollisionShape", "number", "number"}),
			SetCone = util.self_function(
					"SetCone", {}, {"CollisionShape", "number", "number"}),
		},
	})

	util.wc("Model", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("Material", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("Material", Material:new())
			end,
		},
		instance = {
			--SetTexture = util.wrap_function({"Material", "number", "Texture"},
			--function(self, index, texture)
			--	log:info("Material:SetTexture("..dump(index)..", "..dump(texture)..")")
			--	self:SetTexture(index, texture)
			--end),
			SetShaderParameter = util.wrap_function(
				{"Material", "string",
					{"number", "boolean", "Vector2", "Vector3", "Color",
						"Variant"}},
				function(self, name, value)
					self:SetShaderParameter(name, Variant(value))
				end
			),
			SetTexture = util.self_function(
					"SetTexture", {}, {"Material", "number", "Texture"}),
			SetTechnique = util.self_function(
					"SetTechnique", {}, {"Material", "number", "Technique",
							{"number", "__nil"}, {"number", "__nil"}}),
		},
		properties = {
			-- Which faces are thrown away, as CULL_NONE, CULL_CCW or
			-- CULL_CW. A technique carries one and a material overrides it,
			-- which is how Urho3D's own skybox material is drawn: a box
			-- seen from the inside is entirely back-facing, so a skybox
			-- with the default culling draws nothing at all.
			cullMode = util.simple_property("number"),
		},
	})

	util.wc("Texture", {
		inherited_from_by_wrapper = dst.Resource,
		properties = {
			-- Read-only in Urho3D, so writing one raises. What wanted them
			-- is a HUD element whose size is a multiple of its own image's.
			width = util.simple_property("number"),
			height = util.simple_property("number"),
			-- FILTER_NEAREST and the rest of Urho3D's TextureFilterMode.
			-- What wants it is pixel art, which is what a Luanti game's
			-- textures are: smoothing them is wrong at every size.
			filterMode = util.simple_property("number"),
		},
	})

	util.wc("Texture2D", {
		inherited_from_by_wrapper = dst.Texture,
	})

	-- Declared here rather than next to Drawable: its ramp property needs
	-- Texture, and these are wrapped in the order they are written in
	util.wc("Light", {
		inherited_from_by_wrapper = dst.Drawable,
		properties = {
			lightType = util.simple_property("number"),
			brightness = util.simple_property("number"),
			shadowIntensity = util.simple_property("number"),
			shadowBias = util.simple_property("BiasParameters"),
			shadowCascade = util.simple_property("CascadeParameters"),
			color = util.simple_property(dst.Color),
			range = util.simple_property("number"),
			fadeDistance = util.simple_property("number"),
			fov = util.simple_property("number"),
			specularIntensity = util.simple_property("number"),
			-- How the light falls off over its range, sampled at
			-- distance/range; Textures/Ramp.png is the default one
			rampTexture = util.simple_property(dst.Texture),
		},
	})

	util.wc("Zone", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
		},
		properties = {
			boundingBox = util.simple_property(dst.BoundingBox),
			ambientColor = util.simple_property(dst.Color),
			fogColor = util.simple_property(dst.Color),
			fogStart = util.simple_property("number"),
			fogEnd = util.simple_property("number"),
			priority = util.simple_property("number"),
			heightFog = util.simple_property("boolean"),
			override = util.simple_property("boolean"),
			ambientGradient = util.simple_property("boolean"),
			-- The environment cube map the PBR shaders reflect
			zoneTexture = util.simple_property(dst.Texture),
		},
	})

	util.wc("Font", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("XMLFile", {
		inherited_from_by_wrapper = dst.Resource,
	})

	-- Drawable, which is what Urho3D says it is; it used to say Octree here,
	-- which gave it the octree's query methods and none of a drawable's
	-- properties
	util.wc("StaticModel", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			SetModel = util.self_function(
					"SetModel", {}, {"StaticModel", "Model"}),
		},
		properties = {
			model = util.simple_property(dst.Model),
			material = util.simple_property(dst.Material),
		},
	})

	util.wc("Technique", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("Node", {
		class = {
			new = function()
				return util.wrap_instance("Node", Node:new())
			end,
		},
		instance = {
			CreateChild = util.wrap_function({"Node", "string",
					{"number", "__nil"}},
				function(self, name, mode)
					if mode ~= nil then
						return util.wrap_instance("Node", self:CreateChild(name, mode))
					else
						return util.wrap_instance("Node", self:CreateChild(name, LOCAL))
					end
				end
			),
			CreateComponent = util.wrap_function(
					{"Node", "string", {"number", "__nil"}},
				function(self, name, mode)
					local component = nil
					if mode ~= nil then
						component = self:CreateComponent(name, mode)
					else
						component = self:CreateComponent(name, LOCAL)
					end
					assert(component)
					return util.wrap_instance(name, component)
				end
			),
			GetComponent = util.wrap_function({"Node", "string"}, function(self, name)
				local component = self:GetComponent(name)
				if not component then
					return nil
				end
				return util.wrap_instance(name, component)
			end),
			LookAt = util.wrap_function({"Node", "Vector3"}, function(self, p)
				self:LookAt(p)
			end),
			Translate = util.wrap_function({"Node", "Vector3"}, function(self, v)
				self:Translate(v)
			end),
			RemoveChild = util.wrap_function({"Node", "Node"}, function(self, v)
				self:RemoveChild(v)
			end),
			GetID = util.self_function("GetID", {"number"}, {"Node"}),
			GetName = util.self_function("GetName", {"string"}, {"Node"}),
			GetNumChildren = util.self_function(
					"GetNumChildren", {"number"}, {"Node"}),
			GetChild = util.wrap_function({"Node", {"string", "number"}},
				function(self, name_or_index)
					return util.wrap_instance("Node",
							self:GetChild(name_or_index))
				end
			),
			SetScale = util.self_function("SetScale", {}, {"Node", "Vector3"}),
			GetVar = util.wrap_function({"Node", {"string", "StringHash"}},
				function(self, name_or_stringhash)
					if type(name_or_stringhash) == "string" then
						return util.wrap_instance("Variant",
								self:GetVar(StringHash(name_or_stringhash)))
					else
						return util.wrap_instance("Variant",
								self:GetVar(name_or_stringhash))
					end
				end
			),
			SetVar = util.wrap_function({"Node", {"string", "StringHash"}, "Variant"},
				function(self, name_or_stringhash, value)
					if type(name_or_stringhash) == "string" then
						self:SetVar(StringHash(name_or_stringhash), value)
					else
						self:SetVar(name_or_stringhash, value)
					end
				end
			),
			SetVar = util.self_function("SetVar", {},
					{"Node", "StringHash", "Variant"}),
			GetWorldPosition = util.self_function("GetWorldPosition", {dst.Vector3}, {"Node"}),
			GetWorldDirection = util.self_function("GetWorldDirection", {dst.Vector3}, {"Node"}),
			GetRotation = util.self_function("GetRotation", {dst.Quaternion}, {"Node"}),
			Pitch = util.self_function("Pitch", {}, {"Node", "number"}),
			Yaw = util.self_function("Yaw", {}, {"Node", "number"}),
			Roll = util.self_function("Roll", {}, {"Node", "number"}),
			Rotate = util.wrap_function({"Node", "Quaternion", {"number", "__nil"}},
				function(self, q, space)
					if space ~= nil then
						self:Rotate(q, space)
					else
						self:Rotate(q)
					end
				end
			),
			Remove = util.self_function("Remove", {}, {"Node"}),
			SetEnabled = util.self_function(
					"SetEnabled", {}, {"Node", "boolean"}),
			-- A copy of the node and its components, in the same parent.
			-- Urho3D copies a component through its attributes, which is in
			-- the engine: what wants this is geometry that costs a sandbox
			-- call per vertex to build and is wanted more than once.
			-- Attributes are all it copies, so a material made in Lua --
			-- which has no resource name to refer to -- is not among them
			-- and has to be set on the copy.
			Clone = util.wrap_function({"Node", {"number", "__nil"}},
				function(self, mode)
					return util.wrap_instance("Node",
							self:Clone(mode ~= nil and mode or LOCAL))
				end
			),
		},
		properties = {
			scale = util.simple_property(dst.Vector3),
			direction = util.simple_property(dst.Vector3),
			position = util.simple_property(dst.Vector3),
			worldDirection = util.simple_property(dst.Vector3),
			worldPosition = util.simple_property(dst.Vector3),
			enabled = util.simple_property("boolean"),
			rotation = util.simple_property(dst.Quaternion),
		},
	})

	util.wc("Plane", {
	})

	util.wc("Scene", {
		inherited_from_by_wrapper = dst.Node,
		properties = {
			-- What cElapsedTime(PS) in the shaders is
			elapsedTime = util.simple_property("number"),
			timeScale = util.simple_property("number"),
		},
		unsafe_constructor = util.wrap_function({}, function()
			return util.wrap_instance("Scene", Scene())
		end),
		class = {
			new = function()
				return util.wrap_instance("Scene", Scene:new())
			end,
		},
		instance = {
			GetNode = util.wrap_function({"Scene", "number"},
				function(self, id)
					return util.wrap_instance("Node", self:GetNode(id))
				end
			),
		},
	})

	-- Add properties to Node, using types defined later
	getmetatable(dst.Node).def.properties["scene"] =
			util.simple_property(dst.Scene),

	util.wc("ResourceCache", {
		instance = {
			GetResource = util.wrap_function({"ResourceCache", "string", "string"},
			function(self, resource_type, unsafe_resource_name)
				--[[
				-- NOTE: resource_type=XMLFile can refer to other resources even
				-- in absolute and arbitrary relative paths. Make sure file
				-- access (fopen()) is sandboxed appropriately.
				resource_name = util.check_safe_resource_name(unsafe_resource_name)
				log:debug("GetResource: "..dump(unsafe_resource_name)..
						" -> "..dump(resource_name))
				local saved_path = util.resave_file(resource_name)
				-- Note: saved_path is ignored
				--]]
				local res = cache:GetResource(resource_type, unsafe_resource_name)
				return util.wrap_instance(resource_type, res)
			end),
		},
	})

	-- One command of a render path. A scene pass command's shader parameters
	-- reach every batch it draws, which is how one value can be handed to
	-- every material in the viewport at once; see builtin/voxel_shading.
	util.wc("RenderPathCommand", {
		instance = {
			SetShaderParameter = util.wrap_function(
				{"RenderPathCommand", "string",
					{"number", "boolean", "Vector2", "Vector3", "Color",
						"Variant"}},
				function(self, name, value)
					self:SetShaderParameter(name, Variant(value))
				end
			),
			RemoveShaderParameter = util.self_function(
					"RemoveShaderParameter", {},
					{"RenderPathCommand", "string"}),
		},
		properties = {
			-- One of the CMD_ constants; CMD_SCENEPASS is the one that draws
			-- scene geometry
			type = util.simple_property("number"),
			-- The technique pass it draws, "base" and so on
			pass = util.simple_property("string"),
			enabled = util.simple_property("boolean"),
		},
	})

	util.wc("RenderPath", {
		instance = {
			GetNumCommands = util.self_function(
					"GetNumCommands", {"number"}, {"RenderPath"}),
			-- 0-based, as Urho counts them
			GetCommand = util.wrap_function({"RenderPath", "number"},
				function(self, index)
					return util.wrap_instance("RenderPathCommand",
							self:GetCommand(index))
				end
			),
			Clone = util.wrap_function({"RenderPath"},
				function(self)
					return util.wrap_instance("RenderPath", self:Clone())
				end
			),
			Append = util.self_function(
					"Append", {"boolean"}, {"RenderPath", "XMLFile"}),
			Load = util.self_function(
					"Load", {"boolean"}, {"RenderPath", "XMLFile"}),
			SetEnabled = util.self_function(
					"SetEnabled", {}, {"RenderPath", "string", "boolean"}),
			ToggleEnabled = util.self_function(
					"ToggleEnabled", {}, {"RenderPath", "string"}),
			SetShaderParameter = util.wrap_function(
				{"RenderPath", "string",
					{"number", "boolean", "Vector2", "Vector3", "Color",
						"Variant"}},
				function(self, name, value)
					self:SetShaderParameter(name, Variant(value))
				end
			),
		},
	})

	util.wc("Viewport", {
		class = {
			new = util.wrap_function({"__to_nil", "Scene", "Camera"},
			function(_, scene, camera_component)
				return util.wrap_instance("Viewport", Viewport:new(scene, camera_component))
			end),
		},
		instance = {
			GetScene = util.wrap_function({"Viewport"},
				function(self)
					return util.wrap_instance("Scene", self:GetScene())
				end
			),
			GetCamera = util.wrap_function({"Viewport"},
				function(self)
					return util.wrap_instance("Camera", self:GetCamera())
				end
			),
			-- Backbuffer pixels; an all-zero rect is the whole window
			SetRect = util.self_function("SetRect", {}, {"Viewport", "IntRect"}),
		},
		properties = {
			renderPath = util.simple_property(dst.RenderPath),
			rect = util.simple_property(dst.IntRect),
		},
	})

	util.wc("Renderer", {
		instance = {
			SetViewport = util.wrap_function({"Renderer", "number", "Viewport"},
				function(self, index, viewport)
					self:SetViewport(index, viewport)
				end
			),
			GetViewport = util.wrap_function({"Renderer", "number"},
				function(self, index)
					local ret = self:GetViewport(index)
					if ret == nil then return nil end
					return util.wrap_instance("Viewport", ret)
				end
			),
		},
		properties = {
			HDRRendering = util.simple_property("boolean"),
			numViewports = util.simple_property("number"),
			-- Shadows are a renderer-wide setting and not a light's: how big
			-- the shadow map is, how it is filtered (Urho3D's ShadowQuality),
			-- and whether any are drawn at all
			shadowMapSize = util.simple_property("number"),
			shadowQuality = util.simple_property("number"),
			drawShadows = util.simple_property("boolean"),
		},
	})

	-- Window size in backbuffer pixels, which is what a Viewport rect is in
	util.wc("Graphics", {
		class = {
			-- The texture format a render target is made in, static in
			-- Urho3D; see TextureCube:SetSize()
			GetRGBAFormat = function()
				return Graphics:GetRGBAFormat()
			end,
			-- Half floats: a target that holds an HDR sky's radiance
			GetRGBAFloat16Format = function()
				return Graphics:GetRGBAFloat16Format()
			end,
		},
		properties = {
			width = util.simple_property("number"),
			height = util.simple_property("number"),
		},
	})

	-- A texture's face as something a viewport draws into. What wants it
	-- is the sky rendered into a cube for the world to reflect, six
	-- viewports of one skybox scene -- [SKY_REFLECTIONS] in
	-- doc/plan/rendering_plan.md. Manual update, queued when the sky has
	-- moved, is the mode; a surface that redraws every frame is six extra
	-- renders a frame for a reflection nobody watches change.
	util.wc("RenderSurface", {
		instance = {
			SetViewport = util.wrap_function({"RenderSurface", "number",
					"Viewport"},
				function(self, index, viewport)
					self:SetViewport(index, viewport)
				end),
			QueueUpdate = util.self_function("QueueUpdate", {},
					{"RenderSurface"}),
		},
		properties = {
			updateMode = util.simple_property("number"),
		},
	})

	util.wc("Animatable", {
	})

	util.wc("UIElement", {
		inherited_from_by_wrapper = dst.Animatable,
		instance = {
			CreateChild = util.wrap_function({"UIElement", "string",
					{"string", "__nil"}},
				function(self, element_type, name)
					return util.wrap_instance(element_type,
							self:CreateChild(element_type, name))
				end
			),
			GetChild = util.wrap_function({"UIElement", {"string", "number"}},
				function(self, name_or_index)
					-- Wrapped as what it is when that class is whitelisted
					-- -- a BorderImage's texture, a Text's text -- and as a
					-- plain UIElement otherwise ([SCAN_EVENT] reads a form's
					-- elements this way)
					local child = self:GetChild(name_or_index)
					if child == nil then
						return nil
					end
					local tn = child:GetTypeName()
					local class = dst[tn]
					if class and getmetatable(class) and getmetatable(class).wrap then
						return util.wrap_instance(tn, child)
					end
					return util.wrap_instance("UIElement", child)
				end
			),
			GetNumChildren = util.self_function(
					"GetNumChildren", {"number"}, {"UIElement"}),
			RemoveChild = util.wrap_function({"UIElement", "UIElement"},
				function(self, child)
					self:RemoveChild(child)
				end
			),
			Remove = util.self_function("Remove", {}, {"UIElement"}),
			-- Everything under it at once, which is what redrawing a screen
			-- full of elements from scratch wants
			RemoveAllChildren = util.self_function(
					"RemoveAllChildren", {}, {"UIElement"}),
			SetName = util.self_function("SetName", {}, {"UIElement", "string"}),
			SetText = util.self_function("SetText", {}, {"UIElement", "string"}),
			SetFont = util.self_function("SetFont", {}, {"UIElement", "Font"}),
			SetPosition = util.self_function(
					"SetPosition", {}, {"UIElement", "number", "number"}),
			SetStyleAuto = util.self_function("SetStyleAuto", {}, {"UIElement"}),
			-- A size that is both the minimum and the maximum, which is what
			-- a layout leaves alone. Functions rather than the fixedWidth /
			-- fixedHeight / fixedSize properties, which have no setter in
			-- the bindings; see the note by them below.
			SetFixedWidth = util.self_function("SetFixedWidth", {},
					{"UIElement", "number"}),
			SetFixedHeight = util.self_function("SetFixedHeight", {},
					{"UIElement", "number"}),
			SetFixedSize = util.self_function("SetFixedSize", {},
					{"UIElement", "number", "number"}),
			SetVisible = util.self_function("SetVisible", {},
					{"UIElement", "boolean"}),
			SetLayout = util.wrap_function({"UIElement", "number",
					{"number", "__nil"}, {"IntRect", "__nil"}},
				function(self, mode, spacing, border)
					spacing = spacing or 0
					border = border or dst.IntRect()
					self:SetLayout(mode, spacing, border)
				end
			),
			SetAlignment = util.self_function(
					"SetAlignment", {}, {"UIElement", "number", "number"}),
			SetFocusMode = util.self_function(
					"SetFocusMode", {}, {"UIElement", "number"}),
			SetFocus = util.self_function(
					"SetFocus", {}, {"UIElement", "boolean"}),
			HasFocus = util.self_function(
					"HasFocus", {"boolean"}, {"UIElement"}),
			GetName = util.self_function("GetName", {"string"}, {"UIElement"}),
			-- Which kind of element this is -- "Button", "LineEdit" --
			-- which is how the one with the focus is told apart from the
			-- rest; see button_menu_nav() in extensions/ui_utils
			GetTypeName = util.self_function(
					"GetTypeName", {"string"}, {"UIElement"}),
			GetText = util.self_function("GetText", {"string"}, {"UIElement"}),
		},
		properties = {
			-- Where the element is in its parent. Note that this is an
			-- offset from whatever the alignment anchors it to, not a
			-- corner: a centred element sits at 0,0. screenPosition is the
			-- resolved place, and read-only in the bindings.
			position = util.simple_property(dst.IntVector2),
			screenPosition = {get = util.simple_property(dst.IntVector2).get},
			horizontalAlignment = util.simple_property("number"),
			verticalAlignment = util.simple_property("number"),
			height = util.simple_property("number"),
			width = util.simple_property("number"),
			size = util.simple_property(dst.IntVector2),
			color = util.simple_property(dst.Color),
			-- Whether children outside the element are drawn: a viewport
			-- over a grid taller than the window ([LAUNCH_GRID])
			clipChildren = util.simple_property("boolean"),
			minHeight = util.simple_property("number"),
			minWidth = util.simple_property("number"),
			minSize = util.simple_property(dst.IntVector2),
			-- Read-only, and not because Urho3D says so: tolua++ generates
			-- no setter for these (the generated binding is
			-- tolua_variable("fixedWidth", getter, NULL)), so assigning
			-- them wrote nowhere and read back what was assigned. Use
			-- SetFixedWidth / SetFixedHeight / SetFixedSize below.
			fixedHeight = {get = util.simple_property("number").get},
			fixedWidth = {get = util.simple_property("number").get},
			fixedSize = {get = util.simple_property(dst.IntVector2).get},
			-- "__nil" because an element that has not been given a style
			-- reads back nil, and a property that can be unset has to say so
			-- or reading it throws. The same is true of every other
			-- object-typed property here that a game might read before
			-- setting it.
			defaultStyle = util.simple_property({dst.XMLFile, "__nil"}),
			selected = util.simple_property("boolean"),
			-- Off by default in Urho3D: an element that is not enabled is
			-- not hit by a click, so nothing under the mouse is found and
			-- no click event is sent at all
			enabled = util.simple_property("boolean"),
			visible = util.simple_property("boolean"),
			opacity = util.simple_property("number"),
			priority = util.simple_property("number"),
		},
	})

	util.wc("Text", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			SetTextAlignment = util.self_function(
					"SetTextAlignment", {}, {"UIElement", "number"}),
			SetFontSize = util.self_function(
					"SetFontSize", {}, {"Text", "number"}),
			-- A shadow or an outline under the letters, which is what makes
			-- text over a world readable: a HUD over snow or sand is white
			-- on white without it. effectColor is what it is drawn with.
			SetTextEffect = util.self_function(
					"SetTextEffect", {}, {"Text", "number"}),
		},
		properties = {
			text = util.simple_property("string"),
			effectColor = util.simple_property(dst.Color),
		},
	})

	util.wc("BorderImage", {
		inherited_from_by_wrapper = dst.UIElement,
		properties = {
			-- Texture2D, the tolua type a BorderImage's texture reads back as;
			-- a setter given one passes the same check
			texture = util.simple_property(dst.Texture2D),
			hoverOffset = util.simple_property(dst.IntVector2),
			-- The border widths, which is what makes an image nine-sliced:
			-- the corners keep their size and only the middle stretches
			border = util.simple_property(dst.IntRect),
			imageBorder = util.simple_property(dst.IntRect),
			imageRect = util.simple_property(dst.IntRect),
			tiled = util.simple_property("boolean"),
			-- BLEND_REPLACE is the default and is what an image with
			-- transparency in it has to be taken off: a fully opaque colour
			-- keeps it, and then the transparent pixels are drawn black
			blendMode = util.simple_property("number"),
		},
	})

	util.wc("Window", {
		inherited_from_by_wrapper = dst.BorderImage,
	})

	-- A UI element that draws a scene of its own. Urho3D renders the scene
	-- into a texture of the element's size and shows it, which is the one
	-- way to get something three-dimensional in among the UI rather than
	-- behind all of it. What wants it here is a formspec's model[].
	util.wc("View3D", {
		inherited_from_by_wrapper = dst.Window,
		instance = {
			-- The scene and the camera it is drawn from. own_scene, which
			-- is what it defaults to, means the element takes ownership of
			-- both: a scene made for one element dies with it and a caller
			-- that keeps no reference cannot leak one. False is for a view
			-- of a scene somebody else owns -- the world seen from above,
			-- say -- which the element must not take with it when it goes.
			SetView = util.wrap_function({"View3D", "Scene", "Camera",
					{"boolean", "__nil"}},
				function(self, scene, camera, own_scene)
					self:SetView(scene, camera, own_scene ~= false)
				end
			),
			-- Draw it again once. With autoUpdate off, which is what a view
			-- of a whole scene wants, this is what refreshes it: a picture
			-- of the world costs a second pass over the world.
			QueueUpdate = util.self_function("QueueUpdate", {}, {"View3D"}),
			-- The viewport it renders through. What a caller wants from it
			-- is its render path: a scene drawn without the one the window
			-- itself is drawn with is a different picture of the same world
			-- -- with HDR on and no tonemap in the way, a white one.
			GetViewport = util.wrap_function({"View3D"},
				function(self)
					return util.wrap_instance("Viewport", self:GetViewport())
				end
			),
		},
		properties = {
			autoUpdate = util.simple_property("boolean"),
		},
	})

	util.wc("Button", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			pressedOffset = util.simple_property(dst.IntVector2),
		},
	})

	-- A box that is ticked or not. The style sheet draws it; the element
	-- carries the state.
	util.wc("CheckBox", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			checked = util.simple_property("boolean"),
		},
	})

	util.wc("LineEdit", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			-- The character a password field shows instead of what was
			-- typed, as its code point; 0 shows the text itself
			echoCharacter = util.simple_property("number"),
			maxLength = util.simple_property("number"),
		},
	})

	-- The scrolling family, added 2026-09-15 by the whitelist policy: a look
	-- rather than a proof, and a look says a panel that clips its children
	-- and two bars that say how far down it is draw and compute and do
	-- nothing else. `ui_utils.add_paged()` exists because none of this was
	-- here; see [URHO_SWEEP] and [WHITELIST_POLICY] in
	-- doc/plan/master_plan.md.
	--
	-- In dependency order, because a wrapper names the classes its
	-- properties are of and they have to exist by then.

	util.wc("Slider", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			ChangeValue = util.self_function("ChangeValue", {},
					{"Slider", "number"}),
		},
		properties = {
			orientation = util.simple_property("number"),
			range = util.simple_property("number"),
			value = util.simple_property("number"),
			-- Read-only: the part that is dragged
			knob = util.simple_property(dst.BorderImage),
			repeatRate = util.simple_property("number"),
		},
	})

	util.wc("ScrollBar", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			ChangeValue = util.self_function("ChangeValue", {},
					{"ScrollBar", "number"}),
			StepBack = util.self_function("StepBack", {}, {"ScrollBar"}),
			StepForward = util.self_function("StepForward", {},
					{"ScrollBar"}),
		},
		properties = {
			-- O_HORIZONTAL or O_VERTICAL
			orientation = util.simple_property("number"),
			-- How much there is to scroll through, and where in it we are
			range = util.simple_property("number"),
			value = util.simple_property("number"),
			scrollStep = util.simple_property("number"),
			stepFactor = util.simple_property("number"),
			-- Read-only: the bar's own parts
			effectiveScrollStep = util.simple_property("number"),
			backButton = util.simple_property(dst.Button),
			forwardButton = util.simple_property(dst.Button),
			slider = util.simple_property(dst.Slider),
		},
	})

	util.wc("ProgressBar", {
		inherited_from_by_wrapper = dst.BorderImage,
		instance = {
			ChangeValue = util.self_function("ChangeValue", {},
					{"ProgressBar", "number"}),
		},
		properties = {
			orientation = util.simple_property("number"),
			range = util.simple_property("number"),
			value = util.simple_property("number"),
			knob = util.simple_property(dst.BorderImage),
			-- Read-only: the style the percentage text is drawn with
			loadingPercentStyle = util.simple_property("string"),
			showPercentText = util.simple_property("boolean"),
		},
	})

	-- The content element is the one that scrolls: make it, fill it, and
	-- give it to the view, which clips it and puts bars beside it.
	util.wc("ScrollView", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			-- Which bars are drawn at all, whatever auto-visible would do
			SetScrollBarsVisible = util.self_function("SetScrollBarsVisible",
					{}, {"ScrollView", "boolean", "boolean"}),
		},
		properties = {
			-- How far into the content the top left corner is, in pixels
			viewPosition = util.simple_property(dst.IntVector2),
			contentElement = util.simple_property(dst.UIElement),
			-- Read-only in Urho3D: the bars the view made for itself. A
			-- write here is dropped rather than refused, which is the one
			-- sharp edge of a property list.
			horizontalScrollBar = util.simple_property(dst.ScrollBar),
			verticalScrollBar = util.simple_property(dst.ScrollBar),
			scrollPanel = util.simple_property(dst.BorderImage),
			scrollBarsAutoVisible = util.simple_property("boolean"),
			-- A wheel notch, and a page: fractions of the content
			scrollStep = util.simple_property("number"),
			pageStep = util.simple_property("number"),
			-- What a flick does after the finger leaves, and when it stops
			scrollDeceleration = util.simple_property("number"),
			scrollSnapEpsilon = util.simple_property("number"),
		},
	})

	-- A list of elements with a selection, which is a ScrollView that knows
	-- what is in it. The items are whatever elements the game makes; the
	-- list owns them once they are added.
	util.wc("ListView", {
		inherited_from_by_wrapper = dst.ScrollView,
		instance = {
			AddItem = util.self_function("AddItem", {},
					{"ListView", "UIElement"}),
			InsertItem = util.self_function("InsertItem", {},
					{"ListView", "number", "UIElement"}),
			-- simplified: the by-index form only. Urho3D also removes by
			-- element, and the two are one overloaded name, which a type
			-- check cannot tell apart from here; FindItem() turns an
			-- element into its index, which is the same thing in two calls.
			RemoveItem = util.self_function("RemoveItem", {},
					{"ListView", "number"}),
			RemoveAllItems = util.self_function("RemoveAllItems", {},
					{"ListView"}),
			GetItem = util.wrap_function({"ListView", "number"},
				function(self, index)
					return util.wrap_instance("UIElement", self:GetItem(index))
				end
			),
			FindItem = util.self_function("FindItem", {"number"},
					{"ListView", "UIElement"}),
			SetSelection = util.self_function("SetSelection", {},
					{"ListView", "number"}),
			AddSelection = util.self_function("AddSelection", {},
					{"ListView", "number"}),
			RemoveSelection = util.self_function("RemoveSelection", {},
					{"ListView", "number"}),
			ToggleSelection = util.self_function("ToggleSelection", {},
					{"ListView", "number"}),
			ChangeSelection = util.self_function("ChangeSelection", {},
					{"ListView", "number", {"boolean", "__nil"}}),
			ClearSelection = util.self_function("ClearSelection", {},
					{"ListView"}),
			IsSelected = util.self_function("IsSelected", {"boolean"},
					{"ListView", "number"}),
			-- The hierarchy half, which is what makes a tree out of a list
			Expand = util.self_function("Expand", {},
					{"ListView", "number", "boolean",
					{"boolean", "__nil"}}),
			ToggleExpand = util.self_function("ToggleExpand", {},
					{"ListView", "number", {"boolean", "__nil"}}),
			IsExpanded = util.self_function("IsExpanded", {"boolean"},
					{"ListView", "number"}),
		},
		properties = {
			-- Read-only: how many items, and which one is selected
			numItems = util.simple_property("number"),
			selectedItem = util.simple_property(dst.UIElement),
			selection = util.simple_property("number"),
			-- HM_NEVER, HM_FOCUS or HM_ALWAYS
			highlightMode = util.simple_property("number"),
			multiselect = util.simple_property("boolean"),
			clearSelectionOnDefocus = util.simple_property("boolean"),
			selectOnClickEnd = util.simple_property("boolean"),
			hierarchyMode = util.simple_property("boolean"),
			baseIndent = util.simple_property("number"),
		},
	})

	-- A button that opens something when it is pressed, and the list that
	-- is one. Added 2026-09-15 with the rest of the UI sweep; a menu draws
	-- and computes and does nothing else. The popup is an element the game
	-- makes and hands over, so what a menu opens is the game's own.
	util.wc("Menu", {
		inherited_from_by_wrapper = dst.Button,
		instance = {
			ShowPopup = util.self_function("ShowPopup", {},
					{"Menu", "boolean"}),
			-- Which key opens it without the mouse. The qualifiers are
			-- Urho3D's QUAL_ constants; 0 is none.
			SetAccelerator = util.self_function("SetAccelerator", {},
					{"Menu", "number", "number"}),
		},
		properties = {
			popup = util.simple_property(dst.UIElement),
			-- Where the popup lands relative to the menu
			popupOffset = util.simple_property(dst.IntVector2),
			showPopup = util.simple_property("boolean"),
			-- Read-only: what SetAccelerator was given
			acceleratorKey = util.simple_property("number"),
			acceleratorQualifiers = util.simple_property("number"),
		},
	})

	-- The one a game reaches for: a menu whose popup is a list, which is
	-- what a settings screen is made of. The items are elements the game
	-- makes, as ListView's are.
	util.wc("DropDownList", {
		inherited_from_by_wrapper = dst.Menu,
		instance = {
			AddItem = util.self_function("AddItem", {},
					{"DropDownList", "UIElement"}),
			InsertItem = util.self_function("InsertItem", {},
					{"DropDownList", "number", "UIElement"}),
			-- simplified: the by-index form only, as ListView's is, the two
			-- being one overloaded name that a type check cannot tell apart
			RemoveItem = util.self_function("RemoveItem", {},
					{"DropDownList", "number"}),
			RemoveAllItems = util.self_function("RemoveAllItems", {},
					{"DropDownList"}),
			SetSelection = util.self_function("SetSelection", {},
					{"DropDownList", "number"}),
			GetItem = util.wrap_function({"DropDownList", "number"},
				function(self, index)
					return util.wrap_instance("UIElement", self:GetItem(index))
				end
			),
		},
		properties = {
			-- Read-only: how many, which one, and the parts it is made of
			numItems = util.simple_property("number"),
			selectedItem = util.simple_property(dst.UIElement),
			listView = util.simple_property(dst.ListView),
			placeholder = util.simple_property(dst.UIElement),
			selection = util.simple_property("number"),
			-- What it says with nothing chosen
			placeholderText = util.simple_property("string"),
			-- Whether the popup takes the list's width or the button's
			resizePopup = util.simple_property("boolean"),
		},
	})

	-- What hangs under the pointer after it has rested a moment. The
	-- element it shows is a child of it, which the game makes.
	util.wc("ToolTip", {
		inherited_from_by_wrapper = dst.UIElement,
		properties = {
			-- Seconds of rest before it appears
			delay = util.simple_property("number"),
		},
	})

	-- The pointer itself, as an element the style sheet draws. A game can
	-- say which named shape it is wearing; **DefineShape is not here**,
	-- because it takes an Image and images are not on this whitelist yet.
	util.wc("Cursor", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
			shape = util.simple_property("string"),
			-- The system's own arrow instead of the style's, which is a
			-- look rather than a reach: the shape is still Urho3D's list
			useSystemShapes = util.simple_property("boolean"),
		},
	})

	-- Text in the world rather than on the screen: a nameplate over a
	-- player, a sign a game can read from a distance. A Drawable, so it
	-- goes on a scene node and not in the UI tree.
	util.wc("Text3D", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			SetFont = util.self_function("SetFont", {"boolean"},
					{"Text3D", "Font", {"number", "__nil"}}),
			SetAlignment = util.self_function("SetAlignment", {},
					{"Text3D", "number", "number"}),
			SetColor = util.self_function("SetColor", {},
					{"Text3D", "Color"}),
		},
		properties = {
			text = util.simple_property("string"),
			-- **A font has to be set before this does anything.**
			-- Text::SetFontSize() begins "Initial font must be set" and
			-- returns false without one, so a size written first is
			-- silently the default. SetFont() takes both at once.
			fontSize = util.simple_property("number"),
			-- Wrapped at this many pixels of its own space, 0 for not
			width = util.simple_property("number"),
			wordwrap = util.simple_property("boolean"),
			-- Whether it is always the same size on the screen however far
			-- away it is, and which way it turns to face the camera
			fixedScreenSize = util.simple_property("boolean"),
			faceCameraMode = util.simple_property("number"),
			opacity = util.simple_property("number"),
			-- An outline or a shadow, which is what makes text readable
			-- over a world it has no control over
			textEffect = util.simple_property("number"),
			effectColor = util.simple_property(dst.Color),
			effectStrokeThickness = util.simple_property("number"),
			material = util.simple_property(dst.Material),
		},
	})

	-- Looked at and refused, so that the next sweep does not look again.
	-- util/whitelist_sweep.py reads these lines, so the shape is fixed:
	-- "-- refused: <Class> -- <why>", one per line.
	--
	-- refused: FileSelector -- shows the user's own filesystem, and hands the chosen path back
	-- refused: HierarchyContainer -- ListView makes its own; a game never does
	-- refused: MessageBox -- its constructor wants the engine context and it loads a layout resource by name; ui_utils.show_message_dialog is the dialog here

	-- IO, which is the shape this policy exists to refuse: a game's data is
	-- what the server sends it and what the resource cache serves it, and
	-- neither of those is a path.
	--
	-- refused: File -- opens a path on the user's disk and reads or writes it
	-- refused: FileSystem -- lists, copies, deletes and renames the user's own files, and runs a program
	-- refused: NamedPipe -- a pipe is a path, and the other end is another program
	-- refused: PackageFile -- opens an archive by path, and the resource cache is how a game's media arrives
	-- refused: Deserializer -- the base a File is one of, so wrapping it hands over every File method
	-- refused: Serializer -- the same, the writing half
	-- refused: Log -- writes the engine's own log file and can be pointed at a path; buildat.Logger is the log here

	-- Engine, which is the process rather than the scene.
	--
	-- refused: Engine -- exits the process, sets the engine's own parameters and dumps its resources
	-- refused: Console -- an in-engine command line that runs script, which is what the sandbox exists to stop
	-- refused: DebugHud -- draws the engine's own profiler over the game, and a game has no say in it

	-- Core, which is the engine itself.
	--
	-- refused: Context -- the engine context: every subsystem, whitelisted or not, is one GetSubsystem() away
	-- refused: Object -- the base every wrapped class already inherits from, and its SendEvent() reaches events safe_events.lua does not list

	-- And the attribute family, which is one bypass in three shapes: an
	-- attribute is reached by its name as a string, so anything that
	-- animates or writes one reaches every property this file leaves out.
	--
	-- refused: Serializable -- reads and writes any attribute by name, whitelisted or not
	-- refused: ValueAnimation -- the value an attribute takes over time, set by that attribute's name
	-- refused: ObjectAnimation -- a table of those, applied to a node by name

	util.wc("Sprite", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			SetTexture = util.self_function(
					"SetTexture", {}, {"Sprite", "Texture"}),
			SetFixedSize = util.self_function(
					"SetFixedSize", {}, {"Sprite", "number", "number"}),
		},
		properties = {
			-- A Sprite is the one UI element Urho3D turns, which is what a
			-- compass needs: the rotation is in degrees and the hot spot is
			-- the point it turns about, in the sprite's own pixels.
			rotation = util.simple_property("number"),
			hotSpot = util.simple_property(dst.IntVector2),
		},
	})

	util.wc("UI", {
		instance = {
			SetFocusElement = util.wrap_function({"UI", {"UIElement", "__nil"}},
				function(self, element)
					if element == nil then
						self:SetFocusElement(nil)
					else
						self:SetFocusElement(element)
					end
				end
			),
			SetScale = util.wrap_function({"UI", "number"},
				function(self, scale)
					__buildat_set_ui_scale(scale)
				end),
			GetScale = util.self_function(
					"GetScale", {"number"}, {"UI"}),
		},
		properties = {
			root = util.simple_property(dst.UIElement),
			focusElement = util.simple_property({dst.UIElement, "__nil"}),
			scale = {
				get = function(current_value)
					return current_value
				end,
				set = function(new_value)
					if type(new_value) ~= "number" then
						error("UI.scale must be a number")
					end
					__buildat_set_ui_scale(new_value)
					return new_value
				end,
			},
		},
	})

	-- A scripted client (bin/buildat -c) never hides or captures the
	-- cursor. Its mouse_move is injected and relative, so a game loses
	-- nothing; the person whose desktop the run shares keeps their cursor,
	-- which the re-show after a hide used to warp to the window's corner.
	-- See [SCRIPTED_CURSOR] in doc/plan/miscellaneous_plan.md.
	local scripted = __buildat_is_scripted()
	util.wc("Input", {
		instance = {
			SetMouseVisible = util.wrap_function({"Input", "boolean"},
				function(self, enable)
					if scripted and not enable then
						return
					end
					-- Left false in a scripted run, so init.lua's
					-- click-to-recapture stays inert too
					if util.mouse then
						util.mouse.hide_wanted = not enable
					end
					self:SetMouseVisible(enable)
				end),
			SetMouseMode = util.wrap_function({"Input", "number"},
				function(self, mode)
					if scripted and (mode == MM_RELATIVE or mode == MM_WRAP) then
						return
					end
					self:SetMouseMode(mode)
				end),
			GetKeyDown = util.self_function("GetKeyDown", {"boolean"}, {"Input", "number"}),
			GetKeyPress = util.self_function("GetKeyPress", {"boolean"}, {"Input", "number"}),
			GetMouseMove = util.self_function("GetMouseMove", {dst.IntVector2}, {"Input"}),
			-- Whether a mouse button is held, which the click events do not
			-- say: a dig is held down rather than clicked
			GetMouseButtonDown = util.self_function("GetMouseButtonDown",
					{"boolean"}, {"Input", "number"}),
		},
	})

	util.wc("PhysicsWorld", {
		inherited_from_by_wrapper = dst.Component,
	})

	-- Pixels in memory. Added 2026-09-15 for the cube map a game's own six
	-- sky textures make; see [SKY_LEFTOVERS] in doc/plan/master_plan.md.
	--
	-- **What is deliberately not here is every method that names a file.**
	-- Image has SaveBMP, SavePNG, SaveTGA, SaveJPG, SaveDDS, SaveWEBP and
	-- LoadColorLUT, and all of them take a path from their caller: a server's
	-- Lua writing where it likes is the first disqualifier in
	-- [WHITELIST_POLICY]. What is here reads and writes pixels and nothing
	-- else. An image comes from the resource cache, which only looks in the
	-- directories the client registered, or is made empty and filled.
	util.wc("Image", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("Image", Image:new())
			end,
		},
		instance = {
			-- components is 1 to 4: luminance, luminance and alpha, rgb, rgba
			SetSize = util.self_function("SetSize", {"boolean"},
					{"Image", "number", "number", "number"}),
			SetPixel = util.self_function("SetPixel", {},
					{"Image", "number", "number", "Color"}),
			GetPixel = util.self_function("GetPixel", {dst.Color},
					{"Image", "number", "number"}),
			-- Scaled rather than cropped, which is what a cube map face
			-- wants when a game's textures are not all one size
			Resize = util.self_function("Resize", {"boolean"},
					{"Image", "number", "number"}),
			Clear = util.self_function("Clear", {}, {"Image", "Color"}),
			FlipVertical = util.self_function("FlipVertical", {"boolean"},
					{"Image"}),
			FlipHorizontal = util.self_function("FlipHorizontal",
					{"boolean"}, {"Image"}),
		},
		properties = {
			-- All read-only in Urho3D: what the image turned out to be
			width = util.simple_property("number"),
			height = util.simple_property("number"),
			components = util.simple_property("number"),
			compressed = util.simple_property("boolean"),
		},
	})

	-- Six square faces around a point, which is what a sky is drawn on.
	-- SetData sizes the cube from face 0 and refuses a face that does not
	-- match it, so the order is FACE_POSITIVE_X first and every face the
	-- same square.
	util.wc("TextureCube", {
		inherited_from_by_wrapper = dst.Texture,
		class = {
			new = function()
				return util.wrap_instance("TextureCube", TextureCube:new())
			end,
		},
		instance = {
			SetData = util.self_function("SetData", {"boolean"},
					{"TextureCube", "number", "Image"}),
			-- SetSize(size, format, usage): TEXTURE_RENDERTARGET makes the
			-- six faces drawable, each through GetRenderSurface(face)
			SetSize = util.self_function("SetSize", {"boolean"},
					{"TextureCube", "number", "number", "number"}),
			GetRenderSurface = util.wrap_function({"TextureCube", "number"},
				function(self, face)
					return util.wrap_instance("RenderSurface",
							self:GetRenderSurface(face))
				end),
		},
	})

	-- What a ParticleEmitter emits, and the only way to say it: an effect
	-- built here rather than loaded from a resource, because the description
	-- comes over the network. EmitterType is 0 for a sphere and 1 for a box.
	util.wc("ParticleEffect", {
		inherited_from_by_wrapper = dst.Resource,
		class = {
			new = function()
				return util.wrap_instance("ParticleEffect",
						ParticleEffect:new())
			end,
		},
		instance = {
			AddColorTime = util.self_function("AddColorTime", {},
					{"ParticleEffect", "Color", "number"}),
			-- One frame of a texture animation: the part of the image, and
			-- how many seconds into a particle's life it is shown from
			AddTextureTime = util.self_function("AddTextureTime", {},
					{"ParticleEffect", "Rect", "number"}),
			-- The vector-valued fields are functions rather than properties
			-- because tolua++ generates no setter for a property whose type
			-- is a const reference: Urho3D's own binding registers
			-- ("minDirection", getter, NULL). Assigning the property writes
			-- nowhere and reads back what was assigned, so the effect keeps
			-- Urho3D's defaults and every particle flies off in a random
			-- direction at the default size. Every `const Vector3&` and
			-- `const Vector2&` property in these bindings is like that.
			SetEmitterSize = util.self_function("SetEmitterSize", {},
					{"ParticleEffect", "Vector3"}),
			SetMinDirection = util.self_function("SetMinDirection", {},
					{"ParticleEffect", "Vector3"}),
			SetMaxDirection = util.self_function("SetMaxDirection", {},
					{"ParticleEffect", "Vector3"}),
			SetConstantForce = util.self_function("SetConstantForce", {},
					{"ParticleEffect", "Vector3"}),
			SetMinParticleSize = util.self_function("SetMinParticleSize", {},
					{"ParticleEffect", "Vector2"}),
			SetMaxParticleSize = util.self_function("SetMaxParticleSize", {},
					{"ParticleEffect", "Vector2"}),
		},
		properties = {
			material = util.simple_property(dst.Material),
			numParticles = util.simple_property("number"),
			emitterType = util.simple_property("number"),
			emitterSize = {get = util.simple_property(dst.Vector3).get},
			minDirection = {get = util.simple_property(dst.Vector3).get},
			maxDirection = {get = util.simple_property(dst.Vector3).get},
			constantForce = {get = util.simple_property(dst.Vector3).get},
			dampingForce = util.simple_property("number"),
			activeTime = util.simple_property("number"),
			inactiveTime = util.simple_property("number"),
			minEmissionRate = util.simple_property("number"),
			maxEmissionRate = util.simple_property("number"),
			minParticleSize = {get = util.simple_property(dst.Vector2).get},
			maxParticleSize = {get = util.simple_property(dst.Vector2).get},
			minTimeToLive = util.simple_property("number"),
			maxTimeToLive = util.simple_property("number"),
			minVelocity = util.simple_property("number"),
			maxVelocity = util.simple_property("number"),
			minRotation = util.simple_property("number"),
			maxRotation = util.simple_property("number"),
			minRotationSpeed = util.simple_property("number"),
			maxRotationSpeed = util.simple_property("number"),
			sizeAdd = util.simple_property("number"),
			sizeMul = util.simple_property("number"),
			relative = util.simple_property("boolean"),
			scaled = util.simple_property("boolean"),
			sorted = util.simple_property("boolean"),
			updateInvisible = util.simple_property("boolean"),
		},
	})

	util.wc("Animation", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("Sound", {
		inherited_from_by_wrapper = dst.Resource,
		properties = {
			looped = util.simple_property("boolean"),
			length = util.simple_property("number"),
			frequency = util.simple_property("number"),
		},
	})

	util.wc("SoundSource", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			Play = util.self_function(
					"Play", {}, {"SoundSource", "Sound"}),
			Stop = util.self_function("Stop", {}, {"SoundSource"}),
		},
		properties = {
			gain = util.simple_property("number"),
			frequency = util.simple_property("number"),
			panning = util.simple_property("number"),
			soundType = util.simple_property("string"),
			autoRemoveMode = util.simple_property("number"),
			playing = util.simple_property("boolean"),
		},
	})

	util.wc("SoundSource3D", {
		inherited_from_by_wrapper = dst.SoundSource,
		properties = {
			nearDistance = util.simple_property("number"),
			farDistance = util.simple_property("number"),
			innerAngle = util.simple_property("number"),
			outerAngle = util.simple_property("number"),
			rolloffFactor = util.simple_property("number"),
		},
	})

	util.wc("SoundListener", {
		inherited_from_by_wrapper = dst.Component,
	})

	-- The engine's clock: how long it has run, this frame's step and its
	-- number. Reads nothing but time, which is the policy's clearest yes
	-- ([URHO_SWEEP]); what wants it is anything paced by wall time rather
	-- than by a scene's own clock -- a reflection cube re-rendered once a
	-- second. Not the static system-time getters: a game has os.time().
	util.wc("Time", {
		instance = {
			GetElapsedTime = util.self_function("GetElapsedTime", {"number"},
					{"Time"}),
		},
		properties = {
			frameNumber = util.simple_property("number"),
			timeStep = util.simple_property("number"),
		},
	})

	util.wc("Audio", {
		instance = {
			-- Urho3D multiplies a type's gain by the "Master" one, so the
			-- master is the user's volume preference and not a game's to
			-- write. "Effect", "Music", "Ambient" and "Voice" are what a
			-- game's own mixing is for, and they multiply under it.
			SetMasterGain = util.wrap_function(
					{"Audio", "string", "number"},
					function(self, type_name, gain)
						if type_name == "Master" then
							error("Audio:SetMasterGain(\"Master\") is the"..
									" client's volume preference; use a sound"..
									" type such as \"Effect\" or \"Music\"")
						end
						self:SetMasterGain(type_name, gain)
					end),
			Play = util.self_function("Play", {"boolean"}, {"Audio"}),
			Stop = util.self_function("Stop", {}, {"Audio"}),
		},
		properties = {
			listener = util.simple_property({dst.SoundListener, "__nil"}),
			playing = util.simple_property("boolean"),
		},
	})

	util.wc("Billboard", {
		properties = {
			position = util.simple_property(dst.Vector3),
			size = util.simple_property(dst.Vector2),
			color = util.simple_property(dst.Color),
			rotation = util.simple_property("number"),
			enabled = util.simple_property("boolean"),
		},
	})

	util.wc("BillboardSet", {
		inherited_from_by_wrapper = dst.Drawable,
		instance = {
			Commit = util.self_function("Commit", {}, {"BillboardSet"}),
			GetBillboard = util.wrap_function({"BillboardSet", "number"},
				function(self, index)
					local b = self:GetBillboard(index)
					if b == nil then
						return nil
					end
					return util.wrap_instance("Billboard", b)
				end
			),
		},
		properties = {
			material = util.simple_property(dst.Material),
			numBillboards = util.simple_property("number"),
			sorted = util.simple_property("boolean"),
			relative = util.simple_property("boolean"),
			faceCameraMode = util.simple_property("number"),
		},
	})

	util.wc("ParticleEmitter", {
		inherited_from_by_wrapper = dst.BillboardSet,
		instance = {
			Reset = util.self_function("Reset", {}, {"ParticleEmitter"}),
		},
		properties = {
			effect = util.simple_property(dst.ParticleEffect),
			emitting = util.simple_property("boolean"),
			numParticles = util.simple_property("number"),
		},
	})

	util.wc("Skybox", {
		inherited_from_by_wrapper = dst.StaticModel,
	})

	util.wc("AnimatedModel", {
		inherited_from_by_wrapper = dst.StaticModel,
	})

	util.wc("AnimationController", {
		inherited_from_by_wrapper = dst.Component,
		instance = {
			Play = util.wrap_function({"boolean"},
					{"AnimationController", "string", "number", "boolean",
							{"number", "__nil"}},
				function(self, name, layer, looped, fade)
					if fade ~= nil then
						return self:Play(name, layer, looped, fade)
					end
					return self:Play(name, layer, looped)
				end
			),
			Stop = util.wrap_function({"boolean"},
					{"AnimationController", "string", {"number", "__nil"}},
				function(self, name, fade)
					if fade ~= nil then
						return self:Stop(name, fade)
					end
					return self:Stop(name)
				end
			),
			SetSpeed = util.self_function(
					"SetSpeed", {"boolean"},
					{"AnimationController", "string", "number"}),
			IsPlaying = util.self_function(
					"IsPlaying", {"boolean"},
					{"AnimationController", "string"}),
		},
	})

	util.wc("RibbonTrail", {
		inherited_from_by_wrapper = dst.Drawable,
		properties = {
			material = util.simple_property(dst.Material),
			vertexDistance = util.simple_property("number"),
			width = util.simple_property("number"),
			startColor = util.simple_property(dst.Color),
			endColor = util.simple_property(dst.Color),
			startScale = util.simple_property("number"),
			endScale = util.simple_property("number"),
			trailType = util.simple_property("number"),
			lifetime = util.simple_property("number"),
			emitting = util.simple_property("boolean"),
			sorted = util.simple_property("boolean"),
		},
	})

	dst.cache = util.wrap_instance("ResourceCache", cache)
	dst.renderer = util.wrap_instance("Renderer", renderer)
	dst.graphics = util.wrap_instance("Graphics", graphics)
	dst.ui = util.wrap_instance("UI", ui)
	dst.input = util.wrap_instance("Input", input)
	dst.time = util.wrap_instance("Time", time)
	if audio ~= nil then
		dst.audio = util.wrap_instance("Audio", audio)
	end
end

return M
-- vim: set noet ts=4 sw=4:
