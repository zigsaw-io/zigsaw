# tests/gtk.sh's app: built against GTK's SDK image, run on its runtime.
project('hello-gtk', 'c', default_options: ['buildtype=release'])
executable('hello-gtk', 'hello.c', dependencies: [dependency('gtk4'), dependency('libadwaita-1')], install: true)
