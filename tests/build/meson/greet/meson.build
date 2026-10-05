# The greet module of tests/build.sh's meson fixture: the C fixture's library
# (tests/build/c), of C and C++, as a DLL with an import library and a
# pkg-config file, which the hello module finds.
project('greet', 'c', 'cpp', version: '1', default_options: ['buildtype=release'])
greet = shared_library('greet', 'greet.c', 'twice.cpp', install: true)
install_headers('greet.h')
import('pkgconfig').generate(greet, description: 'greets')
