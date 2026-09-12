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
# installed copy wants. See local/world_persistence_plan.md.
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
set(URHO3D_LUAJIT FALSE CACHE BOOL "Enable Urho3D LuaJIT")
if(NOT DEFINED URHO3D_64BIT)
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		set(URHO3D_64BIT TRUE)
	else()
		set(URHO3D_64BIT FALSE)
	endif()
endif()

set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build")
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
	set(URHO3D_BUNDLE_CMAKE_ARGS
		-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
		-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}
		-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}
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
	execute_process(
		COMMAND ${CMAKE_COMMAND} ${URHO3D_BUNDLE_CMAKE_ARGS} "${URHO3D_HOME}"
		WORKING_DIRECTORY "${URHO3D_BUILD_DIR}"
		RESULT_VARIABLE URHO3D_CONFIGURE_RESULT
	)
	if(NOT URHO3D_CONFIGURE_RESULT EQUAL 0)
		message(FATAL_ERROR "Failed to configure bundled Urho3D")
	endif()
	add_custom_target(urho3d_build
		COMMAND ${CMAKE_COMMAND} --build "${URHO3D_BUILD_DIR}" --parallel
		WORKING_DIRECTORY "${URHO3D_BUILD_DIR}"
		COMMENT "Building bundled Urho3D"
		VERBATIM
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
else()
	set(LUA_INCLUDE_DIRS "${URHO3D_HOME}/Source/ThirdParty/Lua/src")
	set(LUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/Lua/libLua.a")
endif()
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
add_subdirectory("3rdparty/luabind-deboostified")

include_directories("src")
include_directories("3rdparty/cereal/include")
include_directories("3rdparty/c55lib")
include_directories("3rdparty/smallsha1")
include_directories("3rdparty/polyvox/library/PolyVoxCore/include")
include_directories("3rdparty/zlib")
include_directories("${CMAKE_BINARY_DIR}/3rdparty/zlib")
include_directories("3rdparty/zstd/lib")
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
add_library(${BUILDAT_CORE_NAME} SHARED ${BUILDAT_CORE_SRCS})
target_link_libraries(${BUILDAT_CORE_NAME}
	c55lib
	smallsha1
	PolyVoxCore
	zlib
	zstd
)
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

if(WIN32)
	set(DST_BIN "bin")
	set(DST_SHARE ".")
	set(DST_COMPILER "${DST_SHARE}/compiler")

	install(DIRECTORY "${CMAKE_SOURCE_DIR}/doc" DESTINATION ".")
	install(FILES "${CMAKE_SOURCE_DIR}/NOTICE" DESTINATION ".")
	install(FILES "${CMAKE_SOURCE_DIR}/README.md" DESTINATION ".")

	message(STATUS "CMAKE_CXX_COMPILER: ${CMAKE_CXX_COMPILER}")
	get_filename_component(COMPILER_BIN_PATH "${CMAKE_CXX_COMPILER}" DIRECTORY)
	message(STATUS "COMPILER_BIN_PATH: ${COMPILER_BIN_PATH}")
	get_filename_component(COMPILER_USR_PATH "${COMPILER_BIN_PATH}" DIRECTORY)
	message(STATUS "COMPILER_USR_PATH: ${COMPILER_USR_PATH}")

	install(TARGETS ${BUILDAT_CORE_NAME} DESTINATION "${DST_BIN}")

	# Always copy these DLLs to the same directory as the executables. On the
	# server, they also exist in the compiler's path, but there really is no
	# reasonable way of accessing them from there.
	# Even Rust does it this way: https://github.com/rust-lang/rust/issues/1011
	install(FILES "${COMPILER_USR_PATH}/bin/libwinpthread-1.dll" DESTINATION "${DST_BIN}")
	install(FILES "${COMPILER_USR_PATH}/bin/libgcc_s_dw2-1.dll" DESTINATION "${DST_BIN}")
	install(FILES "${COMPILER_USR_PATH}/bin/libstdc++-6.dll" DESTINATION "${DST_BIN}")

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
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/3rdparty/polyvox/library/PolyvoxCore/include" DESTINATION "${DST_SHARE}/3rdparty/polyvox/library/PolyvoxCore")
		install(DIRECTORY "${URHO3D_HOME}/Source" DESTINATION "${DST_SHARE}/Urho3D")
		install(FILES "${URHO3D_BUILD_DIR}/include/Urho3D/Urho3D.h" DESTINATION "${DST_SHARE}/Urho3D/Build/include/Urho3D")

		install(DIRECTORY "${COMPILER_USR_PATH}/bin" DESTINATION "${DST_COMPILER}")
		install(DIRECTORY "${COMPILER_USR_PATH}/i686-w64-mingw32" DESTINATION "${DST_COMPILER}")
		install(DIRECTORY "${COMPILER_USR_PATH}/include" DESTINATION "${DST_COMPILER}")
		install(DIRECTORY "${COMPILER_USR_PATH}/lib" DESTINATION "${DST_COMPILER}")
		install(DIRECTORY "${COMPILER_USR_PATH}/licenses" DESTINATION "${DST_COMPILER}")
		install(FILES "${COMPILER_USR_PATH}/build-info.txt" DESTINATION "${DST_COMPILER}")
		set(BIG_EXECUTABLES
			cc1.exe
			cc1plus.exe
			liblto_plugin-0.dll
			liblto_plugin.dll.a
		)
		set(BIG_EXECUTABLES_SUBDIR "libexec/gcc/i686-w64-mingw32/4.9.1/")
		foreach(BIG_EXE ${BIG_EXECUTABLES})
			install(FILES "${COMPILER_USR_PATH}/${BIG_EXECUTABLES_SUBDIR}/${BIG_EXE}"
					DESTINATION "${DST_COMPILER}/${BIG_EXECUTABLES_SUBDIR}")
		endforeach()
	endif()

	install(DIRECTORY "${URHO3D_HOME}/bin/CoreData" DESTINATION "${DST_SHARE}/Urho3D/bin")
	install(DIRECTORY "${URHO3D_HOME}/bin/Data" DESTINATION "${DST_SHARE}/Urho3D/bin")
	install(FILES "${URHO3D_LIBRARY_FILE}" DESTINATION "${DST_BIN}")

	set(PACKAGE_NAME "${PROJECT_NAME}")
	if(BUILD_CLIENT AND BUILD_SERVER)
		set(PACKAGE_NAME "${PACKAGE_NAME}-full")
	elseif(BUILD_CLIENT)
		set(PACKAGE_NAME "${PACKAGE_NAME}-client")
	elseif(BUILD_SERVER)
		set(PACKAGE_NAME "${PACKAGE_NAME}-server")
	endif()
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		set(PACKAGE_NAME "${PACKAGE_NAME}-w64")
	else()
		set(PACKAGE_NAME "${PACKAGE_NAME}-w32")
	endif()
	message(STATUS "PACKAGE_NAME: ${PACKAGE_NAME}")

	set(CPACK_PACKAGE_FILE_NAME "${PACKAGE_NAME}")
	set(CPACK_GENERATOR ZIP)
	include(CPACK)

	message(STATUS "CMAKE_INSTALL_PREFIX: ${CMAKE_INSTALL_PREFIX}")
	message(STATUS "Run 'make install' to install, or 'make package' to create a package.")
endif()

# vim: set noet ts=4 sw=4:
