cmake_minimum_required(VERSION 2.6)
project(md4c C)

# md4c's parser alone; Buildat renders from its callbacks
# (src/impl/markup.cpp), so md4c-html and entity.c are not taken
add_library(md4c OBJECT md4c.c)
set_target_properties(md4c PROPERTIES POSITION_INDEPENDENT_CODE TRUE)
target_include_directories(md4c PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
