#
# [BUILD_TIME]: writes OUT with what the bundled Urho3D's source is -- its
# git tree id and a hash of its uncommitted diff -- rewritten only when that
# changes, so the engine's build is entered only then. Outside a checkout
# the text is fixed: the engine builds once.
# simplified: untracked files in 3rdparty/Urho3D do not count; a new engine
# source file is committed or added before it builds.
#   cmake -DSRC=<source dir> -DOUT=<file> -P util/urho3d_stamp.cmake
execute_process(COMMAND git rev-parse HEAD:3rdparty/Urho3D
	WORKING_DIRECTORY "${SRC}" OUTPUT_VARIABLE tree
	RESULT_VARIABLE status OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT status EQUAL 0)
	set(tree "no checkout")
endif()
execute_process(COMMAND git diff HEAD -- 3rdparty/Urho3D
	WORKING_DIRECTORY "${SRC}" OUTPUT_VARIABLE diff ERROR_QUIET)
string(SHA256 diff "${diff}")
set(text "${tree} ${diff}\n")
set(old "")
if(EXISTS "${OUT}")
	file(READ "${OUT}" old)
endif()
if(NOT old STREQUAL text)
	file(WRITE "${OUT}" "${text}")
endif()
