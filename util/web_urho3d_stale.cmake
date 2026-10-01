# The web build's engine archive merges the third-party archives into
# libUrho3D.a after its own objects build, and only then: a rebuilt SDL is
# otherwise never in it ([WEB_CLIENT]). Removed when any of them is newer,
# so the engine's build merges again.
# cmake -DDIR=<Urho3D build dir> -P util/web_urho3d_stale.cmake
set(LIB "${DIR}/lib/libUrho3D.a")
if(NOT EXISTS "${LIB}")
	return()
endif()
file(GLOB_RECURSE ARCHIVES "${DIR}/Source/ThirdParty/*.a")
foreach(A ${ARCHIVES})
	if("${A}" IS_NEWER_THAN "${LIB}")
		message(STATUS "${A} is newer than the engine archive; merging again")
		file(REMOVE "${LIB}")
		return()
	endif()
endforeach()
