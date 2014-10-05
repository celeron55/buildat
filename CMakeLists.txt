# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2014 Perttu Ahola <celeron55@gmail.com>

cmake_minimum_required(VERSION 2.6)
project(buildat)

#
# Bundled libraries
#

add_subdirectory("3rdparty/cereal")
add_subdirectory("3rdparty/c55lib")
add_subdirectory("3rdparty/smallsha1")
add_subdirectory("3rdparty/polyvox")

include_directories("src")
include_directories("3rdparty/cereal/include")
include_directories("3rdparty/c55lib")
include_directories("3rdparty/smallsha1")
include_directories("3rdparty/polyvox/library/PolyVoxCore/include")

#
# Global options
#

set(BUILD_SERVER TRUE CACHE BOOL "Build server")
set(BUILD_CLIENT TRUE CACHE BOOL "Build client")

#
# Urho3D dependency
#

set(URHO3D_HOME $ENV{URHO3D_HOME})
message(STATUS "URHO3D_HOME=\"${URHO3D_HOME}\"")
if("${URHO3D_HOME}" STREQUAL "")
	message(FATAL_ERROR "You need to set the URHO3D_HOME environment variable.")
endif()

set(CMAKE_MODULE_PATH ${URHO3D_HOME}/Source/CMake/Modules PATH "Path to Urho3D-specific CMake modules")

if(MINGW)
	# Urho3D Does some stupid things when MinGW is set, messing up our
	# precious core/exe linking stage
	set(MINGW 0)
	include(Urho3D-CMake-common)
	set(MINGW 1)
else()
	include(Urho3D-CMake-common)
endif()

find_package(Urho3D REQUIRED)
include_directories(${URHO3D_INCLUDE_DIRS})

# Urho3D's Lua
include_directories("${URHO3D_HOME}/Source/ThirdParty/Lua/src")
include_directories("${URHO3D_HOME}/Source/ThirdParty/toluapp/include")

# Run some automagic from Urho3D.
# This appends to at least ${ABSOLUTE_PATH_LIBS} and {LINK_LIBS_ONLY}
define_dependency_libs("Urho3D")

#
# Buildat
#

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -Wall")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wextra -Wno-unused-parameter")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O0 -Wall")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin") # Executables
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib") # Shared libs
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib") # Static libs

# Always output in color (useful when using head for build output)
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fdiagnostics-color=always")
# Security / crash protection
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fstack-protector-all")

set(CLIENT_EXE_NAME buildat_client)
set(SERVER_EXE_NAME buildat_server)
set(SERVER_CORE_NAME buildat_server_core)

if(BUILD_CLIENT)
	# Client
	set(CLIENT_SRCS
		src/client/main.cpp
		src/client/state.cpp
		src/client/app.cpp
		src/client/config.cpp
		src/core/log.cpp
		src/core/json.cpp
		src/impl/fs.cpp
		src/impl/tcpsocket.cpp
		src/impl/sha1.cpp
		src/impl/packet_stream.cpp
		src/lua_bindings/util.cpp
		src/lua_bindings/init.cpp
		src/lua_bindings/misc.cpp
		src/lua_bindings/cereal.cpp
		src/lua_bindings/voxel.cpp
	)

	add_executable(${CLIENT_EXE_NAME} ${CLIENT_SRCS})

	target_link_libraries(${CLIENT_EXE_NAME}
		c55lib
		smallsha1
		PolyVoxCore
		${ABSOLUTE_PATH_LIBS}
		${LINK_LIBS_ONLY}
		${URHO3D_HOME}/Build/ThirdParty/toluapp/src/lib/libtoluapp.a
	)
	if(URHO3D_LUAJIT)
		target_link_libraries(${CLIENT_EXE_NAME}
			${URHO3D_HOME}/Build/ThirdParty/LuaJIT/libLuaJIT.a
		)
	else()
		target_link_libraries(${CLIENT_EXE_NAME}
			${URHO3D_HOME}/Build/ThirdParty/Lua/libLua.a
		)
	endif()
endif(BUILD_CLIENT)

if(BUILD_SERVER)
	# Server core library - shared code between executable and modules
	set(SERVER_CORE_SRCS
		src/core/log.cpp
		src/core/json.cpp
		src/impl/fs.cpp
		src/impl/event.cpp
		src/impl/tcpsocket.cpp
		src/impl/module.cpp
		src/impl/sha1.cpp
		src/impl/packet_stream.cpp
		src/impl/voxel.cpp
	)
	if(WIN32)
		set(SERVER_CORE_SRCS ${SERVER_CORE_SRCS} src/impl/windows/file_watch.cpp)
		set(SERVER_CORE_SRCS ${SERVER_CORE_SRCS} src/impl/windows/process.cpp)
	else()
		set(SERVER_CORE_SRCS ${SERVER_CORE_SRCS} src/impl/linux/file_watch.cpp)
		set(SERVER_CORE_SRCS ${SERVER_CORE_SRCS} src/impl/linux/process.cpp)
	endif()
	add_library(${SERVER_CORE_NAME} SHARED ${SERVER_CORE_SRCS})
	target_link_libraries(${SERVER_CORE_NAME}
		c55lib
		smallsha1
		PolyVoxCore
	)
	if(WIN32)
		target_link_libraries(${SERVER_CORE_NAME} wsock32 ws2_32)
	endif()

	# Server
	set(SERVER_SRCS
		src/server/main.cpp
		src/server/state.cpp
		src/server/rccpp.cpp
		src/server/config.cpp
	)
	add_executable(${SERVER_EXE_NAME} ${SERVER_SRCS})

	target_link_libraries(${SERVER_EXE_NAME}
		${SERVER_CORE_NAME}
		c55lib
		smallsha1
		${ABSOLUTE_PATH_LIBS}
		${LINK_LIBS_ONLY}
	)
	if(WIN32)
	else()
		target_link_libraries(${SERVER_EXE_NAME} dl)
	endif()
endif(BUILD_SERVER)

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

	if(BUILD_CLIENT)
		install(TARGETS ${CLIENT_EXE_NAME} DESTINATION "${DST_BIN}")
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/client" DESTINATION "${DST_SHARE}")
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/extensions" DESTINATION "${DST_SHARE}")
		install(FILES "${CMAKE_SOURCE_DIR}/util/windows/launch_client.bat" DESTINATION ".")
		if(NOT BUILD_SERVER)
			install(FILES "${COMPILER_USR_PATH}/bin/libwinpthread-1.dll" DESTINATION "${DST_BIN}")
			install(FILES "${COMPILER_USR_PATH}/bin/libgcc_s_dw2-1.dll" DESTINATION "${DST_BIN}")
			install(FILES "${COMPILER_USR_PATH}/bin/libstdc++-6.dll" DESTINATION "${DST_BIN}")
		endif()
	endif()

	if(BUILD_SERVER)
		install(TARGETS ${SERVER_EXE_NAME} DESTINATION "${DST_BIN}")
		install(TARGETS ${SERVER_CORE_NAME} DESTINATION "${DST_BIN}")
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/builtin" DESTINATION "${DST_SHARE}")
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/games" DESTINATION "${DST_SHARE}")
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/src" DESTINATION "${DST_SHARE}")
		install(FILES "${CMAKE_SOURCE_DIR}/util/windows/launch_server.bat" DESTINATION ".")

		install(DIRECTORY "${CMAKE_SOURCE_DIR}/3rdparty/cereal/include" DESTINATION "${DST_SHARE}/3rdparty/cereal")
		install(DIRECTORY "${URHO3D_HOME}/Source" DESTINATION "${DST_SHARE}/Urho3D")
		install(FILES "${URHO3D_HOME}/Build/Engine/Urho3D.h" DESTINATION "${DST_SHARE}/Urho3D/Build/Engine")

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

	install(DIRECTORY "${URHO3D_HOME}/Bin/CoreData" DESTINATION "${DST_SHARE}/Urho3D/Bin")
	install(DIRECTORY "${URHO3D_HOME}/Bin/Data" DESTINATION "${DST_SHARE}/Urho3D/Bin")
	install(FILES "${URHO3D_HOME}/Bin/Urho3D.dll" DESTINATION "${DST_BIN}")

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
