cmake_minimum_required(VERSION 2.6)
project(qrcodegen C)

# Project Nayuki's QR Code generator 1.8.0, its C version, unmodified (MIT,
# in the sources' headers): the QR code of a TOTP secret ([STARPORT] 10a)
add_library(qrcodegen STATIC qrcodegen.c)
target_include_directories(qrcodegen PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
set_target_properties(qrcodegen PROPERTIES POSITION_INDEPENDENT_CODE ON)
