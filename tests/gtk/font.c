/* Fonts for tests/gtk.sh: adds a font file to Pango's font map, as
 * GtkSourceView does with its own, which warned while HarfBuzz lacked
 * DirectWrite, and draws text in it with pangocairo. */
#include <pango/pangocairo.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: font-file <font file> <family>\n");
        return 2;
    }
    PangoFontMap *map = pango_cairo_font_map_get_default();
    GError *error = NULL;
    if (!pango_font_map_add_font_file(map, argv[1], &error)) {
        printf("adding %s: %s\n", argv[1], error->message);
        return 1;
    }
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 400, 80);
    cairo_t *cr = cairo_create(surface);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string(argv[2]);
    pango_font_description_set_absolute_size(font, 24 * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, "Hello, zigsaw", -1);
    pango_cairo_show_layout(cr, layout);
    PangoRectangle ink;
    pango_layout_get_pixel_extents(layout, &ink, NULL);
    printf("drew %dx%d with %s\n", ink.width, ink.height, argv[2]);
    pango_font_description_free(font);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return ink.width > 0 ? 0 : 1;
}
