cmake_minimum_required(VERSION 2.6)
project(c55lib)
set(SRCS
	c55/getopt.cpp
	c55/filesys.cpp
	c55/os.cpp
)
add_library(c55lib STATIC ${SRCS})
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -Wall")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O0 -Wall")
