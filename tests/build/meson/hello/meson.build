# The hello module of tests/build.sh's meson fixture: a program with
# resources that links the greet module's DLL, found with pkg-config.
project('hello', 'c', default_options: ['buildtype=release'])
res = import('windows').compile_resources('hello.rc')
executable('hello', 'main.c', res, dependencies: dependency('greet'), install: true)
