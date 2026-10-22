cmake_minimum_required(VERSION 3.21)
project(hermetic NONE)
# What a build would find on this machine: the prefixes CMake searches, a Git
# under Program Files (where FindGit looks, through those prefixes), whether
# find_package reads CMake's package registries, and a Python from the
# registry (the build's PATH has none).
find_program(GIT git PATH_SUFFIXES Git/cmd Git/bin NO_CACHE)
find_package(Python3 COMPONENTS Interpreter)
file(WRITE "${CMAKE_INSTALL_PREFIX}/found.txt"
  "prefixes=${CMAKE_SYSTEM_PREFIX_PATH}\n"
  "git=${GIT}\n"
  "registry=${CMAKE_FIND_USE_PACKAGE_REGISTRY}\n"
  "system registry=${CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY}\n"
  "python=${Python3_FOUND}\n")
