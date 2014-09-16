cmake_minimum_required(VERSION 2.6)
project(buildat)

#
# Libraries
#

add_subdirectory("3rdparty/cereal")
add_subdirectory("3rdparty/c55lib")

#
# Polycode
#

SET(POLYCODE_ROOT_DIR "${buildat_SOURCE_DIR}/../polycode")
SET(POLYCODE_RELEASE_DIR ${POLYCODE_ROOT_DIR}/Release/${CMAKE_SYSTEM_NAME})
SET(POLYCODE_CMAKE_DIR ${POLYCODE_ROOT_DIR}/CMake)
SET(CMAKE_INSTALL_PREFIX ${POLYCODE_RELEASE_DIR}/Standalone/)
SET(CMAKE_PREFIX_PATH
    ${POLYCODE_RELEASE_DIR}/Framework/Core/Dependencies
    ${POLYCODE_RELEASE_DIR}/Framework/Modules/Dependencies
    ${POLYCODE_RELEASE_DIR}/Framework/Tools/Dependencies
)

SET(CMAKE_DEBUG_POSTFIX "_d")
SET(CMAKE_MODULE_PATH
	${CMAKE_MODULE_PATH}
	${POLYCODE_CMAKE_DIR}
)
INCLUDE(${POLYCODE_CMAKE_DIR}/PolycodeDependencies.cmake)

include_directories("../polycode/Bindings/Contents/LUA/Include")

#
# Buildat
#

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -Wall")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wextra -Wno-unused-parameter")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O0 -Wall")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# Always output in color (useful when using head for build output)
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fdiagnostics-color=always")
# Security / crash protection
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fstack-protector-all")

include_directories(src)
include_directories(3rdparty/c55lib)

# Client
set(CLIENT_EXE_NAME buildat_client)
set(CLIENT_SRCS
	src/client/main.cpp
)
add_executable(${CLIENT_EXE_NAME} ${CLIENT_SRCS})
TARGET_LINK_LIBRARIES(${CLIENT_EXE_NAME}
	${POLYCODE_DEPENDENCY_LIBS}
	c55lib
)

# Server
set(SERVER_EXE_NAME buildat_server)
set(SERVER_SRCS
	src/server/main.cpp
	src/server/state.cpp
	src/server/rccpp.cpp
	src/impl/fs.cpp
)
add_executable(${SERVER_EXE_NAME} ${SERVER_SRCS})
TARGET_LINK_LIBRARIES(${SERVER_EXE_NAME}
	c55lib
	dl
)
add_definitions()

