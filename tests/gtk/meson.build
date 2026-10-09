# tests/gtk.sh's app: built against GTK's SDK image, run on its runtime, with
# programs that fetch URLs with libsoup, load images with GdkPixbuf, check
# spelling with enchant, and draw text in a font file with pangocairo.
project('hello-gtk', 'c', default_options: ['buildtype=release'])
executable('hello-gtk', 'hello.c', dependencies: [dependency('gtk4'), dependency('libadwaita-1')], install: true)
executable('soup-get', 'soup.c', dependencies: [dependency('libsoup-3.0')], install: true)
executable('svg-size', 'svg.c', dependencies: [dependency('gdk-pixbuf-2.0')], install: true)
executable('spell', 'spell.c', dependencies: [dependency('enchant-2')], install: true)
executable('font-file', 'font.c', dependencies: [dependency('pangocairo')], install: true)
