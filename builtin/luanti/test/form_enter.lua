-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [FORM_ENTER]: a form with a search field in it -- what the client sends
-- when enter is pressed in it, and whether the form stays open. The rows
-- under the field are what the last search answered, so a redraw says the
-- server heard it.
local function spec(query)
	local rows = {}
	for _, name in ipairs({"apple", "apricot", "banana", "cherry"}) do
		if query == "" or name:find(query, 1, true) then
			rows[#rows + 1] = name
		end
	end
	return "size[6,5]" ..
			"field[0.5,0.7;5,0.8;q;Search;" .. core.formspec_escape(query) ..
			"]" ..
			"field_close_on_enter[q;false]" ..
			"label[0.5,1.8;rows " .. #rows .. ": " ..
			core.formspec_escape(table.concat(rows, " ")) .. "]" ..
			"button_exit[0.5,4;5,0.8;done;Done]"
end

core.register_on_joinplayer(function(player)
	core.after(3, function()
		core.show_formspec(player:get_player_name(), "form_enter", spec(""))
		core.log("action", "form_enter: the form is shown")
	end)
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "form_enter" then
		return
	end
	core.log("action", "form_enter: fields key_enter=" ..
			tostring(fields.key_enter) .. " key_enter_field=" ..
			tostring(fields.key_enter_field) .. " q=" .. tostring(fields.q) ..
			" quit=" .. tostring(fields.quit))
	if fields.key_enter and not fields.quit then
		core.show_formspec(player:get_player_name(), "form_enter",
				spec(fields.q or ""))
	end
end)
