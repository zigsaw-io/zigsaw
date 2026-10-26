# Boost's headers, unpacked into the build's prefix from Boost's b2 release
# (recipes/osm2pgsql.json), for osm2pgsql's find_package(Boost CONFIG): it
# uses only Geometry's headers, so there are no libraries.
get_filename_component(_boost_include "${CMAKE_CURRENT_LIST_DIR}/../../../include" ABSOLUTE)
set(Boost_INCLUDE_DIR "${_boost_include}")
set(Boost_INCLUDE_DIRS "${_boost_include}")
set(Boost_LIBRARIES "")
set(Boost_VERSION 1.92.0)
if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED)
    set_target_properties(Boost::headers PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${_boost_include}")
endif()
unset(_boost_include)
