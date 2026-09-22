-- [FORMSPEC_SCROLL]: animated_image and button_url in a form
core.register_on_joinplayer(function(player)
	core.after(3, function()
		core.show_formspec(player:get_player_name(), "formelems_check",
				"size[8,4]" ..
				"animated_image[0.3,0.3;1,1;anim;default_stone.png;4;100;1]" ..
				"button_url[0.3,1.6;7.4,0.9;visit;Read the manual;" ..
				"https://example.org/manual]" ..
				"button_exit[0.3,3;7.4,0.6;done;Done]")
		core.log("action", "formelems: the form is shown")
	end)
end)

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "formelems_check" then
		return
	end
	local got = {}
	for k, v in pairs(fields) do
		got[#got + 1] = k .. "=" .. tostring(v)
	end
	table.sort(got)
	core.log("action", "formelems: fields " .. table.concat(got, " "))
end)
