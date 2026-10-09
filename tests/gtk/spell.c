/* Spell checking for tests/gtk.sh: which enchant providers load, what each
 * says about a word in a language, and which one enchant picks by itself. */
#include <enchant.h>
#include <stdio.h>

static void describe(const char *name, const char *desc, const char *file, void *data) {
    (void)desc, (void)file, (void)data;
    printf("provider %s\n", name);
}

static void dict_provider(const char *tag, const char *name, const char *desc, const char *file, void *data) {
    (void)desc, (void)file, (void)data;
    printf("default %s: %s\n", tag, name);
}

/* With only `provider`, checks "the" and "teh" and asks for suggestions. */
static void check(EnchantBroker *b, const char *provider, const char *tag) {
    enchant_broker_set_ordering(b, tag, provider);
    EnchantDict *d = enchant_broker_request_dict(b, tag);
    if (!d) {
        printf("%s %s: no dictionary\n", provider, tag);
        return;
    }
    size_t n = 0;
    char **s = enchant_dict_suggest(d, "teh", -1, &n);
    printf("%s %s: the %s, teh %s, suggests %s\n", provider, tag,
           enchant_dict_check(d, "the", -1) == 0 ? "ok" : "misspelled",
           enchant_dict_check(d, "teh", -1) == 0 ? "ok" : "misspelled",
           n > 0 ? s[0] : "nothing");
    if (s) enchant_dict_free_string_list(d, s);
    enchant_broker_free_dict(b, d);
}

int main(int argc, char **argv) {
    const char *tag = argc > 1 ? argv[1] : "en_US";
    EnchantBroker *b = enchant_broker_init();
    enchant_broker_describe(b, describe, NULL);
    EnchantDict *d = enchant_broker_request_dict(b, tag);
    if (d) {
        enchant_dict_describe(d, dict_provider, NULL);
        enchant_broker_free_dict(b, d);
    }
    check(b, "hunspell", tag);
    check(b, "winspell", tag);
    enchant_broker_free(b);
    return 0;
}
