/* Icons for tests/gtk.sh: whether GTK's icon theme has each icon named, as
 * it looks for them in the share directories of XDG_DATA_DIRS. Each line is
 * flushed, so it's seen even if the program then ends badly. */
#include <gtk/gtk.h>
#include <stdio.h>

int main(int argc, char **argv) {
    gtk_init();
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    for (int i = 1; i < argc; i++) {
        printf("icon %s %s\n", argv[i], gtk_icon_theme_has_icon(theme, argv[i]) ? "found" : "missing");
        fflush(stdout);
    }
    return 0;
}
