-- Buildat: extension/urho3d
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/urho3d")
local dump = buildat.dump
local magic_sandbox = require("buildat/extension/magic_sandbox")
local M = {safe = {}}

--
-- ResourceCache support code
--

-- Checks that this is not an absolute file path or anything funny
local allowed_name_pattern = '^[a-zA-Z0-9][a-zA-Z0-9/._ ]*$'
function M.check_safe_resource_name(name)
	if type(name) ~= "string" then
		error("Unsafe resource name: "..dump(name).." (not string)")
	end
	if string.match(name, '^/.*$') then
		error("Unsafe resource name: "..dump(name).." (absolute path)")
	end
	if not string.match(name, allowed_name_pattern) then
		error("Unsafe resource name: "..dump(name).." (unneeded chars)")
	end
	if string.match(name, '[.][.]') then
		error("Unsafe resource name: "..dump(name).." (contains ..)")
	end
	log:verbose("Safe resource name: "..name)
	return name
end

-- Basic tests
assert(pcall(function()
	M.check_safe_resource_name("/etc/passwd")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name(" /etc/passwd")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("\t /etc/passwd")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("Models/Box.mdl")
end) == true)
assert(pcall(function()
	M.check_safe_resource_name("Fonts/Anonymous Pro.ttf")
end) == true)
assert(pcall(function()
	M.check_safe_resource_name("test1/pink_texture.png")
end) == true)
assert(pcall(function()
	M.check_safe_resource_name(" Box.mdl ")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("../../foo")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("abc$de")
end) == false)

local hack_resaved_files = {}  -- name -> temporary target file

-- Create temporary file with wanted file name to make Urho3D load it correctly
function M.resave_file(resource_name)
	M.check_safe_resource_name(resource_name)
	local path2 = hack_resaved_files[resource_name]
	if path2 == nil then
		local path = __buildat_get_file_path(resource_name)
		if path == nil then
			return nil
		end
		path2 = __buildat_get_path("tmp").."/"..resource_name
		dir2 = string.match(path2, '^(.*)/.+$')
		if dir2 then
			if not __buildat_mkdir(dir2) then
				error("Failed to create directory: \""..dir2.."\"")
			end
		end
		log:info("Temporary path: "..path2)
		local src = io.open(path, "rb")
		local dst = io.open(path2, "wb")
		while true do
			local buf = src:read(100000)
			if buf == nil then break end
			dst:write(buf)
		end
		src:close()
		dst:close()
		hack_resaved_files[resource_name] = path2
	end
	return path2
end

-- Callback from core
function __buildat_file_updated_in_cache(name, hash, cached_path)
	log:debug("__buildat_file_updated_in_cache(): name="..dump(name)..
			", cached_path="..dump(cached_path))
	if hack_resaved_files[name] then
		log:verbose("__buildat_file_updated_in_cache(): Re-saving: "..dump(name))
		hack_resaved_files[name] = nil -- Force re-copy
		M.resave_file(name)
	end
end

--
-- Safe interface
--

local function wc(name, def)
	M.safe[name] = magic_sandbox.wrap_class(name, def)
end

local function wrap_instance(name, instance)
	local class = M.safe[name]
	local class_meta = getmetatable(class)
	if not class_meta then error(dump(name).." is not a whitelisted class") end
	return class_meta.wrap(instance)
end

-- (return_types, param_types, f) or (param_types, f)
local function wrap_function(return_types, param_types, f)
	if type(param_types) == 'function' and f == nil then
		f = param_types
		param_types = return_types
		return_types = {"__safe"}
	end
	return function(...)
		local checked_arg = {}
		for i = 1, #param_types do
			checked_arg[i] = magic_sandbox.safe_to_unsafe(arg[i], param_types[i])
		end
		local wrapped_ret = {}
		local ret = {f(unpack(checked_arg, 1, table.maxn(checked_arg)))}
		for i = 1, #return_types do
			wrapped_ret[i] = magic_sandbox.unsafe_to_safe(ret[i], return_types[i])
		end
		return unpack(wrapped_ret, 1, #return_types)
	end
end

local function self_function(function_name, return_types, param_types)
	return function(...)
		if #param_types < 1 then
			error("At least one argument required (self)")
		end
		local checked_arg = {}
		for i = 1, #param_types do
			checked_arg[i] = magic_sandbox.safe_to_unsafe(arg[i], param_types[i])
		end
		local wrapped_ret = {}
		local self = checked_arg[1]
		local f = self[function_name]
		if type(f) ~= 'function' then
			error(dump(function_name).." not found in instance")
		end
		local ret = {f(unpack(checked_arg, 1, table.maxn(checked_arg)))}
		for i = 1, #return_types do
			wrapped_ret[i] = magic_sandbox.unsafe_to_safe(ret[i], return_types[i])
		end
		return unpack(wrapped_ret, 1, #return_types)
	end
end

local function simple_property(valid_types)
	return {
		get = function(current_value)
			return magic_sandbox.unsafe_to_safe(current_value, valid_types)
		end,
		set = function(new_value)
			return magic_sandbox.safe_to_unsafe(new_value, valid_types)
		end,
	}
end

local safe_globals = {
	-- BlendMode
	"BLEND_REPLACE",
	"BLEND_ADD",
	"BLEND_MULTIPLY",
	"BLEND_ALPHA",
	"BLEND_ADDALPHA",
	"BLEND_PREMULALPHA",
	"BLEND_INVDESTALPHA",
	"BLEND_SUBTRACT",
	"BLEND_SUBTRACTALPHA",
	"MAX_BLENDMODES",

	-- BodyType2D
	"BT_STATIC",
	"BT_DYNAMIC",
	"BT_KINEMATIC",

	-- CollisionEventMode
	"COLLISION_NEVER",
	"COLLISION_ACTIVE",
	"COLLISION_ALWAYS",

	-- CompareMode
	"CMP_ALWAYS",
	"CMP_EQUAL",
	"CMP_NOTEQUAL",
	"CMP_LESS",
	"CMP_LESSEQUAL",
	"CMP_GREATER",
	"CMP_GREATEREQUAL",
	"MAX_COMPAREMODES",

	-- CompressedFormat
	"CF_NONE",
	"CF_DXT1",
	"CF_DXT3",
	"CF_DXT5",
	"CF_ETC1",
	"CF_PVRTC_RGB_2BPP",
	"CF_PVRTC_RGBA_2BPP",
	"CF_PVRTC_RGB_4BPP",
	"CF_PVRTC_RGBA_4BPP",

	-- ConstraintType
	"CONSTRAINT_POINT",
	"CONSTRAINT_HINGE",
	"CONSTRAINT_SLIDER",
	"CONSTRAINT_CONETWIST",

	-- Corner
	"C_TOPLEFT",
	"C_TOPRIGHT",
	"C_BOTTOMLEFT",
	"C_BOTTOMRIGHT",
	"MAX_UIELEMENT_CORNERS",

	-- CreateMode
	"REPLICATED",
	"LOCAL",

	-- CubeMapFace
	"FACE_POSITIVE_X",
	"FACE_NEGATIVE_X",
	"FACE_POSITIVE_Y",
	"FACE_NEGATIVE_Y",
	"FACE_POSITIVE_Z",
	"FACE_NEGATIVE_Z",
	"MAX_CUBEMAP_FACES",

	-- CullMode
	"CULL_NONE",
	"CULL_CCW",
	"CULL_CW",
	"MAX_CULLMODES",

	-- CursorShape
	"CS_NORMAL",
	"CS_RESIZEVERTICAL",
	"CS_RESIZEDIAGONAL_TOPRIGHT",
	"CS_RESIZEHORIZONTAL",
	"CS_RESIZEDIAGONAL_TOPLEFT",
	"CS_ACCEPTDROP",
	"CS_REJECTDROP",
	"CS_BUSY",
	"CS_MAX_SHAPES",

	-- EmitterType
	"EMITTER_SPHERE",
	"EMITTER_BOX",

	-- EmitterType2D
	"EMITTER_TYPE_GRAVITY",
	"EMITTER_TYPE_RADIAL",

	-- FaceCameraMode
	"FC_NONE",
	"FC_ROTATE_XYZ",
	"FC_ROTATE_Y",
	"FC_LOOKAT_XYZ",
	"FC_LOOKAT_Y",

	-- FileMode
	"FILE_READ",
	"FILE_WRITE",
	"FILE_READWRITE",

	-- FillMode
	"FILL_SOLID",
	"FILL_WIREFRAME",
	"FILL_POINT",

	-- FocusMode
	"FM_NOTFOCUSABLE",
	"FM_RESETFOCUS",
	"FM_FOCUSABLE",
	"FM_FOCUSABLE_DEFOCUSABLE",

	-- FrustumPlane
	"PLANE_NEAR",
	"PLANE_LEFT",
	"PLANE_RIGHT",
	"PLANE_UP",
	"PLANE_DOWN",
	"PLANE_FAR",

	-- GeometryType
	"GEOM_STATIC",
	"GEOM_SKINNED",
	"GEOM_INSTANCED",
	"GEOM_BILLBOARD",
	"GEOM_STATIC_NOINSTANCING",
	"MAX_GEOMETRYTYPES",

	-- HighlightMode
	"HM_NEVER",
	"HM_FOCUS",
	"HM_ALWAYS",

	-- HorizontalAlignment
	"HA_LEFT",
	"HA_CENTER",
	"HA_RIGHT",

	-- HttpRequestState
	"HTTP_INITIALIZING",
	"HTTP_ERROR",
	"HTTP_OPEN",
	"HTTP_CLOSED",

	-- InterpMethod
	"IM_LINEAR",
	"IM_SPLINE",

	-- InterpolationMode
	"BEZIER_CURVE",

	-- Intersection
	"OUTSIDE",
	"INTERSECTS",
	"INSIDE",

	-- JSONValueType
	"JSON_ANY",
	"JSON_OBJECT",
	"JSON_ARRAY",

	-- LayoutMode
	"LM_FREE",
	"LM_HORIZONTAL",
	"LM_VERTICAL",

	-- LightType
	"LIGHT_DIRECTIONAL",
	"LIGHT_SPOT",
	"LIGHT_POINT",

	-- LoadMode
	"LOAD_RESOURCES_ONLY",
	"LOAD_SCENE",
	"LOAD_SCENE_AND_RESOURCES",

	-- LockState
	"LOCK_NONE",
	"LOCK_HARDWARE",
	"LOCK_SHADOW",
	"LOCK_SCRATCH",

	-- LoopMode2D
	"LM_DEFAULT",
	"LM_FORCE_LOOPED",
	"LM_FORCE_CLAMPED",

	-- Orientation
	"O_HORIZONTAL",
	"O_VERTICAL",

	-- Orientation2D
	"O_ORTHOGONAL",
	"O_ISOMETRIC",
	"O_STAGGERED",

	-- PassLightingMode
	"LIGHTING_UNLIT",
	"LIGHTING_PERVERTEX",
	"LIGHTING_PERPIXEL",

	-- PrimitiveType
	"TRIANGLE_LIST",
	"LINE_LIST",
	"POINT_LIST",
	"TRIANGLE_STRIP",
	"LINE_STRIP",
	"TRIANGLE_FAN",

	-- RayQueryLevel
	"RAY_AABB",
	"RAY_OBB",
	"RAY_TRIANGLE",

	-- RenderSurfaceUpdateMode
	"SURFACE_MANUALUPDATE",
	"SURFACE_UPDATEVISIBLE",
	"SURFACE_UPDATEALWAYS",

	-- ShaderParameterGroup
	"SP_FRAME",
	"SP_CAMERA",
	"SP_VIEWPORT",
	"SP_ZONE",
	"SP_LIGHT",
	"SP_VERTEXLIGHTS",
	"SP_MATERIAL",
	"SP_OBJECTTRANSFORM",
	"MAX_SHADER_PARAMETER_GROUPS",

	-- ShaderType
	"VS",
	"PS",

	-- ShapeType
	"SHAPE_BOX",
	"SHAPE_SPHERE",
	"SHAPE_STATICPLANE",
	"SHAPE_CYLINDER",
	"SHAPE_CAPSULE",
	"SHAPE_CONE",
	"SHAPE_TRIANGLEMESH",
	"SHAPE_CONVEXHULL",
	"SHAPE_TERRAIN",

	-- SoundType
	"SOUND_EFFECT",
	"SOUND_AMBIENT",
	"SOUND_VOICE",
	"SOUND_MUSIC",
	"SOUND_MASTER",
	"MAX_SOUND_TYPES",

	-- StencilOp
	"OP_KEEP",
	"OP_ZERO",
	"OP_REF",
	"OP_INCR",
	"OP_DECR",

	-- TextEffect
	"TE_NONE",
	"TE_SHADOW",
	"TE_STROKE",

	-- TextureAddressMode
	"ADDRESS_WRAP",
	"ADDRESS_MIRROR",
	"ADDRESS_CLAMP",
	"ADDRESS_BORDER",
	"MAX_ADDRESSMODES",

	-- TextureCoordinate
	"COORD_U",
	"COORD_V",
	"COORD_W",
	"MAX_COORDS",

	-- TextureFilterMode
	"FILTER_NEAREST",
	"FILTER_BILINEAR",
	"FILTER_TRILINEAR",
	"FILTER_ANISOTROPIC",
	"FILTER_DEFAULT",
	"MAX_FILTERMODES",

	-- TextureUnit
	"TU_DIFFUSE",
	"TU_ALBEDOBUFFER",
	"TU_NORMAL",
	"TU_NORMALBUFFER",
	"TU_SPECULAR",
	"TU_EMISSIVE",
	"TU_ENVIRONMENT",
	"MAX_MATERIAL_TEXTURE_UNITS",
	"TU_LIGHTRAMP",
	"TU_LIGHTSHAPE",
	"TU_SHADOWMAP",
	"TU_FACESELECT",
	"TU_INDIRECTION",
	"TU_DEPTHBUFFER",
	"TU_LIGHTBUFFER",
	"TU_VOLUMEMAP",
	"TU_ZONE",
	"MAX_TEXTURE_UNITS",

	-- TextureUsage
	"TEXTURE_STATIC",
	"TEXTURE_DYNAMIC",
	"TEXTURE_RENDERTARGET",
	"TEXTURE_DEPTHSTENCIL",

	-- TileMapLayerType2D
	"LT_TILE_LAYER",
	"LT_OBJECT_GROUP",
	"LT_IMAGE_LAYER",
	"LT_INVALID",

	-- TileMapObjectType2D
	"OT_RECTANGLE",
	"OT_ELLIPSE",
	"OT_POLYGON",
	"OT_POLYLINE",
	"OT_TILE",
	"OT_INVALID",

	-- TransformSpace
	"TS_LOCAL",
	"TS_PARENT",
	"TS_WORLD",

	-- TraversalMode
	"TM_BREADTH_FIRST",
	"TM_DEPTH_FIRST",

	-- VariantType
	"VAR_NONE",
	"VAR_INT",
	"VAR_BOOL",
	"VAR_FLOAT",
	"VAR_VECTOR2",
	"VAR_VECTOR3",
	"VAR_VECTOR4",
	"VAR_QUATERNION",
	"VAR_COLOR",
	"VAR_STRING",
	"VAR_BUFFER",
	"VAR_VOIDPTR",
	"VAR_RESOURCEREF",
	"VAR_RESOURCEREFLIST",
	"VAR_VARIANTVECTOR",
	"VAR_VARIANTMAP",
	"VAR_INTRECT",
	"VAR_INTVECTOR2",
	"VAR_PTR",
	"VAR_MATRIX3",
	"VAR_MATRIX3X4",
	"VAR_MATRIX4",
	"MAX_VAR_TYPES",

	-- VertexElement
	"ELEMENT_POSITION",
	"ELEMENT_NORMAL",
	"ELEMENT_COLOR",
	"ELEMENT_TEXCOORD1",
	"ELEMENT_TEXCOORD2",
	"ELEMENT_CUBETEXCOORD1",
	"ELEMENT_CUBETEXCOORD2",
	"ELEMENT_TANGENT",
	"ELEMENT_BLENDWEIGHTS",
	"ELEMENT_BLENDINDICES",
	"ELEMENT_INSTANCEMATRIX1",
	"ELEMENT_INSTANCEMATRIX2",
	"ELEMENT_INSTANCEMATRIX3",
	"MAX_VERTEX_ELEMENTS",

	-- VerticalAlignment
	"VA_TOP",
	"VA_CENTER",
	"VA_BOTTOM",

	-- WindowDragMode
	"DRAG_NONE",
	"DRAG_MOVE",
	"DRAG_RESIZE_TOPLEFT",
	"DRAG_RESIZE_TOP",
	"DRAG_RESIZE_TOPRIGHT",
	"DRAG_RESIZE_RIGHT",
	"DRAG_RESIZE_BOTTOMRIGHT",
	"DRAG_RESIZE_BOTTOM",
	"DRAG_RESIZE_BOTTOMLEFT",
	"DRAG_RESIZE_LEFT",

	-- WrapMode
	"WM_LOOP",
	"WM_ONCE",
	"WM_CLAMP",

	-- Global constants
    "ANIMATION_LOD_BASESCALE",
    "CHANNEL_POSITION",
    "CHANNEL_ROTATION",
    "CHANNEL_SCALE",
    "CLEAR_COLOR",
    "CLEAR_DEPTH",
    "CLEAR_STENCIL",
    "CONTROLLER_AXIS_LEFTX",
    "CONTROLLER_AXIS_LEFTY",
    "CONTROLLER_AXIS_RIGHTX",
    "CONTROLLER_AXIS_RIGHTY",
    "CONTROLLER_AXIS_TRIGGERLEFT",
    "CONTROLLER_AXIS_TRIGGERRIGHT",
    "CONTROLLER_BUTTON_A",
    "CONTROLLER_BUTTON_B",
    "CONTROLLER_BUTTON_BACK",
    "CONTROLLER_BUTTON_DPAD_DOWN",
    "CONTROLLER_BUTTON_DPAD_LEFT",
    "CONTROLLER_BUTTON_DPAD_RIGHT",
    "CONTROLLER_BUTTON_DPAD_UP",
    "CONTROLLER_BUTTON_GUIDE",
    "CONTROLLER_BUTTON_LEFTSHOULDER",
    "CONTROLLER_BUTTON_LEFTSTICK",
    "CONTROLLER_BUTTON_RIGHTSHOULDER",
    "CONTROLLER_BUTTON_RIGHTSTICK",
    "CONTROLLER_BUTTON_START",
    "CONTROLLER_BUTTON_X",
    "CONTROLLER_BUTTON_Y",
    "DD_DISABLED",
    "DD_SOURCE",
    "DD_SOURCE_AND_TARGET",
    "DD_TARGET",
    "DEBUGHUD_SHOW_ALL",
    "DEBUGHUD_SHOW_MODE",
    "DEBUGHUD_SHOW_NONE",
    "DEBUGHUD_SHOW_PROFILER",
    "DEBUGHUD_SHOW_STATS",
    "DEFAULT_LIGHTMASK",
    "DEFAULT_SHADOWMASK",
    "DEFAULT_VIEWMASK",
    "DEFAULT_ZONEMASK",
    "DRAWABLE_ANY",
    "DRAWABLE_GEOMETRY",
    "DRAWABLE_LIGHT",
    "DRAWABLE_PROXYGEOMETRY",
    "DRAWABLE_ZONE",
    "FIRST_LOCAL_ID",
    "FIRST_REPLICATED_ID",
    "HAT_CENTER",
    "HAT_DOWN",
    "HAT_LEFT",
    "HAT_RIGHT",
    "HAT_UP",
    "KEY_0",
    "KEY_1",
    "KEY_2",
    "KEY_3",
    "KEY_4",
    "KEY_5",
    "KEY_6",
    "KEY_7",
    "KEY_8",
    "KEY_9",
    "KEY_A",
    "KEY_ALT",
    "KEY_APPLICATION",
    "KEY_B",
    "KEY_BACKSPACE",
    "KEY_C",
    "KEY_CAPSLOCK",
    "KEY_CTRL",
    "KEY_D",
    "KEY_DELETE",
    "KEY_DOWN",
    "KEY_E",
    "KEY_END",
    "KEY_ESC",
    "KEY_F",
    "KEY_F1",
    "KEY_F10",
    "KEY_F11",
    "KEY_F12",
    "KEY_F13",
    "KEY_F14",
    "KEY_F15",
    "KEY_F16",
    "KEY_F17",
    "KEY_F18",
    "KEY_F19",
    "KEY_F2",
    "KEY_F20",
    "KEY_F21",
    "KEY_F22",
    "KEY_F23",
    "KEY_F24",
    "KEY_F3",
    "KEY_F4",
    "KEY_F5",
    "KEY_F6",
    "KEY_F7",
    "KEY_F8",
    "KEY_F9",
    "KEY_G",
    "KEY_GUI",
    "KEY_H",
    "KEY_HOME",
    "KEY_I",
    "KEY_INSERT",
    "KEY_J",
    "KEY_K",
    "KEY_KP_0",
    "KEY_KP_1",
    "KEY_KP_2",
    "KEY_KP_3",
    "KEY_KP_4",
    "KEY_KP_5",
    "KEY_KP_6",
    "KEY_KP_7",
    "KEY_KP_8",
    "KEY_KP_9",
    "KEY_KP_DIVIDE",
    "KEY_KP_ENTER",
    "KEY_KP_MINUS",
    "KEY_KP_MULTIPLY",
    "KEY_KP_PERIOD",
    "KEY_KP_PLUS",
    "KEY_L",
    "KEY_LALT",
    "KEY_LCTRL",
    "KEY_LEFT",
    "KEY_LGUI",
    "KEY_LSHIFT",
    "KEY_M",
    "KEY_N",
    "KEY_NUMLOCKCLEAR",
    "KEY_O",
    "KEY_P",
    "KEY_PAGEDOWN",
    "KEY_PAGEUP",
    "KEY_PAUSE",
    "KEY_PRINTSCREEN",
    "KEY_Q",
    "KEY_R",
    "KEY_RALT",
    "KEY_RCTRL",
    "KEY_RETURN",
    "KEY_RETURN2",
    "KEY_RGUI",
    "KEY_RIGHT",
    "KEY_RSHIFT",
    "KEY_S",
    "KEY_SCROLLLOCK",
    "KEY_SELECT",
    "KEY_SHIFT",
    "KEY_SPACE",
    "KEY_T",
    "KEY_TAB",
    "KEY_U",
    "KEY_UP",
    "KEY_V",
    "KEY_W",
    "KEY_X",
    "KEY_Y",
    "KEY_Z",
    "LAST_LOCAL_ID",
    "LAST_REPLICATED_ID",
    "LOG_DEBUG",
    "LOG_ERROR",
    "LOG_INFO",
    "LOG_NONE",
    "LOG_WARNING",
    "MAX_VERTEX_LIGHTS",
    "MOUSEB_LEFT",
    "MOUSEB_MIDDLE",
    "MOUSEB_RIGHT",
    "M_DEGTORAD",
    "M_DEGTORAD_2",
    "M_EPSILON",
    "M_HALF_PI",
    "M_INFINITY",
    "M_LARGE_EPSILON",
    "M_LARGE_VALUE",
    "M_MAX_FOV",
    "M_MAX_INT",
    "M_MAX_UNSIGNED",
    "M_MIN_INT",
    "M_MIN_NEARCLIP",
    "M_MIN_UNSIGNED",
    "M_PI",
    "M_RADTODEG",
    "NUM_FRUSTUM_PLANES",
    "NUM_FRUSTUM_VERTICES",
    "PIXEL_SIZE",
    "QUALITY_HIGH",
    "QUALITY_LOW",
    "QUALITY_MAX",
    "QUALITY_MEDIUM",
    "QUAL_ALT",
    "QUAL_ANY",
    "QUAL_CTRL",
    "QUAL_SHIFT",
    "SCANCODE_0",
    "SCANCODE_1",
    "SCANCODE_2",
    "SCANCODE_3",
    "SCANCODE_4",
    "SCANCODE_5",
    "SCANCODE_6",
    "SCANCODE_7",
    "SCANCODE_8",
    "SCANCODE_9",
    "SCANCODE_A",
    "SCANCODE_AC_BACK",
    "SCANCODE_AC_BOOKMARKS",
    "SCANCODE_AC_FORWARD",
    "SCANCODE_AC_HOME",
    "SCANCODE_AC_REFRESH",
    "SCANCODE_AC_SEARCH",
    "SCANCODE_AC_STOP",
    "SCANCODE_AGAIN",
    "SCANCODE_ALT",
    "SCANCODE_ALTERASE",
    "SCANCODE_APOSTROPHE",
    "SCANCODE_APP1",
    "SCANCODE_APP2",
    "SCANCODE_APPLICATION",
    "SCANCODE_AUDIOMUTE",
    "SCANCODE_AUDIONEXT",
    "SCANCODE_AUDIOPLAY",
    "SCANCODE_AUDIOPREV",
    "SCANCODE_AUDIOSTOP",
    "SCANCODE_B",
    "SCANCODE_BACKSLASH",
    "SCANCODE_BACKSPACE",
    "SCANCODE_BRIGHTNESSDOWN",
    "SCANCODE_BRIGHTNESSUP",
    "SCANCODE_C",
    "SCANCODE_CALCULATOR",
    "SCANCODE_CANCEL",
    "SCANCODE_CAPSLOCK",
    "SCANCODE_CLEAR",
    "SCANCODE_CLEARAGAIN",
    "SCANCODE_COMMA",
    "SCANCODE_COMPUTER",
    "SCANCODE_COPY",
    "SCANCODE_CRSEL",
    "SCANCODE_CTRL",
    "SCANCODE_CURRENCYSUBUNIT",
    "SCANCODE_CURRENCYUNIT",
    "SCANCODE_CUT",
    "SCANCODE_D",
    "SCANCODE_DECIMALSEPARATOR",
    "SCANCODE_DELETE",
    "SCANCODE_DISPLAYSWITCH",
    "SCANCODE_DOWN",
    "SCANCODE_E",
    "SCANCODE_EJECT",
    "SCANCODE_END",
    "SCANCODE_EQUALS",
    "SCANCODE_ESCAPE",
    "SCANCODE_EXECUTE",
    "SCANCODE_EXSEL",
    "SCANCODE_F",
    "SCANCODE_F1",
    "SCANCODE_F10",
    "SCANCODE_F11",
    "SCANCODE_F12",
    "SCANCODE_F13",
    "SCANCODE_F14",
    "SCANCODE_F15",
    "SCANCODE_F16",
    "SCANCODE_F17",
    "SCANCODE_F18",
    "SCANCODE_F19",
    "SCANCODE_F2",
    "SCANCODE_F20",
    "SCANCODE_F21",
    "SCANCODE_F22",
    "SCANCODE_F23",
    "SCANCODE_F24",
    "SCANCODE_F3",
    "SCANCODE_F4",
    "SCANCODE_F5",
    "SCANCODE_F6",
    "SCANCODE_F7",
    "SCANCODE_F8",
    "SCANCODE_F9",
    "SCANCODE_FIND",
    "SCANCODE_G",
    "SCANCODE_GRAVE",
    "SCANCODE_GUI",
    "SCANCODE_H",
    "SCANCODE_HELP",
    "SCANCODE_HOME",
    "SCANCODE_I",
    "SCANCODE_INSERT",
    "SCANCODE_INTERNATIONAL1",
    "SCANCODE_INTERNATIONAL2",
    "SCANCODE_INTERNATIONAL3",
    "SCANCODE_INTERNATIONAL4",
    "SCANCODE_INTERNATIONAL5",
    "SCANCODE_INTERNATIONAL6",
    "SCANCODE_INTERNATIONAL7",
    "SCANCODE_INTERNATIONAL8",
    "SCANCODE_INTERNATIONAL9",
    "SCANCODE_J",
    "SCANCODE_K",
    "SCANCODE_KBDILLUMDOWN",
    "SCANCODE_KBDILLUMTOGGLE",
    "SCANCODE_KBDILLUMUP",
    "SCANCODE_KP_0",
    "SCANCODE_KP_00",
    "SCANCODE_KP_000",
    "SCANCODE_KP_1",
    "SCANCODE_KP_2",
    "SCANCODE_KP_3",
    "SCANCODE_KP_4",
    "SCANCODE_KP_5",
    "SCANCODE_KP_6",
    "SCANCODE_KP_7",
    "SCANCODE_KP_8",
    "SCANCODE_KP_9",
    "SCANCODE_KP_A",
    "SCANCODE_KP_AMPERSAND",
    "SCANCODE_KP_AT",
    "SCANCODE_KP_B",
    "SCANCODE_KP_BACKSPACE",
    "SCANCODE_KP_BINARY",
    "SCANCODE_KP_C",
    "SCANCODE_KP_CLEAR",
    "SCANCODE_KP_CLEARENTRY",
    "SCANCODE_KP_COLON",
    "SCANCODE_KP_COMMA",
    "SCANCODE_KP_D",
    "SCANCODE_KP_DBLAMPERSAND",
    "SCANCODE_KP_DBLVERTICALBAR",
    "SCANCODE_KP_DECIMAL",
    "SCANCODE_KP_DIVIDE",
    "SCANCODE_KP_E",
    "SCANCODE_KP_ENTER",
    "SCANCODE_KP_EQUALS",
    "SCANCODE_KP_EQUALSAS400",
    "SCANCODE_KP_EXCLAM",
    "SCANCODE_KP_F",
    "SCANCODE_KP_GREATER",
    "SCANCODE_KP_HASH",
    "SCANCODE_KP_HEXADECIMAL",
    "SCANCODE_KP_LEFTBRACE",
    "SCANCODE_KP_LEFTPAREN",
    "SCANCODE_KP_LESS",
    "SCANCODE_KP_MEMADD",
    "SCANCODE_KP_MEMCLEAR",
    "SCANCODE_KP_MEMDIVIDE",
    "SCANCODE_KP_MEMMULTIPLY",
    "SCANCODE_KP_MEMRECALL",
    "SCANCODE_KP_MEMSTORE",
    "SCANCODE_KP_MEMSUBTRACT",
    "SCANCODE_KP_MINUS",
    "SCANCODE_KP_MULTIPLY",
    "SCANCODE_KP_OCTAL",
    "SCANCODE_KP_PERCENT",
    "SCANCODE_KP_PERIOD",
    "SCANCODE_KP_PLUS",
    "SCANCODE_KP_PLUSMINUS",
    "SCANCODE_KP_POWER",
    "SCANCODE_KP_RIGHTBRACE",
    "SCANCODE_KP_RIGHTPAREN",
    "SCANCODE_KP_SPACE",
    "SCANCODE_KP_TAB",
    "SCANCODE_KP_VERTICALBAR",
    "SCANCODE_KP_XOR",
    "SCANCODE_L",
    "SCANCODE_LALT",
    "SCANCODE_LANG1",
    "SCANCODE_LANG2",
    "SCANCODE_LANG3",
    "SCANCODE_LANG4",
    "SCANCODE_LANG5",
    "SCANCODE_LANG6",
    "SCANCODE_LANG7",
    "SCANCODE_LANG8",
    "SCANCODE_LANG9",
    "SCANCODE_LCTRL",
    "SCANCODE_LEFT",
    "SCANCODE_LEFTBRACKET",
    "SCANCODE_LGUI",
    "SCANCODE_LSHIFT",
    "SCANCODE_M",
    "SCANCODE_MAIL",
    "SCANCODE_MEDIASELECT",
    "SCANCODE_MENU",
    "SCANCODE_MINUS",
    "SCANCODE_MODE",
    "SCANCODE_MUTE",
    "SCANCODE_N",
    "SCANCODE_NONUSBACKSLASH",
    "SCANCODE_NONUSHASH",
    "SCANCODE_NUMLOCKCLEAR",
    "SCANCODE_O",
    "SCANCODE_OPER",
    "SCANCODE_OUT",
    "SCANCODE_P",
    "SCANCODE_PAGEDOWN",
    "SCANCODE_PAGEUP",
    "SCANCODE_PASTE",
    "SCANCODE_PAUSE",
    "SCANCODE_PERIOD",
    "SCANCODE_POWER",
    "SCANCODE_PRINTSCREEN",
    "SCANCODE_PRIOR",
    "SCANCODE_Q",
    "SCANCODE_R",
    "SCANCODE_RALT",
    "SCANCODE_RCTRL",
    "SCANCODE_RETURN",
    "SCANCODE_RETURN2",
    "SCANCODE_RGUI",
    "SCANCODE_RIGHT",
    "SCANCODE_RIGHTBRACKET",
    "SCANCODE_RSHIFT",
    "SCANCODE_S",
    "SCANCODE_SCROLLLOCK",
    "SCANCODE_SELECT",
    "SCANCODE_SEMICOLON",
    "SCANCODE_SEPARATOR",
    "SCANCODE_SHIFT",
    "SCANCODE_SLASH",
    "SCANCODE_SLEEP",
    "SCANCODE_SPACE",
    "SCANCODE_STOP",
    "SCANCODE_SYSREQ",
    "SCANCODE_T",
    "SCANCODE_TAB",
    "SCANCODE_THOUSANDSSEPARATOR",
    "SCANCODE_U",
    "SCANCODE_UNDO",
    "SCANCODE_UNKNOWN",
    "SCANCODE_UP",
    "SCANCODE_V",
    "SCANCODE_VOLUMEDOWN",
    "SCANCODE_VOLUMEUP",
    "SCANCODE_W",
    "SCANCODE_WWW",
    "SCANCODE_X",
    "SCANCODE_Y",
    "SCANCODE_Z",
    "SCAN_DIRS",
    "SCAN_FILES",
    "SCAN_HIDDEN",
    "SHADOWQUALITY_HIGH_16BIT",
    "SHADOWQUALITY_HIGH_24BIT",
    "SHADOWQUALITY_LOW_16BIT",
    "SHADOWQUALITY_LOW_24BIT",
    "VO_DISABLE_OCCLUSION",
    "VO_DISABLE_SHADOWS",
    "VO_LOW_MATERIAL_QUALITY",
    "VO_NONE",
}

for _, name in ipairs(safe_globals) do
	local v = _G[name]
	if type(v) ~= 'number' and type(v) ~= 'string' then
		error("Invalid safe global "..dump(name).." type: "..dump(type(v)))
	end
	M.safe[name] = v
end

wc("Vector3", {
	unsafe_constructor = wrap_function({"number", "number", "number"},
	function(x, y, z)
		return wrap_instance("Vector3", Vector3(x, y, z))
	end),
	instance_meta = {
		__mul = wrap_function({"Vector3", "number"}, function(self, n)
			return wrap_instance("Vector3", self * n)
		end),
	},
	properties = {
		x = simple_property("number"),
		y = simple_property("number"),
		z = simple_property("number"),
	},
})

wc("Resource", {
})

wc("Component", {
})

wc("Octree", {
	inherited_from_by_wrapper = M.safe.Component,
})

wc("Drawable", {
	inherited_from_by_wrapper = M.safe.Component,
})

wc("Light", {
	inherited_from_by_wrapper = M.safe.Drawable,
	properties = {
		lightType = simple_property("number"),
	},
})

wc("Camera", {
	inherited_from_by_wrapper = M.safe.Component,
})

wc("Model", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("Material", {
	inherited_from_by_wrapper = M.safe.Resource,
	class = {
		new = function()
			return wrap_instance("Material", Material:new())
		end,
	},
	instance = {
		--SetTexture = wrap_function({"Material", "number", "Texture"},
		--function(self, index, texture)
		--	log:info("Material:SetTexture("..dump(index)..", "..dump(texture)..")")
		--	self:SetTexture(index, texture)
		--end),
		SetTexture = self_function(
				"SetTexture", {}, {"Material", "number", "Texture"}),
		SetTechnique = self_function(
				"SetTechnique", {}, {"Material", "number", "Technique",
						{"number", "__nil"}, {"number", "__nil"}}),
	},
})

wc("Texture", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("Texture2D", {
	inherited_from_by_wrapper = M.safe.Texture,
})

wc("Font", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("StaticModel", {
	inherited_from_by_wrapper = M.safe.Octree,
	properties = {
		model = simple_property(M.safe.Model),
		material = simple_property(M.safe.Material),
	},
})

wc("Technique", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("Node", {
	instance = {
		CreateComponent = wrap_function({"Node", "string"}, function(self, name)
			local component = self:CreateComponent(name)
			assert(component)
			return wrap_instance(name, component)
		end),
		GetComponent = wrap_function({"Node", "string"}, function(self, name)
			local component = self:GetComponent(name)
			assert(component)
			return wrap_instance(name, component)
		end),
		LookAt = wrap_function({"Node", "Vector3"}, function(self, p)
			self:LookAt(p)
		end),
		Translate = wrap_function({"Node", "Vector3"}, function(self, v)
			self:Translate(v)
		end),
	},
	properties = {
		scale = simple_property(M.safe.Vector3),
		direction = simple_property(M.safe.Vector3),
		position = simple_property(M.safe.Vector3),
	},
})

wc("Plane", {
})

wc("Scene", {
	inherited_from_by_wrapper = M.safe.Node,
	unsafe_constructor = wrap_function({}, function()
		return wrap_instance("Scene", Scene())
	end),
	instance = {
		CreateChild = wrap_function({"Scene", "string"}, function(self, name)
			return wrap_instance("Node", self:CreateChild(name))
		end)
	},
})

wc("ResourceCache", {
	instance = {
		GetResource = wrap_function({"ResourceCache", "string", "string"},
		function(self, resource_type, resource_name)
			-- TODO: If resource_type=XMLFile, we probably have to go through it and
			--       resave all references to other files found in there
			resource_name = M.check_safe_resource_name(resource_name)
			M.resave_file(resource_name)
			local res = cache:GetResource(resource_type, resource_name)
			return wrap_instance(resource_type, res)
		end),
	},
})

wc("Viewport", {
	class = {
		new = wrap_function({"__to_nil", "Scene", "Camera"},
		function(_, scene, camera_component)
			return wrap_instance("Viewport", Viewport:new(scene, camera_component))
		end),
	},
})

wc("Renderer", {
	instance = {
		SetViewport = wrap_function({"Renderer", "number", "Viewport"},
		function(self, index, viewport)
			self:SetViewport(index, viewport)
		end),
	},
})

wc("Animatable", {
})

wc("UIElement", {
	inherited_from_by_wrapper = M.safe.Animatable,
	instance = {
		CreateChild = wrap_function({"UIElement", "string", {"string", "__nil"}},
		function(self, element_type, name)
			return wrap_instance("UIElement", self:CreateChild(element_type, name))
		end),
		SetText = self_function("SetText", {}, {"UIElement", "string"}),
		SetFont = self_function("SetFont", {}, {"UIElement", "Font"}),
		SetPosition = self_function(
				"SetPosition", {}, {"UIElement", "number", "number"}),
	},
	properties = {
		horizontalAlignment = simple_property("number"),
		verticalAlignment = simple_property("number"),
		height = simple_property("number"),
	},
})

wc("UI", {
	instance = {
	},
	properties = {
		root = simple_property(M.safe.UIElement),
		focusElement = simple_property({M.safe.UIElement, "__nil"}),
	},
})

wc("Input", {
	instance = {
		GetKeyDown = self_function("GetKeyDown", {"boolean"}, {"Input", "number"}),
	},
})

M.safe.cache = wrap_instance("ResourceCache", cache)
M.safe.renderer = wrap_instance("Renderer", renderer)
M.safe.ui = wrap_instance("UI", ui)
M.safe.input = wrap_instance("Input", input)

setmetatable(M.safe, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		error("extension/urho3d: "..dump(k).." not found in safe interface")
	end,
})

-- SubscribeToEvent

local sandbox_callback_to_global_function_name = {}
local next_sandbox_global_function_i = 1

function M.safe.SubscribeToEvent(x, y, z)
	local object = x
	local event_name = y
	local callback = z
	if callback == nil then
		object = nil
		event_name = x
		callback = y
	end
	if type(callback) == 'string' then
		-- Allow supplying callback function name like Urho3D does by default
		local caller_environment = getfenv(2)
		callback = caller_environment[callback]
		if type(callback) ~= 'function' then
			error("SubscribeToEvent(): '"..callback..
					"' is not a global function in current sandbox environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_sandbox_global_function_i
	next_sandbox_global_function_i = next_sandbox_global_function_i + 1
	local global_callback_name = "__buildat_sandbox_callback_"..global_function_i
	sandbox_callback_to_global_function_name[callback] = global_callback_name
	_G[global_callback_name] = function(eventType, eventData)
		local f = function()
			if object then
				callback(object, eventType, eventData)
			else
				callback(eventType, eventData)
			end
		end
		__buildat_run_function_in_sandbox(f)
	end
	if object then
		SubscribeToEvent(object, event_name, global_callback_name)
	else
		SubscribeToEvent(event_name, global_callback_name)
	end
	return global_callback_name
end

--
-- Unsafe interface
--

-- Just wrap everything to the global environment as we don't have a full list
-- of Urho3D's API available.

setmetatable(M, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		return _G[k]
	end,
})

-- Add GetResource wrapper to ResourceCache instance

--[[M.cache.GetResource = function(self, resource_type, resource_name)
	local path = M.resave_file(resource_name)
	-- Note: path is unused
	resource_name = M.check_safe_resource_name(resource_name)
	return M.cache:GetResource(resource_type, resource_name)
end]]

-- Unsafe SubscribeToEvent with function support

local unsafe_callback_to_global_function_name = {}
local next_unsafe_global_function_i = 1

function M.SubscribeToEvent(x, y, z)
	local object = x
	local event_name = y
	local callback = z
	if callback == nil then
		object = nil
		event_name = x
		callback = y
	end
	if type(callback) == 'string' then
		-- Allow supplying callback function name like Urho3D does by default
		local caller_environment = getfenv(2)
		callback = caller_environment[callback]
		if type(callback) ~= 'function' then
			error("SubscribeToEvent(): '"..callback..
					"' is not a global function in current unsafe environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_unsafe_global_function_i
	next_unsafe_global_function_i = next_unsafe_global_function_i + 1
	local global_callback_name = "__buildat_unsafe_callback_"..global_function_i
	unsafe_callback_to_global_function_name[callback] = global_callback_name
	_G[global_callback_name] = function(eventType, eventData)
		local f = function()
			if object then
				callback(object, eventType, eventData)
			else
				callback(eventType, eventData)
			end
		end
		local ok, err = __buildat_pcall(f)
		if not ok then
			__buildat_fatal_error("Error calling callback: "..err)
		end
	end
	if object then
		SubscribeToEvent(object, event_name, global_callback_name)
	else
		SubscribeToEvent(event_name, global_callback_name)
	end
	return global_callback_name
end

return M
-- vim: set noet ts=4 sw=4:
