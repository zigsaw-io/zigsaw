/* nm for builds with GTK's SDK: lists the symbols of COFF objects and of
 * archives of them (static and import libraries), as GNU nm does for
 * x86-64 Windows. zig has no nm, and these need one:
 *
 * - libtool, to turn -export-symbols-regex into a .def file and to check
 *   what its symbol pipe reads (BSD format: "value type name");
 * - gobject-introspection's scanner, which with LLVM's dlltool (zig's)
 *   finds the DLL an import library names by the archive member names
 *   nm prints ("libgtk-4-1.dll:").
 *
 * Options: -B (the default) or -P / -f bsd|posix|sysv, -g (external
 * only), -u (undefined only), -U / --defined-only, -A / -o (file name on
 * each line), -p (no sorting), -n / -v (sort by value), -r (reverse),
 * -C (accepted, names aren't mangled in C), -h, -V. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SCN_CNT_CODE 0x00000020u
#define SCN_CNT_INITIALIZED_DATA 0x00000040u
#define SCN_CNT_UNINITIALIZED_DATA 0x00000080u
#define SCN_LNK_INFO 0x00000200u
#define SCN_LNK_REMOVE 0x00000800u
#define SCN_MEM_DISCARDABLE 0x02000000u
#define SCN_MEM_WRITE 0x80000000u

#define CLASS_EXTERNAL 2
#define CLASS_STATIC 3
#define CLASS_LABEL 6
#define CLASS_FUNCTION 101
#define CLASS_FILE 103
#define CLASS_SECTION 104
#define CLASS_WEAK_EXTERNAL 105

static const char *prog = "nm";
static int opt_extern_only, opt_undefined_only, opt_defined_only;
static int opt_print_file, opt_no_sort, opt_numeric, opt_reverse;
static char opt_format = 'b'; /* b(sd), p(osix), s(ysv) */
static int status;

struct sym {
    char *name;
    uint64_t value;
    char type;
    char external;
};

struct syms {
    struct sym *v;
    size_t n, cap;
};

static void *xrealloc(void *p, size_t n) {
    p = realloc(p, n ? n : 1);
    if (!p) {
        fprintf(stderr, "%s: out of memory\n", prog);
        exit(1);
    }
    return p;
}

static char *xstrndup(const char *s, size_t n) {
    char *d = xrealloc(NULL, n + 1);
    memcpy(d, s, n);
    d[n] = 0;
    return d;
}

static void add(struct syms *s, char *name, uint64_t value, char type, int external) {
    if (s->n == s->cap) {
        s->cap = s->cap ? 2 * s->cap : 64;
        s->v = xrealloc(s->v, s->cap * sizeof *s->v);
    }
    s->v[s->n].name = name;
    s->v[s->n].value = value;
    s->v[s->n].type = type;
    s->v[s->n].external = (char)external;
    s->n++;
}

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* The bigobj header's class id, which tells it from an import object. */
static const unsigned char bigobj_class[16] = {
    0xC7, 0xA1, 0xBA, 0xD1, 0xEE, 0xBA, 0xA9, 0x4B,
    0xAF, 0x20, 0xFA, 0xF6, 0x6A, 0xA4, 0xDC, 0xB8,
};

static int cmp_name(const void *a, const void *b) {
    int c = strcmp(((const struct sym *)a)->name, ((const struct sym *)b)->name);
    return opt_reverse ? -c : c;
}

static int cmp_value(const void *a, const void *b) {
    const struct sym *x = a, *y = b;
    int c = x->value < y->value ? -1 : x->value > y->value ? 1 : strcmp(x->name, y->name);
    return opt_reverse ? -c : c;
}

static int undefined(char type) { return type == 'U' || type == 'w'; }

/* Prints what one object holds, sorted as asked. */
static void print(struct syms *s, const char *file, const char *member) {
    if (!opt_no_sort) qsort(s->v, s->n, sizeof *s->v, opt_numeric ? cmp_value : cmp_name);
    for (size_t i = 0; i < s->n; i++) {
        struct sym *y = &s->v[i];
        if (opt_undefined_only && !undefined(y->type)) continue;
        if (opt_defined_only && undefined(y->type)) continue;
        if (opt_extern_only && !y->external) continue;
        if (opt_print_file && opt_format == 'b') {
            if (member) printf("%s:%s:", file, member);
            else printf("%s:", file);
        } else if (opt_print_file) {
            if (member) printf("%s[%s]: ", file, member);
            else printf("%s: ", file);
        }
        if (opt_format == 'p') {
            if (undefined(y->type)) printf("%s %c         \n", y->name, y->type);
            else printf("%s %c %llx \n", y->name, y->type, (unsigned long long)y->value);
        } else if (opt_format == 's') {
            if (undefined(y->type)) printf("%-20s|                |   %c  |\n", y->name, y->type);
            else printf("%-20s|%016llx|   %c  |\n", y->name, (unsigned long long)y->value, y->type);
        } else {
            if (undefined(y->type)) printf("%16s %c %s\n", "", y->type, y->name);
            else printf("%016llx %c %s\n", (unsigned long long)y->value, y->type, y->name);
        }
    }
    for (size_t i = 0; i < s->n; i++) free(s->v[i].name);
    s->n = 0;
}

/* The type letter of a symbol defined in a section, as GNU nm gives it to
 * a local symbol (upper case for an external one): by the section's name
 * first, then by what it holds. */
static char section_type(uint32_t flags, const char *name) {
    static const struct { const char *prefix; char type; } by_name[] = {
        {".drectve", 'i'}, {".edata", 'e'}, {".idata", 'i'}, {".pdata", 'p'},
    };
    for (size_t i = 0; i < sizeof by_name / sizeof *by_name; i++)
        if (!strncmp(name, by_name[i].prefix, strlen(by_name[i].prefix))) return by_name[i].type;
    if (flags & SCN_CNT_CODE) return 't';
    if (!strncmp(name, ".debug", 6)) return 'N';
    if (flags & SCN_CNT_INITIALIZED_DATA) return flags & SCN_MEM_WRITE ? 'd' : 'r';
    if (flags & SCN_CNT_UNINITIALIZED_DATA) return 'b';
    if (!(flags & SCN_MEM_WRITE)) return 'n';
    return '?';
}

/* Reads a short import object (an import library's member): the name it
 * imports, as code or data. Returns 0 if it isn't one. */
static int import_object(struct syms *s, const unsigned char *p, size_t n) {
    if (n < 20 || rd16(p) != 0 || rd16(p + 2) != 0xFFFF || rd16(p + 4) != 0) return 0;
    uint32_t size = rd32(p + 12);
    if (20 + (size_t)size > n) return 0;
    const char *name = (const char *)p + 20;
    size_t len = strnlen(name, size);
    int kind = rd16(p + 18) & 3; /* 0 code, 1 data, 2 const */
    size_t imp_len = len + 6;
    char *imp = xrealloc(NULL, imp_len + 1);
    snprintf(imp, imp_len + 1, "__imp_%.*s", (int)len, name);
    add(s, imp, 0, 'I', 1);
    if (kind == 0) add(s, xstrndup(name, len), 0, 'T', 1);
    return 1;
}

/* Reads a COFF object, plain or bigobj. Returns 0 if it isn't one. */
static int coff_object(struct syms *s, const unsigned char *p, size_t n, const char *what) {
    int big = 0;
    uint32_t nsections, symoff, nsyms;
    size_t header, symsize;
    if (n >= 56 && rd16(p) == 0 && rd16(p + 2) == 0xFFFF && rd16(p + 4) >= 2 &&
        !memcmp(p + 12, bigobj_class, 16)) {
        big = 1;
        nsections = rd32(p + 44);
        symoff = rd32(p + 48);
        nsyms = rd32(p + 52);
        header = 56;
        symsize = 20;
    } else {
        if (n < 20) return 0;
        uint16_t machine = rd16(p);
        if (machine != 0x8664 && machine != 0x14c && machine != 0xAA64 && machine != 0) return 0;
        if (rd16(p + 16) != 0) return 0; /* an image's optional header */
        nsections = rd16(p + 2);
        symoff = rd32(p + 8);
        nsyms = rd32(p + 12);
        header = 20;
        symsize = 18;
    }
    if (header + (size_t)nsections * 40 > n) {
        fprintf(stderr, "%s: %s: file format not recognized\n", prog, what);
        status = 1;
        return 1;
    }
    if (nsyms == 0) {
        fprintf(stderr, "%s: %s: no symbols\n", prog, what);
        return 1;
    }
    if ((size_t)symoff + (size_t)nsyms * symsize > n) {
        fprintf(stderr, "%s: %s: file truncated\n", prog, what);
        status = 1;
        return 1;
    }
    const unsigned char *sections = p + header;
    const unsigned char *table = p + symoff;
    const char *strings = (const char *)table + (size_t)nsyms * symsize;
    size_t strsize = n - (symoff + (size_t)nsyms * symsize);
    uint32_t strtab_len = strsize >= 4 ? rd32((const unsigned char *)strings) : 0;
    if (strtab_len > strsize) strtab_len = (uint32_t)strsize;

    for (uint32_t i = 0; i < nsyms; i++) {
        const unsigned char *e = table + (size_t)i * symsize;
        char *name;
        if (rd32(e) == 0) {
            uint32_t off = rd32(e + 4);
            if (off >= strtab_len) name = xstrndup("", 0);
            else name = xstrndup(strings + off, strnlen(strings + off, strtab_len - off));
        } else {
            name = xstrndup((const char *)e, strnlen((const char *)e, 8));
        }
        uint32_t value = rd32(e + 8);
        int32_t section = big ? (int32_t)rd32(e + 12) : (int16_t)rd16(e + 12);
        unsigned char sclass = e[big ? 18 : 16];
        unsigned char naux = e[big ? 19 : 17];
        i += naux;
        char type = 0;
        if (sclass == CLASS_FILE || sclass == CLASS_FUNCTION || section == -2) {
            free(name);
            continue;
        }
        if (sclass == CLASS_WEAK_EXTERNAL) {
            type = section == 0 ? 'w' : 'W';
        } else if (section == 0) {
            if (sclass != CLASS_EXTERNAL) {
                free(name);
                continue;
            }
            type = value ? 'C' : 'U';
        } else if (sclass != CLASS_EXTERNAL && sclass != CLASS_STATIC && sclass != CLASS_LABEL &&
                   sclass != CLASS_SECTION) {
            free(name);
            continue;
        } else {
            if (section == -1) {
                type = 'a';
            } else if (section > 0 && (uint32_t)section <= nsections) {
                const unsigned char *sh = sections + (size_t)(section - 1) * 40;
                char sname[9];
                const char *sn = sname;
                memcpy(sname, sh, 8);
                sname[8] = 0;
                /* A name longer than 8 is "/<offset>" into the strings. */
                if (sname[0] == '/' && sname[1] >= '0' && sname[1] <= '9') {
                    unsigned long at = strtoul(sname + 1, NULL, 10);
                    if (at < strtab_len) sn = strings + at;
                }
                type = section_type(rd32(sh + 36), sn);
            } else {
                type = '?';
            }
            if (sclass == CLASS_EXTERNAL && type >= 'a' && type <= 'z') type = (char)(type - 'a' + 'A');
        }
        add(s, name, value, type, sclass == CLASS_EXTERNAL || sclass == CLASS_WEAK_EXTERNAL);
    }
    return 1;
}

/* One object, whatever kind; `member` names it inside an archive. */
static void object(struct syms *s, const char *file, const char *member, const unsigned char *p, size_t n) {
    char what[1024];
    if (member) snprintf(what, sizeof what, "%s(%s)", file, member);
    else snprintf(what, sizeof what, "%s", file);
    if (n >= 2 && p[0] == 'M' && p[1] == 'Z') {
        fprintf(stderr, "%s: %s: no symbols\n", prog, what);
        return;
    }
    if (import_object(s, p, n) || coff_object(s, p, n, what)) {
        print(s, file, member);
        return;
    }
    fprintf(stderr, "%s: %s: file format not recognized\n", prog, what);
    status = 1;
}

static void archive(struct syms *s, const char *file, const unsigned char *p, size_t n) {
    const char *longnames = NULL;
    size_t longnames_len = 0;
    size_t off = 8;
    while (off + 60 <= n) {
        const unsigned char *h = p + off;
        char sizebuf[11];
        memcpy(sizebuf, h + 48, 10);
        sizebuf[10] = 0;
        size_t size = (size_t)strtoull(sizebuf, NULL, 10);
        const unsigned char *data = h + 60;
        if (off + 60 + size > n) {
            fprintf(stderr, "%s: %s: malformed archive\n", prog, file);
            status = 1;
            return;
        }
        char raw[17];
        memcpy(raw, h, 16);
        raw[16] = 0;
        char *name = NULL;
        if (!strncmp(raw, "/ ", 2) || !strncmp(raw, "/SYM64/", 7) || !strncmp(raw, "/<ECSYMBOLS>/", 13)) {
            /* symbol tables */
        } else if (!strncmp(raw, "// ", 3)) {
            longnames = (const char *)data;
            longnames_len = size;
        } else if (raw[0] == '/' && raw[1] >= '0' && raw[1] <= '9') {
            size_t at = (size_t)strtoull(raw + 1, NULL, 10);
            if (longnames && at < longnames_len) {
                size_t end = at;
                while (end < longnames_len && longnames[end] != '\n' && longnames[end] != 0 &&
                       !(longnames[end] == '/' && (end + 1 == longnames_len || longnames[end + 1] == '\n')))
                    end++;
                name = xstrndup(longnames + at, end - at);
            } else {
                name = xstrndup(raw, strlen(raw));
            }
        } else {
            size_t len = 16;
            while (len && raw[len - 1] == ' ') len--;
            if (len && raw[len - 1] == '/') len--;
            name = xstrndup(raw, len);
        }
        if (name) {
            if (opt_print_file) {}
            else if (opt_format == 'b') printf("\n%s:\n", name);
            else printf("%s[%s]:\n", file, name);
            object(s, file, name, data, size);
            free(name);
        }
        off += 60 + size + (size & 1);
    }
}

static void file(struct syms *s, const char *path, int several) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "%s: '%s': No such file\n", prog, path);
        status = 1;
        return;
    }
    unsigned char *buf = NULL;
    size_t n = 0, cap = 0;
    for (;;) {
        if (n == cap) {
            cap = cap ? 2 * cap : 1 << 16;
            buf = xrealloc(buf, cap);
        }
        size_t got = fread(buf + n, 1, cap - n, f);
        if (!got) break;
        n += got;
    }
    fclose(f);
    if (n >= 8 && !memcmp(buf, "!<arch>\n", 8)) {
        archive(s, path, buf, n);
    } else if (n >= 8 && !memcmp(buf, "!<thin>\n", 8)) {
        fprintf(stderr, "%s: %s: thin archives aren't supported\n", prog, path);
        status = 1;
    } else {
        if (several && !opt_print_file) printf(opt_format == 'b' ? "\n%s:\n" : "%s:\n", path);
        object(s, path, NULL, buf, n);
    }
    free(buf);
}

static void usage(FILE *out) {
    fprintf(out,
            "Usage: %s [option(s)] [file(s)]\n"
            " List symbols in [file(s)] (a.out by default).\n"
            "  -A, -o, --print-file-name  Print the file name on each line\n"
            "  -B, --format=bsd           BSD output (the default)\n"
            "  -P, --portability, --format=posix  POSIX output\n"
            "  -f, --format=bsd|posix|sysv\n"
            "  -g, --extern-only          External symbols only\n"
            "  -u, --undefined-only       Undefined symbols only\n"
            "  -U, --defined-only         Defined symbols only\n"
            "  -n, -v, --numeric-sort     Sort by value\n"
            "  -p, --no-sort              Don't sort\n"
            "  -r, --reverse-sort         Reverse the order\n"
            "  -C, --demangle             Accepted; C names aren't mangled\n"
            "  -h, --help                 This help\n"
            "  -V, --version              The version\n",
            prog);
}

static int format(const char *f) {
    if (!strcmp(f, "bsd")) opt_format = 'b';
    else if (!strcmp(f, "posix")) opt_format = 'p';
    else if (!strcmp(f, "sysv")) opt_format = 's';
    else {
        fprintf(stderr, "%s: %s: invalid output format\n", prog, f);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    const char **files = xrealloc(NULL, (size_t)argc * sizeof *files);
    int nfiles = 0, dashdash = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (dashdash || a[0] != '-' || !a[1]) {
            files[nfiles++] = a;
        } else if (!strcmp(a, "--")) {
            dashdash = 1;
        } else if (a[1] == '-') {
            if (!strcmp(a, "--print-file-name")) opt_print_file = 1;
            else if (!strcmp(a, "--portability")) opt_format = 'p';
            else if (!strncmp(a, "--format=", 9)) { if (!format(a + 9)) return 1; }
            else if (!strcmp(a, "--format") && i + 1 < argc) { if (!format(argv[++i])) return 1; }
            else if (!strcmp(a, "--extern-only")) opt_extern_only = 1;
            else if (!strcmp(a, "--undefined-only")) opt_undefined_only = 1;
            else if (!strcmp(a, "--defined-only")) opt_defined_only = 1;
            else if (!strcmp(a, "--numeric-sort")) opt_numeric = 1;
            else if (!strcmp(a, "--no-sort")) opt_no_sort = 1;
            else if (!strcmp(a, "--reverse-sort")) opt_reverse = 1;
            else if (!strcmp(a, "--demangle") || !strncmp(a, "--demangle=", 11) || !strcmp(a, "--no-demangle")) {}
            else if (!strcmp(a, "--help")) { usage(stdout); return 0; }
            else if (!strcmp(a, "--version")) { puts("nm (zigsaw GTK SDK) 1.0"); return 0; }
            else {
                fprintf(stderr, "%s: unrecognized option '%s'\n", prog, a);
                usage(stderr);
                return 1;
            }
        } else {
            for (const char *c = a + 1; *c; c++) {
                switch (*c) {
                case 'A': case 'o': opt_print_file = 1; break;
                case 'B': opt_format = 'b'; break;
                case 'P': opt_format = 'p'; break;
                case 'f':
                    if (c[1]) { if (!format(c + 1)) return 1; }
                    else if (i + 1 < argc) { if (!format(argv[++i])) return 1; }
                    else { usage(stderr); return 1; }
                    c += strlen(c) - 1;
                    break;
                case 'g': opt_extern_only = 1; break;
                case 'u': opt_undefined_only = 1; break;
                case 'U': opt_defined_only = 1; break;
                case 'n': case 'v': opt_numeric = 1; break;
                case 'p': opt_no_sort = 1; break;
                case 'r': opt_reverse = 1; break;
                case 'C': case 'D': break;
                case 'h': usage(stdout); return 0;
                case 'V': puts("nm (zigsaw GTK SDK) 1.0"); return 0;
                default:
                    fprintf(stderr, "%s: invalid option -- '%c'\n", prog, *c);
                    usage(stderr);
                    return 1;
                }
            }
        }
    }
    if (!nfiles) files[nfiles++] = "a.out";
    struct syms s = {0};
    for (int i = 0; i < nfiles; i++) file(&s, files[i], nfiles > 1);
    free(s.v);
    free(files);
    return status;
}
