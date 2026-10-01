cmake_minimum_required(VERSION 2.6)
project(sqlite C)

# SQLite 3.50.2 (2025-06-28), the official amalgamation, unmodified. shell.c is
# not here; nothing in buildat wants the command line tool, and the system one
# reads the same files.
#
# The compile options are the ones the upstream "recommended options" page
# lists for an application that ships its own SQLite, minus the ones that would
# take away something a save might want. SQLITE_DQS=0 is the notable one: a
# double-quoted string that is not a column name is an error rather than a
# string literal, which is the historical misfeature behind a good share of
# SQL injection in other people's code.
# An object library rather than a static one: the objects go into
# buildat_core, whose shared library is what exports sqlite3_* to
# builtin/storage. A static archive would be dropped at link time instead,
# since nothing in buildat_core itself calls sqlite.
add_library(sqlite OBJECT src/sqlite3.c)
set_target_properties(sqlite PROPERTIES POSITION_INDEPENDENT_CODE TRUE)
target_include_directories(sqlite PUBLIC src)
target_compile_definitions(sqlite PRIVATE
	SQLITE_DQS=0
	SQLITE_THREADSAFE=1
	SQLITE_DEFAULT_MEMSTATUS=0
	SQLITE_DEFAULT_WAL_SYNCHRONOUS=1
	SQLITE_LIKE_DOESNT_MATCH_BLOBS
	SQLITE_MAX_EXPR_DEPTH=0
	SQLITE_OMIT_DEPRECATED
	SQLITE_OMIT_PROGRESS_CALLBACK
	SQLITE_OMIT_SHARED_CACHE
	# No sqlite3_load_extension(): a save file must not be able to bring code
	# with it
	SQLITE_OMIT_LOAD_EXTENSION
)
# An object library has nothing to link; buildat_core carries pthread and dl
# for it.
