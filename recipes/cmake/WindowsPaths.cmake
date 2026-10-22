# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file LICENSE.rst or https://cmake.org/licensing for details.

# zigsaw: CMake 4.4.4's Modules/Platform/WindowsPaths.cmake without the
# program-files folders, so that builds don't find what the machine has
# installed there: CMake found them through %SystemDrive% though the build's
# environment has no ProgramFiles, and a runner's PostgreSQL went into Qt's
# SQL plugins, a desktop's Git into Flameshot's configure. For the same
# reason, unless a project asks for them, CMake's package registries
# (Software\Kitware\CMake\Packages in HKCU and HKLM) are off, and FindPython
# doesn't look for Pythons in the registry, where it found the machine's
# before the build's on PATH. Paths given with CMAKE_PREFIX_PATH or
# <Package>_ROOT are searched as before.


# Block multiple inclusion because "CMakeCInformation.cmake" includes
# "Platform/${CMAKE_SYSTEM_NAME}" even though the generic module
# "CMakeSystemSpecificInformation.cmake" already included it.
# The extra inclusion is a work-around documented next to the include()
# call, so this can be removed when the work-around is removed.
if(__WINDOWS_PATHS_INCLUDED)
  return()
endif()
set(__WINDOWS_PATHS_INCLUDED 1)

if(NOT DEFINED CMAKE_FIND_USE_PACKAGE_REGISTRY)
  set(CMAKE_FIND_USE_PACKAGE_REGISTRY OFF)
endif()
if(NOT DEFINED CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY)
  set(CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY OFF)
endif()
foreach(_python Python Python2 Python3)
  if(NOT DEFINED ${_python}_FIND_REGISTRY)
    set(${_python}_FIND_REGISTRY NEVER)
  endif()
endforeach()
unset(_python)

# Add the CMake install location.
# CMAKE_ROOT is CMAKE_INSTALL_PREFIX/share/cmake, so we need to go two levels up.
# When CMake runs from its build tree, CMAKE_ROOT is the source tree instead.
get_filename_component(_CMAKE_INSTALL_DIR "${CMAKE_ROOT}" PATH)
get_filename_component(_CMAKE_INSTALL_DIR "${_CMAKE_INSTALL_DIR}" PATH)
get_property(_cmake_running_in_build_tree GLOBAL PROPERTY
  _CMAKE_RUNNING_IN_BUILD_TREE)
if(_cmake_running_in_build_tree)
  set(_CMAKE_INSTALL_DIR "")
endif()
unset(_cmake_running_in_build_tree)
if(_CMAKE_INSTALL_DIR)
  list(APPEND CMAKE_SYSTEM_PREFIX_PATH "${_CMAKE_INSTALL_DIR}")
endif()

if (NOT CMAKE_FIND_NO_INSTALL_PREFIX)
  # Add other locations.
  list(APPEND CMAKE_SYSTEM_PREFIX_PATH
    # Project install destination.
    "${CMAKE_INSTALL_PREFIX}"
    )
  if (CMAKE_STAGING_PREFIX)
    list(APPEND CMAKE_SYSTEM_PREFIX_PATH
      # User-supplied staging prefix.
      "${CMAKE_STAGING_PREFIX}"
    )
  endif()
endif()
_cmake_record_install_prefix()

if(CMAKE_CROSSCOMPILING AND NOT CMAKE_HOST_SYSTEM_NAME MATCHES "Windows")
  # MinGW (useful when cross compiling from linux with CMAKE_FIND_ROOT_PATH set)
  list(APPEND CMAKE_SYSTEM_PREFIX_PATH /)
endif()

list(APPEND CMAKE_SYSTEM_INCLUDE_PATH
  )

# mingw can also link against dlls which can also be in /bin, so list this too
if (NOT CMAKE_FIND_NO_INSTALL_PREFIX)
  list(APPEND CMAKE_SYSTEM_LIBRARY_PATH
    "${CMAKE_INSTALL_PREFIX}/bin"
  )
  if (CMAKE_STAGING_PREFIX)
    list(APPEND CMAKE_SYSTEM_LIBRARY_PATH
      "${CMAKE_STAGING_PREFIX}/bin"
    )
  endif()
endif()
if(_CMAKE_INSTALL_DIR)
  list(APPEND CMAKE_SYSTEM_LIBRARY_PATH
    "${_CMAKE_INSTALL_DIR}/bin"
    )
endif()
list(APPEND CMAKE_SYSTEM_LIBRARY_PATH
  /bin
  )

list(APPEND CMAKE_SYSTEM_PROGRAM_PATH
  )
