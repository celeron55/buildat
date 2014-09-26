-- Buildat: extension/uistack/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/uistack")
local magic = require("buildat/extension/urho3d")
local dump = buildat.dump
local M = {safe = {}}
log:info("extension/uistack/init.lua: Loading")

local ui_stack_name_i = 1  -- For generating a unique name for each stack
local last_stack_with_pushed_element = nil

function M.UIStack(root)
	local self = {}
	self.root = root
	self.stack_name = "ui_stack_"..ui_stack_name_i
	ui_stack_name_i = ui_stack_name_i + 1
	self.element_name_i = 1
	self.stack = {}
	local current_ui_stack_object = self
	function self:push(options)
		options = options or {}
		if #self.stack >= 1 then
			local top = self.stack[#self.stack]
			top:SetVisible(false)
		end
		local element_name =
				self.stack_name.."_"..#self.stack.."."..self.element_name_i
		if options.description then
			element_name = element_name..": "..options.description
		end
		log:verbose("UIStack:push(): "..dump(element_name))
		local element = self.root:CreateChild("UIElement")
		element:SetName(element_name)
		element:SetStyleAuto()
		element:SetLayout(LM_HORIZONTAL, 0, IntRect(0, 0, 0, 0))
		element:SetAlignment(HA_CENTER, VA_CENTER)
		element:SetFocusMode(FM_FOCUSABLE)
		element:SetFocus(true)
		self.element_name_i = self.element_name_i + 1

		-- Add a recursive version of UIElement::HasFocus() to the pushed root
		-- element which also handles the "no focus" situation as expected
		local function has_plain_recursive_focus(self)
			if self:HasFocus() then return true end
			local n = self:GetNumChildren()
			for i = 0, n-1 do
				local child = self:GetChild(i)
				local child_has_focus = has_plain_recursive_focus(child)
				if child_has_focus then return true end
			end
			return false
		end
		function element.HasRecursiveFocus(self)
			-- If focused element is nil, then assume focus is owned by the
			-- stack on which an element was pushed latest
			local focused_element = ui:GetFocusElement()
			if focused_element == nil then
				if last_stack_with_pushed_element == current_ui_stack_object then
					-- It is this stack; check if self is the top element
					local top = current_ui_stack_object.stack[#current_ui_stack_object.stack]
					if top == self then
						-- Pass
						return true
					end
				end
				return false
			end
			-- Check that self exists as some of this stack's elements. If not,
			-- it is invalid and running HasFocus() on it will cause a segfault.
			local found = false
			for _, k in ipairs(current_ui_stack_object.stack) do
				if k == self then
					found = true
					break
				end
			end
			if not found then
				log:verbose("HasRecursiveFocus called for removed element "..
						dump(self:GetName()).."; ignoring")
				-- Not returning here will cause a NULL dereference in Urho3D
				-- once the garbage collector kicks in
				return
			end
			-- Non-special case
			return has_plain_recursive_focus(self)
		end

		-- Subscribe to event until this stack level is popped out
		element.event_subscriptions = {}
		function element:SubscribeToStackEvent(event_name, callback)
			local cb_name = magic.SubscribeToEvent(event_name,
			function(event_type, event_data)
				if not element:HasRecursiveFocus() then
					return
				end
				callback(event_type, event_data)
			end)
			table.insert(element.event_subscriptions, {
				event_name = event_name,
				cb_name = cb_name
			})
		end

		table.insert(self.stack, element)
		last_stack_with_pushed_element = self
		return element
	end
	function self:pop(current_top_root)
		-- This check should keep things better in sync
		if self.stack[#self.stack] ~= current_top_root then
			error("UIStack:pop(): Wrong current_top_root")
		end
		local top = table.remove(self.stack)
		log:verbose("UIStack:pop(): "..dump(top:GetName()))
		for _, sub in ipairs(top.event_subscriptions) do
			magic.UnsubscribeFromEvent(sub.event_name, sub.cb_name)
		end
		--top:SetVisible(false)
		--top:SetFocus(false)
		self.root:RemoveChild(top)
		if #self.stack >= 1 then
			local top = self.stack[#self.stack]
			top:SetVisible(true)
			top:SetFocus(true)
		end
	end
	return self
end

return M
-- vim: set noet ts=4 sw=4:
