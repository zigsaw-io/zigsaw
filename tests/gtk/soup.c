/* libsoup for tests/gtk.sh: says which TLS backend GIO loaded and what the
 * Public Suffix List makes of a host, then GETs each URL it's given and says
 * what came back: the status and HTTP version, or the error. */
#include <libsoup/soup.h>

static const char *http_version(SoupHTTPVersion v) {
    switch (v) {
    case SOUP_HTTP_1_0: return "HTTP/1.0";
    case SOUP_HTTP_1_1: return "HTTP/1.1";
    case SOUP_HTTP_2_0: return "HTTP/2";
    default: return "HTTP/?";
    }
}

int main(int argc, char **argv) {
    g_print("libsoup %u.%u.%u\n", soup_get_major_version(), soup_get_minor_version(), soup_get_micro_version());
    g_print("tls backend %s\n", G_OBJECT_TYPE_NAME(g_tls_backend_get_default()));
    g_print("base domain of www.example.co.uk is %s\n", soup_tld_get_base_domain("www.example.co.uk", NULL));
    SoupSession *session = soup_session_new();
    int failed = 0;
    for (int i = 1; i < argc; i++) {
        SoupMessage *msg = soup_message_new("GET", argv[i]);
        GError *error = NULL;
        GBytes *body = soup_session_send_and_read(session, msg, NULL, &error);
        if (body) {
            g_print("GET %s: %u over %s\n", argv[i], soup_message_get_status(msg), http_version(soup_message_get_http_version(msg)));
            g_bytes_unref(body);
        } else {
            g_print("GET %s: error: %s\n", argv[i], error->message);
            g_error_free(error);
            failed = 1;
        }
        g_object_unref(msg);
    }
    g_object_unref(session);
    return failed;
}
