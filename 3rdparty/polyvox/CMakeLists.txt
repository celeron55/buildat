# Copyright (c) 2007-2012 Matt Williams
# Copyright (c) 2007-2012 David Williams
# 
# This software is provided 'as-is', without any express or implied
# warranty. In no event will the authors be held liable for any damages
# arising from the use of this software.
# 
# Permission is granted to anyone to use this software for any purpose,
# including commercial applications, and to alter it and redistribute it
# freely, subject to the following restrictions:
# 
# 1. The origin of this software must not be misrepresented; you must not
# claim that you wrote the original software. If you use this software
# in a product, an acknowledgment in the product documentation would be
# appreciated but is not required.
# 
# 2. Altered source versions must be plainly marked as such, and must not be
# misrepresented as being the original software.
# 
# 3. This notice may not be removed or altered from any source
# distribution.

CMAKE_MINIMUM_REQUIRED(VERSION 2.8.3)

PROJECT(PolyVox)

SET(POLYVOX_VERSION_MAJOR "0")
SET(POLYVOX_VERSION_MINOR "2")
SET(POLYVOX_VERSION_PATCH "1")
SET(POLYVOX_VERSION "${POLYVOX_VERSION_MAJOR}.${POLYVOX_VERSION_MINOR}.${POLYVOX_VERSION_PATCH}" CACHE STRING "PolyVox version")
MARK_AS_ADVANCED(FORCE POLYVOX_VERSION)

SET_PROPERTY(GLOBAL PROPERTY USE_FOLDERS ON)
include(FeatureSummary)

FIND_PACKAGE(Doxygen)
OPTION(ENABLE_EXAMPLES "Should the examples be built" ON)

#SET(LIBRARY_TYPE "DYNAMIC" CACHE STRING "Should the library be STATIC or DYNAMIC")
#SET_PROPERTY(CACHE LIBRARY_TYPE PROPERTY STRINGS DYNAMIC STATIC)
#IF(WIN32)
#	SET(LIBRARY_TYPE "STATIC")
#ENDIF()

SET(LIBRARY_TYPE "STATIC")

if(MSVC AND (MSVC_VERSION LESS 1600))
	# Require boost for older (pre-vc2010) Visual Studio compilers
	# See library/include/polyvoxcore/impl/TypeDef.h
	find_package(Boost REQUIRED)
	include_directories(${Boost_INCLUDE_DIRS})
endif()

IF(CMAKE_COMPILER_IS_GNUCXX) #Maybe "OR MINGW"
	ADD_DEFINITIONS(-std=c++0x) #Enable C++0x mode
ENDIF()
if(CMAKE_CXX_COMPILER MATCHES "clang")
	ADD_DEFINITIONS(-std=c++0x) #Enable C++0x mode
endif()

ADD_SUBDIRECTORY(library)

INCLUDE(Packaging.cmake)

