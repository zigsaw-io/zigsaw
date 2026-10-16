# tests/gtk.sh's GTK 3 app: built against GTK 3's SDK image with GTK 4's,
# run on both runtimes.
project('hello-gtk3', 'c', default_options: ['buildtype=release'])
executable('hello-gtk3', 'hello3.c', dependencies: [dependency('gtk+-3.0'), dependency('atk')], install: true)
