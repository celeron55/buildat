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
	-- The client is going away: the window was closed, or something asked
	-- the engine to exit. It carries nothing; what it is for is closing what
	-- a module opened, such as telling a server that we are leaving.
	ExitRequested = {},
	KeyDown = {
		Key = {variant = "Int", safe = "number"},
		-- True when this is a key repeat rather than a fresh press
		Repeat = {variant = "Bool", safe = "boolean"},
	},
	KeyUp = {
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
	-- A click on the UI, which carries where it landed. MouseButtonDown does
	-- not: the position of a click is the UI's business, and a game that has
	-- put something on screen needs to know where in it the player clicked.
	-- The element that was hit is deliberately not passed on.
	UIMouseClick = {
		X = {variant = "Int", safe = "number"},
		Y = {variant = "Int", safe = "number"},
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
	-- The window's size or fullscreen state changed. What wants to know is
	-- anything that put something on the GPU by hand: Urho3D can bring back
	-- what it loaded from a file, and nothing else.
	ScreenMode = {
		Width = {variant = "Int", safe = "number"},
		Height = {variant = "Int", safe = "number"},
		Fullscreen = {variant = "Bool", safe = "boolean"},
		Resizable = {variant = "Bool", safe = "boolean"},
		Borderless = {variant = "Bool", safe = "boolean"},
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
	PhysicsPreStep = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	PhysicsCollision = {
		NodeA = {variant = "Ptr", safe = "Node"},
		NodeB = {variant = "Ptr", safe = "Node"},
		BodyA = {variant = "Ptr", safe = "RigidBody"},
		BodyB = {variant = "Ptr", safe = "RigidBody"},
		Contacts = {variant = "Buffer", safe = "VectorBuffer", get_type = "Buffer"},
	},
	PhysicsPostStep = {
		TimeStep = {variant = "Float", safe = "number"},
	},
	SoundFinished = {
		Node = {variant = "Ptr", safe = "Node"},
		SoundSource = {variant = "Ptr", safe = "SoundSource"},
		Sound = {variant = "Ptr", safe = "Sound"},
	},
}
-- vim: set noet ts=4 sw=4:
