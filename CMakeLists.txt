# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2014 Perttu Ahola <celeron55@gmail.com>

cmake_minimum_required(VERSION 3.2.3)
project(buildat)

#
# Global options
#

set(BUILD_SERVER TRUE CACHE BOOL "Build server")
set(BUILD_CLIENT TRUE CACHE BOOL "Build client")
set(DEBUG_LOG_TIMING FALSE CACHE BOOL "Output log messages of interesting but floody time measurements")
# Where the cache and the user's own things live. TRUE keeps both beside the
# program, in <buildat>/cache and <buildat>/user: what development wants, and
# the default. FALSE puts them where the platform says, which is what an
# installed copy wants. See doc/plan/world_persistence_plan.md.
set(PORTABLE TRUE CACHE BOOL "Keep cache/ and user/ beside the program")

#
# Urho3D dependency (bundled in 3rdparty/Urho3D)
#
# 1.7.1 UrhoCommon.cmake treats CMAKE_SOURCE_DIR as the Urho tree. Do not
# include it from this file. Configure the engine as a sub-build of the Urho
# root instead of Source/.
#

set(URHO3D_BUNDLED_HOME "${CMAKE_SOURCE_DIR}/3rdparty/Urho3D")
if(NOT URHO3D_HOME)
	if(DEFINED ENV{URHO3D_HOME} AND NOT "$ENV{URHO3D_HOME}" STREQUAL "")
		set(URHO3D_HOME "$ENV{URHO3D_HOME}")
	else()
		set(URHO3D_HOME "${URHO3D_BUNDLED_HOME}")
	endif()
endif()
message(STATUS "URHO3D_HOME=\"${URHO3D_HOME}\"")
if(NOT EXISTS "${URHO3D_HOME}/CMakeLists.txt")
	message(FATAL_ERROR "Urho3D not found at URHO3D_HOME=${URHO3D_HOME}")
endif()

# SHARED is required for the module interface.
set(URHO3D_LIB_TYPE SHARED CACHE STRING "Urho3D library type (SHARED required by Buildat modules)")
set(URHO3D_LUA TRUE CACHE BOOL "Enable Urho3D Lua")
set(URHO3D_SAFE_LUA TRUE CACHE BOOL "Enable Urho3D Lua safety checks")
set(URHO3D_ANGELSCRIPT FALSE CACHE BOOL "Enable Urho3D AngelScript")
# LuaJIT is the runtime ([LUAJIT] in doc/plan/performance_plan.md); the
# server's Luanti state and the client's sandbox are one Lua build
set(URHO3D_LUAJIT TRUE CACHE BOOL "Enable Urho3D LuaJIT")
if(NOT DEFINED URHO3D_64BIT)
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		set(URHO3D_64BIT TRUE)
	else()
		set(URHO3D_64BIT FALSE)
	endif()
endif()

# A sanitizer, for chasing an intermittent crash rather than for every day:
# -DSANITIZE=address builds with AddressSanitizer, and the option is passed
# to the bundled Urho3D's own build below, because the engine is where a
# use-after-free of a scene node would be. Build it in a directory of its
# own -- Build/asan -- so that the ordinary build is untouched, and run it
# with ASAN_OPTIONS=detect_leaks=0:abort_on_error=1, a long-lived engine's
# exit leaks being what would otherwise bury the report. It costs about
# twice the CPU and three times the memory, which is why it is not the
# default. See doc/plan/master_plan.md, "Catching a use-after-free before it
# is a mystery".
set(SANITIZE "" CACHE STRING "Sanitizer to build with: address, thread or empty")
if(SANITIZE)
	set(SANITIZE_FLAGS "-fsanitize=${SANITIZE} -fno-omit-frame-pointer")
	set(COMMON_CXX_FLAGS "${COMMON_CXX_FLAGS} ${SANITIZE_FLAGS}")
	set(CMAKE_EXE_LINKER_FLAGS
			"${CMAKE_EXE_LINKER_FLAGS} ${SANITIZE_FLAGS}")
	set(CMAKE_SHARED_LINKER_FLAGS
			"${CMAKE_SHARED_LINKER_FLAGS} ${SANITIZE_FLAGS}")
	message(STATUS "Building with -fsanitize=${SANITIZE}")
endif()

# The bundled Urho3D is built in one directory, shared by every buildat
# build directory there is -- so a sanitizer build needs its own, or
# configuring one re-flags the engine for the ordinary build as well and the
# next ordinary link fails. Found the hard way.
if(SANITIZE)
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build-${SANITIZE}")
else()
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build")
endif()
if(WIN32)
	set(URHO3D_LIBRARY_FILE "${URHO3D_BUILD_DIR}/bin/Urho3D.dll")
	set(URHO3D_IMPLIB_FILE "${URHO3D_BUILD_DIR}/lib/libUrho3D.dll.a")
else()
	set(URHO3D_LIBRARY_FILE "${URHO3D_BUILD_DIR}/lib/libUrho3D${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()

# Flat includes so existing #include <Scene.h> and RCC++ modules keep working.
set(URHO3D_INCLUDE_DIRS
	"${URHO3D_HOME}/Source/Urho3D"
	"${URHO3D_BUILD_DIR}/include"
	"${URHO3D_BUILD_DIR}/include/Urho3D"
	"${URHO3D_BUILD_DIR}/include/Urho3D/ThirdParty"
	"${URHO3D_BUILD_DIR}/include/Urho3D/ThirdParty/Bullet"
	"${URHO3D_HOME}/Source/ThirdParty/toluapp/include"
)
file(GLOB URHO3D_ENGINE_SUBDIRS "${URHO3D_HOME}/Source/Urho3D/*")
foreach(URHO3D_ENGINE_SUBDIR ${URHO3D_ENGINE_SUBDIRS})
	if(IS_DIRECTORY "${URHO3D_ENGINE_SUBDIR}")
		list(APPEND URHO3D_INCLUDE_DIRS "${URHO3D_ENGINE_SUBDIR}")
	endif()
endforeach()

# Build the in-tree engine as part of this project.
get_filename_component(URHO3D_HOME_ABS "${URHO3D_HOME}" ABSOLUTE)
get_filename_component(URHO3D_BUNDLED_HOME_ABS "${URHO3D_BUNDLED_HOME}" ABSOLUTE)
if(URHO3D_HOME_ABS STREQUAL URHO3D_BUNDLED_HOME_ABS)
	if(NOT CMAKE_BUILD_TYPE)
		set(CMAKE_BUILD_TYPE Debug)
	endif()
	file(MAKE_DIRECTORY "${URHO3D_BUILD_DIR}")
	set(URHO3D_CROSS_ARGS "")
	if(CMAKE_TOOLCHAIN_FILE)
		list(APPEND URHO3D_CROSS_ARGS "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}")
	else()
		list(APPEND URHO3D_CROSS_ARGS
			"-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
			"-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}")
	endif()
	if(MINGW_PREFIX)
		list(APPEND URHO3D_CROSS_ARGS "-DMINGW_PREFIX=${MINGW_PREFIX}")
	endif()
	set(URHO3D_BUNDLE_CMAKE_ARGS
		-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
		# The sanitizer as well, when there is one: the engine is where a
		# use-after-free of a scene node would be, and ASan has to be in the
		# library that owns the memory as much as in what calls it
		"-DCMAKE_CXX_FLAGS=${SANITIZE_FLAGS}"
		"-DCMAKE_C_FLAGS=${SANITIZE_FLAGS}"
		# A cross build hands the engine the same toolchain file and, for
		# Urho3D's MinGW.cmake, the tool prefix ([PACKAGING] step 3) --
		# and not the compilers, which the toolchain sets and Urho3D's
		# native-tool checks must not inherit
		${URHO3D_CROSS_ARGS}
		-DURHO3D_LIB_TYPE=${URHO3D_LIB_TYPE}
		-DURHO3D_LUA=${URHO3D_LUA}
		-DURHO3D_SAFE_LUA=${URHO3D_SAFE_LUA}
		-DURHO3D_LUAJIT=${URHO3D_LUAJIT}
		-DURHO3D_ANGELSCRIPT=${URHO3D_ANGELSCRIPT}
		-DURHO3D_SAMPLES=FALSE
		-DURHO3D_TOOLS=FALSE
		-DURHO3D_EXTRAS=FALSE
		-DURHO3D_DOCS=FALSE
		-DURHO3D_DATABASE_SQLITE=FALSE
		-DURHO3D_PCH=FALSE
		-DURHO3D_64BIT=${URHO3D_64BIT}
	)
	# Under Urho3D's MinGW toolchain the outer configure has exported the
	# cross compilers into this process's environment (the toolchain's
	# try_compile workaround), and Urho3D's own configure probes for a
	# *native* compiler with the same environment -- and finds the cross
	# one, which cannot link -rdynamic. Unset them for the child.
	set(URHO3D_CONFIGURE_ENV "")
	if(CMAKE_CROSSCOMPILING AND NOT CMAKE_HOST_WIN32)
		set(URHO3D_CONFIGURE_ENV /usr/bin/env -i "PATH=$ENV{PATH}"
			"HOME=$ENV{HOME}")
	endif()
	execute_process(
		COMMAND ${URHO3D_CONFIGURE_ENV}
			${CMAKE_COMMAND} ${URHO3D_BUNDLE_CMAKE_ARGS} "${URHO3D_HOME}"
		WORKING_DIRECTORY "${URHO3D_BUILD_DIR}"
		RESULT_VARIABLE URHO3D_CONFIGURE_RESULT
	)
	if(NOT URHO3D_CONFIGURE_RESULT EQUAL 0)
		message(FATAL_ERROR "Failed to configure bundled Urho3D")
	endif()
	# $(MAKE) hands the sub-build the parent make's jobserver, so the engine
	# builds with the -j the user gave and not with one of its own. Other
	# generators have no jobserver to inherit; --parallel without a number is
	# the best they can do.
	if(CMAKE_GENERATOR MATCHES "Makefiles")
		set(URHO3D_BUILD_COMMAND $(MAKE))
	else()
		set(URHO3D_BUILD_COMMAND ${CMAKE_COMMAND} --build "${URHO3D_BUILD_DIR}" --parallel)
	endif()
	add_custom_target(urho3d_build
		COMMAND ${URHO3D_BUILD_COMMAND}
		WORKING_DIRECTORY "${URHO3D_BUILD_DIR}"
		COMMENT "Building bundled Urho3D"
	)
endif()

if(NOT TARGET Urho3D)
	add_library(Urho3D SHARED IMPORTED GLOBAL)
	set_target_properties(Urho3D PROPERTIES
		IMPORTED_LOCATION "${URHO3D_LIBRARY_FILE}")
	if(WIN32)
		set_target_properties(Urho3D PROPERTIES
			IMPORTED_IMPLIB "${URHO3D_IMPLIB_FILE}")
	endif()
endif()

# SYSTEM gets rid of annoying warnings that we're not going to fix
include_directories(SYSTEM ${URHO3D_INCLUDE_DIRS})
if(NOT WIN32)
	set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
	set(CMAKE_INSTALL_RPATH "\$ORIGIN/../lib;${URHO3D_BUILD_DIR}/lib")
endif()

# Urho3D's Lua (luabind needs the headers and a Lua archive)
set(LUA_FOUND true)
if(URHO3D_LUAJIT)
	set(LUA_INCLUDE_DIRS "${URHO3D_HOME}/Source/ThirdParty/LuaJIT/src")
	set(LUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/LuaJIT/libLuaJIT.a")
	set(BUILDAT_LUA_DIR "LuaJIT")
else()
	set(LUA_INCLUDE_DIRS "${URHO3D_HOME}/Source/ThirdParty/Lua/src")
	set(LUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/Lua/libLua.a")
	set(BUILDAT_LUA_DIR "Lua")
endif()
# Where the engine's Lua headers are installed under Build/include, for the
# server to hand to the modules it compiles at run time
add_definitions(-DBUILDAT_LUA_DIR="${BUILDAT_LUA_DIR}")
if(WIN32)
	set(LUA_LIBRARIES ${LUA_LIBRARY})
	message(STATUS "LUA_LIBRARIES=${LUA_LIBRARIES}")
endif()
include_directories(${LUA_INCLUDE_DIRS})
set(URHO3D_TOLUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/toluapp/src/lib/libtoluapp.a")

#
# Bundled libraries
#

add_subdirectory("3rdparty/cereal")
add_subdirectory("3rdparty/c55lib")
add_subdirectory("3rdparty/smallsha1")
add_subdirectory("3rdparty/polyvox")
add_subdirectory("3rdparty/zlib")
add_subdirectory("3rdparty/zstd")
add_subdirectory("3rdparty/sqlite")
add_subdirectory("3rdparty/luabind-deboostified")

include_directories("src")
include_directories("3rdparty/cereal/include")
include_directories("3rdparty/c55lib")
include_directories("3rdparty/smallsha1")
include_directories("3rdparty/polyvox/library/PolyVoxCore/include")
include_directories("3rdparty/zlib")
include_directories("${CMAKE_BINARY_DIR}/3rdparty/zlib")
include_directories("3rdparty/zstd/lib")
include_directories("3rdparty/sqlite/src")
# SYSTEM gets rid of annoying warnings that we're not going to fix
include_directories(SYSTEM "3rdparty/luabind-deboostified")

#
# Buildat
#

if(DEBUG_LOG_TIMING)
	set(COMMON_CXX_FLAGS "${COMMON_CXX_FLAGS} -DDEBUG_LOG_TIMING")
endif()
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -Wall")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wextra -Wno-unused-parameter")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${COMMON_CXX_FLAGS}")
#set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O0 -Wall")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O1 -Wall")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} ${COMMON_CXX_FLAGS}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin") # Executables
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib") # Shared libs
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib") # Static libs

# Always output in color (useful when using head for build output)
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fdiagnostics-color=always")
# Security / crash protection
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fstack-protector-all")

set(BUILDAT_CORE_NAME buildat_core)
# The client *is* buildat: it shows the launch menu, starts a local server for
# a game and connects to a remote one. There used to be a separate `buildat`
# launcher that did nothing but exec `buildat_client -m launch_menu`, and two
# launch menus with it.
set(CLIENT_EXE_NAME buildat)
set(SERVER_EXE_NAME buildat_server)

#
# Core library - shared code between executables and modules
#

set(BUILDAT_CORE_SRCS
	src/core/log.cpp
	src/core/json.cpp
	src/boot/autodetect.cpp
	src/impl/fs.cpp
	src/impl/event.cpp
	src/impl/tcpsocket.cpp
	src/impl/module.cpp
	src/impl/sha1.cpp
	src/impl/sha256.cpp
	src/impl/bignum.cpp
	src/impl/packet_stream.cpp
	src/impl/mesh.cpp
	src/impl/atlas.cpp
	src/impl/voxel.cpp
	src/impl/block.cpp
	src/impl/noise.cpp
	src/impl/voxel_volume.cpp
	src/impl/compress.cpp
	src/impl/zip.cpp
	src/impl/http.cpp
	src/impl/thread_pool.cpp
	src/impl/thread.cpp
	src/impl/magic_event_handler.cpp
)
if(WIN32)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/file_watch.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/process.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/debug.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/os.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/fs.cpp)
else()
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/file_watch.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/process.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/debug.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/os.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/fs.cpp)
endif()
if(PORTABLE)
	add_definitions(-DBUILDAT_PORTABLE)
endif()
# The version and the git hash, generated into a source of the core library
# at configure and again on every build ([VERSION]); see util/version.cmake
set(BUILDAT_VERSION_CPP ${CMAKE_BINARY_DIR}/buildat_version.cpp)
execute_process(COMMAND ${CMAKE_COMMAND}
	-DSRC=${CMAKE_SOURCE_DIR} -DOUT=${BUILDAT_VERSION_CPP}
	-P ${CMAKE_SOURCE_DIR}/util/version.cmake)
add_custom_target(buildat_version ALL
	COMMAND ${CMAKE_COMMAND}
		-DSRC=${CMAKE_SOURCE_DIR} -DOUT=${BUILDAT_VERSION_CPP}
		-P ${CMAKE_SOURCE_DIR}/util/version.cmake
	BYPRODUCTS ${BUILDAT_VERSION_CPP}
	COMMENT "Reading the version and the git hash")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
	${CMAKE_SOURCE_DIR}/VERSION)
set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} ${BUILDAT_VERSION_CPP})
# sqlite's objects rather than a library: builtin/storage is a runtime-compiled
# module and cannot link one, so buildat_core is what exports sqlite3_* to it.
add_library(${BUILDAT_CORE_NAME} SHARED ${BUILDAT_CORE_SRCS}
	$<TARGET_OBJECTS:sqlite>)
add_dependencies(${BUILDAT_CORE_NAME} buildat_version)
# libcurl, required ([CONTENTDB]): ContentDB is HTTPS only and the tree has
# no TLS of its own. The system's on Linux; on the mingw cross build a
# curl-for-win tree, CURL_INCLUDE_DIR and CURL_LIBRARY passed by
# util/package.sh and its DLL shipped beside the executables.
find_package(CURL REQUIRED)
target_include_directories(${BUILDAT_CORE_NAME} PRIVATE ${CURL_INCLUDE_DIRS})
target_link_libraries(${BUILDAT_CORE_NAME}
	c55lib
	smallsha1
	PolyVoxCore
	zlib
	zstd
	${CURL_LIBRARIES}
)
if(NOT WIN32)
	find_package(Threads REQUIRED)
	target_link_libraries(${BUILDAT_CORE_NAME}
		${CMAKE_THREAD_LIBS_INIT}
		${CMAKE_DL_LIBS}
	)
endif()
if(WIN32)
	target_link_libraries(${BUILDAT_CORE_NAME}
		wsock32
		ws2_32
		psapi # Process stuff
		Urho3D
	)
endif()

#
# Client
#

if(BUILD_CLIENT)
	set(CLIENT_SRCS
		src/client/main.cpp
		src/client/state.cpp
		src/client/app.cpp
		src/client/config.cpp
		src/client/command_seq.cpp
		src/lua_bindings/util.cpp
		src/lua_bindings/init.cpp
		src/lua_bindings/misc.cpp
		src/lua_bindings/cereal.cpp
		src/lua_bindings/voxel.cpp
		src/lua_bindings/atlas.cpp
		src/lua_bindings/mesh.cpp
		src/lua_bindings/voxel_volume.cpp
		src/lua_bindings/voxel_data.cpp
	src/lua_bindings/image.cpp
		src/lua_bindings/spatial_update_queue.cpp
		src/lua_bindings/misc_urho3d.cpp
		src/lua_bindings/network.cpp
		src/lua_bindings/crypto.cpp
		src/lua_bindings/compress.cpp
		src/lua_bindings/replicate.cpp
	)

	add_executable(${CLIENT_EXE_NAME} ${CLIENT_SRCS})

	target_link_libraries(${CLIENT_EXE_NAME}
		${BUILDAT_CORE_NAME}
		c55lib
		smallsha1
		PolyVoxCore
		zlib
		zstd
		luabind
		Urho3D
		${URHO3D_TOLUA_LIBRARY}
		${LUA_LIBRARY}
	)
	#if(NOT WIN32)
	#	target_link_libraries(${CLIENT_EXE_NAME}
	#		${LUA_LIBRARY}
	#	)
	#endif()

endif(BUILD_CLIENT)

#
# Server
#

if(BUILD_SERVER)
	set(SERVER_SRCS
		src/server/main.cpp
		src/server/state.cpp
		src/server/rccpp.cpp
		src/server/config.cpp
		src/server/rccpp_util.cpp
	)
	add_executable(${SERVER_EXE_NAME} ${SERVER_SRCS})

	target_link_libraries(${SERVER_EXE_NAME}
		${BUILDAT_CORE_NAME}
		c55lib
		smallsha1
		Urho3D
	)
	if(WIN32)
	else()
		target_link_libraries(${SERVER_EXE_NAME} dl)
	endif()
endif(BUILD_SERVER)

if(TARGET urho3d_build)
	# The core links against the engine too, and under -j it reached the
	# import library before the engine's build had made it
	add_dependencies(${BUILDAT_CORE_NAME} urho3d_build)
	if(BUILD_CLIENT)
		add_dependencies(${CLIENT_EXE_NAME} urho3d_build)
	endif()
	if(BUILD_SERVER)
		add_dependencies(${SERVER_EXE_NAME} urho3d_build)
	endif()
endif()

#
# Installation
#
# The archive's layout, one for every platform ([PACKAGING]): bin/ with the
# programs (and lib/ with the shared libraries on Linux, found through
# RPATH), buildat's own trees at the root as the share path, src/ and the
# headers that run-time compilation reads, Urho3D's sources and data, and
# on Windows the MinGW-w64 tree under compiler/ -- Linux uses the system
# compiler. util/package.sh runs this into a staging directory and makes
# the archive.

if(WIN32)
	set(DST_BIN "bin")
	set(DST_LIB "bin")
else()
	set(DST_BIN "bin")
	set(DST_LIB "lib")
endif()
set(DST_SHARE ".")
set(DST_COMPILER "${DST_SHARE}/compiler")

install(DIRECTORY "${CMAKE_SOURCE_DIR}/doc" DESTINATION "."
	PATTERN "plan" EXCLUDE)
install(FILES "${CMAKE_SOURCE_DIR}/NOTICE" DESTINATION ".")
install(FILES "${CMAKE_SOURCE_DIR}/README.md" DESTINATION ".")

install(TARGETS ${BUILDAT_CORE_NAME} DESTINATION "${DST_LIB}")
if(WIN32)
	install(FILES "${URHO3D_LIBRARY_FILE}" DESTINATION "${DST_LIB}")
else()
	# libUrho3D.so is a symlink chain to libUrho3D.so.0.1.x: the real
	# file and the links with it, or the archive links to nothing
	get_filename_component(URHO3D_LIBRARY_DIR "${URHO3D_LIBRARY_FILE}" DIRECTORY)
	install(DIRECTORY "${URHO3D_LIBRARY_DIR}/" DESTINATION "${DST_LIB}"
		FILES_MATCHING PATTERN "libUrho3D.so*")
endif()
if(WIN32)
	# The compiler the Windows archive ships under compiler/ is a native
	# MinGW-w64 distribution, not the cross toolchain that built the
	# binaries (a Linux program): BUILDAT_SHIP_COMPILER names its mingw64
	# root, which util/docker/windows unpacks from a pinned winlibs release
	# ([PACKAGING] step 3). The runtime DLLs beside the executables come
	# from the same tree, so the modules it compiles and the binaries it
	# is shipped with run on one libstdc++.
	set(BUILDAT_SHIP_COMPILER "" CACHE PATH
		"A native MinGW-w64 tree (mingw64/) to ship under compiler/ on Windows")
	if(NOT BUILDAT_SHIP_COMPILER)
		message(WARNING "BUILDAT_SHIP_COMPILER is not set: the archive will "
			"carry no compiler and its server cannot build a module")
	else()
		foreach(DLL libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll)
			install(FILES "${BUILDAT_SHIP_COMPILER}/bin/${DLL}" DESTINATION "${DST_BIN}")
		endforeach()
	endif()
	# libcurl's DLL from the curl-for-win tree the image unpacks (its
	# bin/ beside the lib/ CURL_LIBRARY names)
	if(CURL_LIBRARY)
		get_filename_component(CURL_LIB_DIR "${CURL_LIBRARY}" DIRECTORY)
		install(DIRECTORY "${CURL_LIB_DIR}/../bin/" DESTINATION "${DST_BIN}"
			FILES_MATCHING PATTERN "libcurl*.dll")
	endif()
endif()
if(BUILD_CLIENT)
	install(TARGETS ${CLIENT_EXE_NAME} buildat DESTINATION "${DST_BIN}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/client" DESTINATION "${DST_SHARE}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/extensions" DESTINATION "${DST_SHARE}")
endif()
if(BUILD_SERVER)
	install(TARGETS ${SERVER_EXE_NAME} DESTINATION "${DST_BIN}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/builtin" DESTINATION "${DST_SHARE}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/games" DESTINATION "${DST_SHARE}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/src" DESTINATION "${DST_SHARE}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/3rdparty/cereal/include" DESTINATION "${DST_SHARE}/3rdparty/cereal")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/3rdparty/polyvox/library/PolyVoxCore/include" DESTINATION "${DST_SHARE}/3rdparty/polyvox/library/PolyVoxCore")
	install(FILES "${CMAKE_SOURCE_DIR}/3rdparty/sqlite/src/sqlite3.h"
		DESTINATION "${DST_SHARE}/3rdparty/sqlite/src")
	install(DIRECTORY "${URHO3D_HOME}/Source" DESTINATION "${DST_SHARE}/Urho3D")
	# The whole generated include tree, not Urho3D.h alone: a module's
	# <lua.h> comes from Build/include/Urho3D/ThirdParty/<Lua>, which the
	# server adds to the module compiler's paths
	# Dereferenced: Urho3D's build makes that tree of symlinks into its
	# source and build directories, absolute, which in an archive point
	# at the machine that built it ([PACKAGING], the xdg tarball on a
	# second machine: every module failed on <Urho3D/Urho3D.h>)
	install(CODE "
		file(REMOVE_RECURSE \"\${CMAKE_INSTALL_PREFIX}/${DST_SHARE}/Urho3D/Build/include\")
		file(MAKE_DIRECTORY \"\${CMAKE_INSTALL_PREFIX}/${DST_SHARE}/Urho3D/Build\")
		execute_process(COMMAND cp -rL \"${URHO3D_BUILD_DIR}/include\"
			\"\${CMAKE_INSTALL_PREFIX}/${DST_SHARE}/Urho3D/Build/include\"
			RESULT_VARIABLE r)
		if(NOT r EQUAL 0)
			message(FATAL_ERROR \"copying Urho3D's include tree dereferenced failed\")
		endif()
	")
	if(WIN32 AND BUILDAT_SHIP_COMPILER)
		# What a C++ compile and link of a module needs and nothing else:
		# the whole distribution is 760 MB with clang, gdb and doxygen in
		# it. The driver finds cc1plus and the crt objects relative to
		# itself, so the layout under compiler/ is the distribution's.
		set(SC "${BUILDAT_SHIP_COMPILER}")
		install(DIRECTORY "${SC}/bin/" DESTINATION "${DST_COMPILER}/bin"
			FILES_MATCHING
			PATTERN "c++.exe" PATTERN "g++.exe" PATTERN "gcc.exe"
			PATTERN "as.exe" PATTERN "ld.exe" PATTERN "ld.bfd.exe" PATTERN "ar.exe"
			PATTERN "libgcc_s_seh-1.dll" PATTERN "libstdc++-6.dll"
			PATTERN "libwinpthread-1.dll" PATTERN "libgmp-10.dll"
			PATTERN "libmpfr-6.dll" PATTERN "libmpc-3.dll" PATTERN "libisl-23.dll"
			PATTERN "libzstd.dll" PATTERN "zlib1.dll" PATTERN "libiconv-2.dll"
			PATTERN "libintl-8.dll")
		file(GLOB SC_LIBEXEC "${SC}/libexec/gcc/x86_64-w64-mingw32/*")
		list(GET SC_LIBEXEC 0 SC_LIBEXEC_VER)
		get_filename_component(SC_GCC_VER "${SC_LIBEXEC_VER}" NAME)
		install(DIRECTORY "${SC_LIBEXEC_VER}/"
			DESTINATION "${DST_COMPILER}/libexec/gcc/x86_64-w64-mingw32/${SC_GCC_VER}"
			FILES_MATCHING PATTERN "cc1plus.exe" PATTERN "collect2.exe"
			PATTERN "*.dll" PATTERN "install-tools" EXCLUDE PATTERN "plugin" EXCLUDE)
		install(DIRECTORY "${SC}/lib/gcc" DESTINATION "${DST_COMPILER}/lib")
		# The C++ and libgcc import libraries beside lib/gcc: what -lstdc++
		# and -lgcc_s resolve to when a module links
		install(DIRECTORY "${SC}/lib/" DESTINATION "${DST_COMPILER}/lib"
			FILES_MATCHING PATTERN "libstdc++*.a" PATTERN "libgcc_s.a"
			PATTERN "libwinpthread*.a" PATTERN "libssp*.a"
			PATTERN "gcc" EXCLUDE PATTERN "clang" EXCLUDE PATTERN "python3.9" EXCLUDE
			PATTERN "bfd-plugins" EXCLUDE PATTERN "pkgconfig" EXCLUDE)
		install(DIRECTORY "${SC}/include/c++" DESTINATION "${DST_COMPILER}/include")
		install(DIRECTORY "${SC}/x86_64-w64-mingw32" DESTINATION "${DST_COMPILER}"
			PATTERN "bin" EXCLUDE)
		install(FILES "${SC}/version_info.txt" DESTINATION "${DST_COMPILER}" OPTIONAL)
	endif()
endif()
install(DIRECTORY "${URHO3D_HOME}/bin/CoreData" DESTINATION "${DST_SHARE}/Urho3D/bin")
install(DIRECTORY "${URHO3D_HOME}/bin/Data" DESTINATION "${DST_SHARE}/Urho3D/bin")

set(PACKAGE_NAME "${PROJECT_NAME}")
if(BUILD_CLIENT AND BUILD_SERVER)
	set(PACKAGE_NAME "${PACKAGE_NAME}-full")
elseif(BUILD_CLIENT)
	set(PACKAGE_NAME "${PACKAGE_NAME}-client")
elseif(BUILD_SERVER)
	set(PACKAGE_NAME "${PACKAGE_NAME}-server")
endif()
if(WIN32)
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		set(PACKAGE_NAME "${PACKAGE_NAME}-w64")
	else()
		set(PACKAGE_NAME "${PACKAGE_NAME}-w32")
	endif()
	set(CPACK_GENERATOR ZIP)
else()
	set(PACKAGE_NAME "${PACKAGE_NAME}-linux-${CMAKE_SYSTEM_PROCESSOR}")
	set(CPACK_GENERATOR TGZ)
endif()
message(STATUS "PACKAGE_NAME: ${PACKAGE_NAME}")
set(CPACK_PACKAGE_FILE_NAME "${PACKAGE_NAME}")
include(CPack)

message(STATUS "CMAKE_INSTALL_PREFIX: ${CMAKE_INSTALL_PREFIX}")
message(STATUS "Run 'make install' to install, or util/package.sh to make the archives.")

# vim: set noet ts=4 sw=4:
