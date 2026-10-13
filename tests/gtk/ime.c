/* A GTK app for tests/gtk.sh: a text view that goes away while it has the
 * keyboard focus, as a page of Text Editor does when a file opens in its
 * place. GTK's input method for Windows (gtkimcontextime.c) listens to the
 * window's messages for the view that has the focus; GTK 4.24.1 kept it
 * listening for a view that was gone, and the next message read freed
 * memory. Says "still here" if it lives through that. */
#include <gtk/gtk.h>
#include <string.h>

static GtkWidget *box, *view;

static gboolean quit(gpointer app) {
    g_print("still here\n");
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}

static gboolean remove_view(gpointer app) {
    g_print("the view has the focus: %s\n", gtk_widget_has_focus(view) ? "yes" : "no");
    gtk_box_remove(GTK_BOX(box), view);
    /* What the view's memory is reused for isn't a GObject. */
    for (gsize size = 16; size <= 1024; size += 16) {
        gpointer blocks[64];
        for (int i = 0; i < 64; i++) blocks[i] = memset(g_malloc(size), 0x41, size);
        for (int i = 0; i < 64; i++) g_free(blocks[i]);
    }
    /* Another view takes the focus, and the window gets messages. */
    GtkWidget *next = gtk_text_view_new();
    gtk_box_append(GTK_BOX(box), next);
    gtk_widget_grab_focus(next);
    g_timeout_add(1000, quit, app);
    return G_SOURCE_REMOVE;
}

static gboolean focus_view(gpointer app) {
    gtk_widget_grab_focus(view);
    g_timeout_add(500, remove_view, app);
    return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *app, gpointer data) {
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "zigsaw");
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 200);
    box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    view = gtk_text_view_new();
    gtk_box_append(GTK_BOX(box), view);
    gtk_window_set_child(GTK_WINDOW(window), box);
    gtk_window_present(GTK_WINDOW(window));
    g_timeout_add(500, focus_view, app);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("io.zigsaw.test.Ime", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
