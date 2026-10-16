/* A GTK 3 app for tests/gtk.sh: says which GTK and ATK it has, whether
 * GTK 3's own settings schemas and the legacy icon theme's icons are found
 * (they're in GTK 3's runtime, GLib and Adwaita in GTK 4's), opens a window,
 * waits for GTK to draw it, and quits. */
#define G_SETTINGS_ENABLE_BACKEND
#include <gio/gsettingsbackend.h>
#include <gtk/gtk.h>
#include <atk/atk.h>

static gboolean drawn(GtkWidget *window, cairo_t *cr, gpointer data) {
    g_print("drew a frame\n");
    gtk_main_quit();
    return FALSE;
}

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);
    g_print("GTK %u.%u.%u\n", gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
    g_print("ATK %u.%u.%u\n", atk_get_major_version(), atk_get_minor_version(), atk_get_micro_version());
    g_print("settings in %s\n", G_OBJECT_TYPE_NAME(g_settings_backend_get_default()));

    GSettingsSchema *schema = g_settings_schema_source_lookup(g_settings_schema_source_get_default(), "org.gtk.Settings.FileChooser", TRUE);
    g_print("FileChooser schema %s\n", schema ? "found" : "missing");
    if (schema) g_settings_schema_unref(schema);

    GtkIconInfo *icon = gtk_icon_theme_lookup_icon(gtk_icon_theme_get_default(), "document-open", 48, 0);
    g_print("icon document-open %s\n", icon ? "found" : "missing");
    if (icon) {
        GdkPixbuf *pixbuf = gtk_icon_info_load_icon(icon, NULL);
        g_print("loaded it at %dx%d\n", pixbuf ? gdk_pixbuf_get_width(pixbuf) : 0, pixbuf ? gdk_pixbuf_get_height(pixbuf) : 0);
        if (pixbuf) g_object_unref(pixbuf);
        g_object_unref(icon);
    }

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "zigsaw GTK 3");
    gtk_container_add(GTK_CONTAINER(window), gtk_label_new("hello from GTK 3"));
    g_signal_connect_after(window, "draw", G_CALLBACK(drawn), NULL);
    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}
