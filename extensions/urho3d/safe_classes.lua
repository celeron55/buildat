-- Buildat: extension/urho3d/safe_classes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local M = {}

function M.define(dst, util)
	util.wc("VariantMap", {
		unsafe_constructor = util.wrap_function({},
		function(x, y, z)
			return util.wrap_instance("VariantMap", VariantMap())
		end),
		instance = {
			SetFloat = util.self_function(
					"SetFloat", {}, {"VariantMap", "string", "number"}),
			GetFloat = util.self_function(
					"GetFloat", {"number"}, {"VariantMap", "string"}),
		}
	})

	util.wc("Vector3", {
		unsafe_constructor = util.wrap_function({"number", "number", "number"},
		function(x, y, z)
			return util.wrap_instance("Vector3", Vector3(x, y, z))
		end),
		instance_meta = {
			__mul = util.wrap_function({"Vector3", "number"}, function(self, n)
				return util.wrap_instance("Vector3", self * n)
			end),
		},
		properties = {
			x = util.simple_property("number"),
			y = util.simple_property("number"),
			z = util.simple_property("number"),
		},
	})

	util.wc("Resource", {
	})

	util.wc("Component", {
	})

	util.wc("Octree", {
		inherited_from_by_wrapper = dst.Component,
	})

	util.wc("Drawable", {
		inherited_from_by_wrapper = dst.Component,
	})

	util.wc("Light", {
		inherited_from_by_wrapper = dst.Drawable,
		properties = {
			lightType = util.simple_property("number"),
		},
	})

	util.wc("Camera", {
		inherited_from_by_wrapper = dst.Component,
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
			SetTexture = util.self_function(
					"SetTexture", {}, {"Material", "number", "Texture"}),
			SetTechnique = util.self_function(
					"SetTechnique", {}, {"Material", "number", "Technique",
							{"number", "__nil"}, {"number", "__nil"}}),
		},
	})

	util.wc("Texture", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("Texture2D", {
		inherited_from_by_wrapper = dst.Texture,
	})

	util.wc("Font", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("StaticModel", {
		inherited_from_by_wrapper = dst.Octree,
		properties = {
			model = util.simple_property(dst.Model),
			material = util.simple_property(dst.Material),
		},
	})

	util.wc("Technique", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("Node", {
		instance = {
			CreateComponent = util.wrap_function({"Node", "string"}, function(self, name)
				local component = self:CreateComponent(name)
				assert(component)
				return util.wrap_instance(name, component)
			end),
			GetComponent = util.wrap_function({"Node", "string"}, function(self, name)
				local component = self:GetComponent(name)
				assert(component)
				return util.wrap_instance(name, component)
			end),
			LookAt = util.wrap_function({"Node", "Vector3"}, function(self, p)
				self:LookAt(p)
			end),
			Translate = util.wrap_function({"Node", "Vector3"}, function(self, v)
				self:Translate(v)
			end),
		},
		properties = {
			scale = util.simple_property(dst.Vector3),
			direction = util.simple_property(dst.Vector3),
			position = util.simple_property(dst.Vector3),
		},
	})

	util.wc("Plane", {
	})

	util.wc("Scene", {
		inherited_from_by_wrapper = dst.Node,
		unsafe_constructor = util.wrap_function({}, function()
			return util.wrap_instance("Scene", Scene())
		end),
		instance = {
			CreateChild = util.wrap_function({"Scene", "string"}, function(self, name)
				return util.wrap_instance("Node", self:CreateChild(name))
			end)
		},
	})

	util.wc("ResourceCache", {
		instance = {
			GetResource = util.wrap_function({"ResourceCache", "string", "string"},
			function(self, resource_type, resource_name)
				-- TODO: If resource_type=XMLFile, we probably have to go through it and
				--       resave all references to other files found in there
				resource_name = util.check_safe_resource_name(resource_name)
				util.resave_file(resource_name)
				local res = cache:GetResource(resource_type, resource_name)
				return util.wrap_instance(resource_type, res)
			end),
		},
	})

	util.wc("Viewport", {
		class = {
			new = util.wrap_function({"__to_nil", "Scene", "Camera"},
			function(_, scene, camera_component)
				return util.wrap_instance("Viewport", Viewport:new(scene, camera_component))
			end),
		},
	})

	util.wc("Renderer", {
		instance = {
			SetViewport = util.wrap_function({"Renderer", "number", "Viewport"},
			function(self, index, viewport)
				self:SetViewport(index, viewport)
			end),
		},
	})

	util.wc("Animatable", {
	})

	util.wc("UIElement", {
		inherited_from_by_wrapper = dst.Animatable,
		instance = {
			CreateChild = util.wrap_function({"UIElement", "string", {"string", "__nil"}},
			function(self, element_type, name)
				return util.wrap_instance("UIElement", self:CreateChild(element_type, name))
			end),
			SetText = util.self_function("SetText", {}, {"UIElement", "string"}),
			SetFont = util.self_function("SetFont", {}, {"UIElement", "Font"}),
			SetPosition = util.self_function(
					"SetPosition", {}, {"UIElement", "number", "number"}),
		},
		properties = {
			horizontalAlignment = util.simple_property("number"),
			verticalAlignment = util.simple_property("number"),
			height = util.simple_property("number"),
		},
	})

	util.wc("UI", {
		instance = {
		},
		properties = {
			root = util.simple_property(dst.UIElement),
			focusElement = util.simple_property({dst.UIElement, "__nil"}),
		},
	})

	util.wc("Input", {
		instance = {
			GetKeyDown = util.self_function("GetKeyDown", {"boolean"}, {"Input", "number"}),
		},
	})

	dst.cache = util.wrap_instance("ResourceCache", cache)
	dst.renderer = util.wrap_instance("Renderer", renderer)
	dst.ui = util.wrap_instance("UI", ui)
	dst.input = util.wrap_instance("Input", input)
end

return M
-- vim: set noet ts=4 sw=4:
