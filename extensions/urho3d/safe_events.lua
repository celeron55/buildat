-- Buildat: extension/urho3d/safe_events.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>

return {
	Update = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	PostRenderUpdate = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	KeyDown = {
		Key = {variant = "Int", safe = "number"},
	},
	MouseButtonDown = {
		Button = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	MouseButtonUp = {
		Button = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	MouseMove = {
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
		DX = {variant = "Int", safe = "number"},
		DY = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	MouseWheel = {
		Wheel = {variant = "Int", safe = "number"},
		Buttons = {variant = "Int", safe = "number"},
		Qualifiers = {variant = "Int", safe = "number"},
	},
	HoverBegin = {
	},
	HoverEnd = {
	},
	Released = {
	},
	TextFinished = {
	},
	NodeAdded = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Parent = {variant = "Ptr", safe = "Node"},
		Node = {variant = "Ptr", safe = "Node"},
	},
	NodeRemoved = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Parent = {variant = "Ptr", safe = "Node"},
		Node = {variant = "Ptr", safe = "Node"},
	},
	ComponentAdded = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Node = {variant = "Ptr", safe = "Node"},
		Component = {variant = "Ptr", safe = "Component"},
	},
	ComponentRemoved = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Node = {variant = "Ptr", safe = "Node"},
		Component = {variant = "Ptr", safe = "Component"},
	},
	NodeNameChanged = {
		Scene = {variant = "Ptr", safe = "Scene"},
		Node = {variant = "Ptr", safe = "Node"},
	},
	PhysicsCollision = {
		NodeA = {variant = "Ptr", safe = "Node"},
		NodeB = {variant = "Ptr", safe = "Node"},
		BodyA = {variant = "Ptr", safe = "RigidBody"},
		BodyB = {variant = "Ptr", safe = "RigidBody"},
		Contacts = {variant = "Buffer", safe = "VectorBuffer", get_type = "Buffer"},
	},
}
-- vim: set noet ts=4 sw=4:
