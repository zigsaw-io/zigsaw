# tests/qt.sh's app: built against Qt's SDK image with CMake, run on its
# runtime.
cmake_minimum_required(VERSION 3.22)
project(hello-qt LANGUAGES CXX)
find_package(Qt6 REQUIRED COMPONENTS Widgets Network)
qt_standard_project_setup()
qt_add_executable(hello-qt hello.cpp)
target_link_libraries(hello-qt PRIVATE Qt6::Widgets Qt6::Network)
install(TARGETS hello-qt RUNTIME DESTINATION bin)
