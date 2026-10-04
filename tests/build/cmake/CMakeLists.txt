# A project for tests/build.sh, of the C fixture's sources (tests/build/c),
# built with CMake and Ninja from CMake's image, and zig's compilers: a static
# library of C and C++, and a program with resources that links it.
cmake_minimum_required(VERSION 3.20)
project(hello LANGUAGES C CXX RC)

add_library(greet STATIC greet.c twice.cpp)
target_include_directories(greet PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(hello main.c hello.rc)
target_link_libraries(hello PRIVATE greet)

install(TARGETS hello greet)
install(FILES greet.h DESTINATION include)
