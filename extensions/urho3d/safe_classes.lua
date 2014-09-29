-- Buildat: extension/urho3d/safe_classes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local dump = buildat.dump
local log = buildat.Logger("safe_classes")
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
			SetInt = util.self_function(
					"SetInt", {}, {"VariantMap", "string", "number"}),
			GetInt = util.self_function(
					"GetInt", {"number"}, {"VariantMap", "string"}),
			SetString = util.self_function(
					"SetString", {}, {"VariantMap", "string", "string"}),
			GetString = util.self_function(
					"GetString", {"string"}, {"VariantMap", "string"}),
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

	util.wc("BiasParameters", {
		unsafe_constructor = util.wrap_function({"number", "number"},
		function(constant_bias, slope_scaled_bias)
			return util.wrap_instance("BiasParameters",
					BiasParameters(constant_bias, slope_scaled_bias))
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
			brightness = util.simple_property("number"),
			castShadows = util.simple_property("boolean"),
			shadowBias = util.simple_property("BiasParameters"),
			shadowCascade = util.simple_property("CascadeParameters"),
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

	util.wc("XMLFile", {
		inherited_from_by_wrapper = dst.Resource,
	})

	util.wc("StaticModel", {
		inherited_from_by_wrapper = dst.Octree,
		properties = {
			model = util.simple_property(dst.Model),
			material = util.simple_property(dst.Material),
			castShadows = util.simple_property("boolean"),
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
			CreateChild = util.wrap_function({"Node", "string"}, function(self, name)
				return util.wrap_instance("Node", self:CreateChild(name))
			end),
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
			RemoveChild = util.wrap_function({"Node", "Node"}, function(self, v)
				self:RemoveChild(v)
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
		class = {
			new = function()
				return util.wrap_instance("Scene", Scene:new())
			end,
		},
		inherited_from_by_wrapper = dst.Node,
		unsafe_constructor = util.wrap_function({}, function()
			return util.wrap_instance("Scene", Scene())
		end),
	})

	util.wc("ResourceCache", {
		instance = {
			GetResource = util.wrap_function({"ResourceCache", "string", "string"},
			function(self, resource_type, unsafe_resource_name)
				-- NOTE: resource_type=XMLFile can refer to other resources even
				-- in absolute and arbitrary relative paths. Make sure file
				-- access (fopen()) is sandboxed appropriately.
				resource_name = util.check_safe_resource_name(unsafe_resource_name)
				log:debug("GetResource: "..dump(unsafe_resource_name)..
						" -> "..dump(resource_name))
				local saved_path = util.resave_file(resource_name)
				-- Note: saved_path is ignored
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
			CreateChild = util.wrap_function({"UIElement", "string",
					{"string", "__nil"}},
				function(self, element_type, name)
					return util.wrap_instance(element_type,
							self:CreateChild(element_type, name))
				end
			),
			GetChild = util.wrap_function({"UIElement", {"string", "number"}},
				function(self, name_or_index)
					return util.wrap_instance("UIElement",
							self:GetChild(name_or_index))
				end
			),
			GetNumChildren = util.self_function(
					"GetNumChildren", {"number"}, {"UIElement"}),
			RemoveChild = util.wrap_function({"UIElement", "UIElement"},
				function(self, child)
					self:RemoveChild(child)
				end
			),
			SetName = util.self_function("SetName", {}, {"UIElement", "string"}),
			SetText = util.self_function("SetText", {}, {"UIElement", "string"}),
			SetFont = util.self_function("SetFont", {}, {"UIElement", "Font"}),
			SetPosition = util.self_function(
					"SetPosition", {}, {"UIElement", "number", "number"}),
			SetStyleAuto = util.self_function("SetStyleAuto", {}, {"UIElement"}),
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
			GetText = util.self_function("GetText", {"string"}, {"UIElement"}),
		},
		properties = {
			horizontalAlignment = util.simple_property("number"),
			verticalAlignment = util.simple_property("number"),
			height = util.simple_property("number"),
			color = util.simple_property("Color"),
			minHeight = util.simple_property("number"),
			minWidth = util.simple_property("number"),
			defaultStyle = util.simple_property("XMLFile"),
		},
	})

	util.wc("Text", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			SetTextAlignment = util.self_function(
					"SetTextAlignment", {}, {"UIElement", "number"}),
		},
		properties = {
			text = util.simple_property("string"),
		},
	})

	util.wc("BorderImage", {
		inherited_from_by_wrapper = dst.UIElement,
	})

	util.wc("Window", {
		inherited_from_by_wrapper = dst.BorderImage,
	})

	util.wc("Button", {
		inherited_from_by_wrapper = dst.BorderImage,
	})

	util.wc("LineEdit", {
		inherited_from_by_wrapper = dst.BorderImage,
		properties = {
		},
	})

	util.wc("Sprite", {
		inherited_from_by_wrapper = dst.UIElement,
		instance = {
			SetTexture = util.self_function(
					"SetTexture", {}, {"Sprite", "Texture"}),
			SetFixedSize = util.self_function(
					"SetFixedSize", {}, {"Sprite", "number", "number"}),
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
