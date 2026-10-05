/* A GTK app for tests/gtk.sh: says where GLib keeps its files and settings,
 * and which libadwaita it has, opens a window, waits for GTK to draw its
 * first frame, says which renderer drew it, and quits. */
#define G_SETTINGS_ENABLE_BACKEND
#include <gio/gsettingsbackend.h>
#include <gtk/gtk.h>
#include <adwaita.h>

static gboolean drawn(GtkWidget *window, GdkFrameClock *clock, gpointer app) {
    GskRenderer *renderer = gtk_native_get_renderer(GTK_NATIVE(window));
    g_print("drew a frame with %s\n", renderer ? G_OBJECT_TYPE_NAME(renderer) : "no renderer");
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *app, gpointer data) {
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "zigsaw");
    gtk_window_set_child(GTK_WINDOW(window), gtk_label_new("hello from GTK"));
    gtk_widget_add_tick_callback(window, drawn, app, NULL);
    gtk_window_present(GTK_WINDOW(window));
    g_print("GTK %u.%u.%u\n", gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
    adw_init();
    g_print("libadwaita %u.%u.%u\n", adw_get_major_version(), adw_get_minor_version(), adw_get_micro_version());
}

int main(int argc, char **argv) {
    g_print("config in %s\n", g_get_user_config_dir());
    g_print("settings in %s\n", G_OBJECT_TYPE_NAME(g_settings_backend_get_default()));
    GtkApplication *app = gtk_application_new("io.zigsaw.test.Hello", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
