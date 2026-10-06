/* GdkPixbuf for tests/gtk.sh: loads the image it's given, as GtkBuilder
 * loads images (GTK's widget factory has an SVG), and says its size. SVGs
 * need librsvg's loader, which the runtime finds through loaders.cache. */
#include <gdk-pixbuf/gdk-pixbuf.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        g_printerr("usage: svg-size FILE\n");
        return 2;
    }
    GError *error = NULL;
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(argv[1], &error);
    if (!pixbuf) {
        g_print("error: %s\n", error->message);
        g_error_free(error);
        return 1;
    }
    g_print("loaded %dx%d\n", gdk_pixbuf_get_width(pixbuf), gdk_pixbuf_get_height(pixbuf));
    g_object_unref(pixbuf);
    return 0;
}
