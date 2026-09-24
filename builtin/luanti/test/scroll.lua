-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [FORMSPEC_SCROLL]: a form with a scroll_container and its scrollbar
core.register_on_joinplayer(function(player)
	core.after(3, function()
		local labels = {}
		for i = 1, 12 do
			labels[#labels + 1] = string.format("label[0.2,%.1f;row %d]",
					0.3 + (i - 1) * 0.6, i)
		end
		core.show_formspec(player:get_player_name(), "scroll_check",
				"size[6,4]" ..
				"scroll_container[0.3,0.3;5,3;bar;vertical;0.1]" ..
				table.concat(labels) ..
				"scroll_container_end[]" ..
				"scrollbar[5.4,0.3;0.3,3;vertical;bar;0]" ..
				"button_exit[0.5,3.5;5,0.4;done;Done]")
		core.log("action", "scroll: the form is shown")
	end)
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "scroll_check" then
		return
	end
	core.log("action", "scroll: fields bar=" .. tostring(fields.bar))
end)
