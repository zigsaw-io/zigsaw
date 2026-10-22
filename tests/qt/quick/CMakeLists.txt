# tests/qt.sh's Qt Quick app: a QML module compiled in (qmlcachegen), Qt
# Quick Controls from the runtime's qml folder.
cmake_minimum_required(VERSION 3.22)
project(hello-quick LANGUAGES CXX)
find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2)
qt_standard_project_setup(REQUIRES 6.5)
qt_add_executable(hello-quick main.cpp)
qt_add_qml_module(hello-quick URI Hello QML_FILES Main.qml)
target_link_libraries(hello-quick PRIVATE Qt6::Quick Qt6::QuickControls2)
install(TARGETS hello-quick RUNTIME DESTINATION bin)
