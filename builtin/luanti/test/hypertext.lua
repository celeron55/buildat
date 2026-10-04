-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [FORMSPEC_SCROLL]: a form with a hypertext in it, and what the client
-- sends back when one of its actions is clicked
core.register_on_joinplayer(function(player)
	core.after(3, function()
		core.show_formspec(player:get_player_name(), "hypertext_check",
				"size[8,4]" ..
				"hypertext[0.3,0.3;7.4,3;doc;" ..
				"<big>A title</big>\\nSome words in it, and " ..
				"<action name=here>press here</action> to answer.]" ..
				"button_exit[0.5,3.4;7,0.5;done;Done]")
		core.log("action", "hypertext: the form is shown")
	end)
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "hypertext_check" then
		return
	end
	core.log("action", "hypertext: fields doc=" .. tostring(fields.doc))
end)
