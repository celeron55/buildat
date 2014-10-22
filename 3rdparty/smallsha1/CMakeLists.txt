cmake_minimum_required(VERSION 2.6)
project(smallsha1)
set(SRCS
	smallsha1.cpp
)
add_library(smallsha1 STATIC ${SRCS})
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -Wall -fPIC")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O0 -Wall -fPIC")
