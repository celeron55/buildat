-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [FORMSPEC_SCROLL]: a form with a dropdown in it, and what the client
-- sends back when one is picked
core.register_on_joinplayer(function(player)
	core.after(3, function()
		core.show_formspec(player:get_player_name(), "dropdown_check",
				"size[6,4]" ..
				"dropdown[0.5,0.5;5;pick;alpha,beta,gamma;1]" ..
				"button_exit[0.5,3;5,0.8;done;Done]")
		core.log("action", "dropdown: the form is shown")
	end)
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "dropdown_check" then
		return
	end
	core.log("action", "dropdown: fields pick=" .. tostring(fields.pick))
end)
