cmake_minimum_required(VERSION 2.6)
project(mbedtls C)

# Mbed TLS 3.6.5's library/ and include/ ([STARPORT] 10f): TLS for the web
# client's channel to a Starport, PBKDF2 and AES-GCM for the client's cached
# Starport ID tokens. Upstream sources are unmodified, with the default
# configuration (include/mbedtls/mbedtls_config.h); this file replaces
# upstream's build, which generates files and builds programs and tests.
file(GLOB SRCS "${CMAKE_CURRENT_SOURCE_DIR}/library/*.c")
add_library(mbedtls STATIC ${SRCS})
target_include_directories(mbedtls PUBLIC
	"${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(mbedtls PRIVATE
	"${CMAKE_CURRENT_SOURCE_DIR}/library")
set_target_properties(mbedtls PROPERTIES POSITION_INDEPENDENT_CODE ON)
