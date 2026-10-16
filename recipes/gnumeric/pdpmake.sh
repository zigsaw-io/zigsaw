# Rewrites what BusyBox's make (pdpmake) can't read in goffice's and
# Gnumeric's Makefile.in files, before configure:
# - intltool's rules for translated files, GNU make pattern rules on one
#   line (%.xml: %.xml.in ... ; recipe, with $(wildcard)), become a POSIX
#   suffix rule: <name> from <name>.in, through intltool-merge as XML. The
#   .desktop and .schemas rules go: Gnumeric makes its .desktop file with a
#   rule of its own, and its GSettings schemas aren't built (goffice keeps
#   settings in a key file).
# - intltool's po/Makefile.in.in sets the languages and catalogs with
#   $(shell ...), which pdpmake expands to nothing, so no translation was
#   built or installed; they become POSIX's VAR != command.
# - goffice's pattern rule for its versioned .pc file becomes a plain rule.
# - $< in a rule that isn't an inference rule is the first prerequisite to
#   GNU make, and to pdpmake one that's out of date, which can be Makefile:
#   Gnumeric's rules that have Makefile among their prerequisites, and the
#   one for its resource script, name their source instead.
#   sh pdpmake.sh  (in goffice's or Gnumeric's source tree)
set -e
printf '%s\n' '.SUFFIXES: .in' '.in:' \
    '	LC_ALL=C $(INTLTOOL_MERGE) -x -u -c $(top_builddir)/po/.intltool-merge-cache $(top_srcdir)/po $< $@' > zigsaw-xml-rule.mk
find . -name Makefile.in | while read -r f; do
    grep -q '^@INTLTOOL_[A-Z]*_RULE@$' "$f" || continue
    sed -i -e '/^@INTLTOOL_XML_RULE@$/{r zigsaw-xml-rule.mk' -e 'd}' \
        -e '/^@INTLTOOL_DESKTOP_RULE@$/d' -e '/^@INTLTOOL_SCHEMAS_RULE@$/d' "$f"
done
rm zigsaw-xml-rule.mk
! find . -name Makefile.in -exec grep -l '^@INTLTOOL_[A-Z]*_RULE@$' {} + | grep -q .

for f in po*/Makefile.in.in; do
    sed -i 's/^\([A-Z_]*\)=$(shell \(.*\))$/\1 != \2/' "$f"
    grep -q '^CATALOGS != ' "$f" && ! grep -q '$(shell' "$f"
done

if [ -d goffice ]; then
    sed -i 's/^%-@GOFFICE_API_VER@.pc: %.pc$/libgoffice-@GOFFICE_API_VER@.pc: libgoffice.pc/' Makefile.in
    grep -q '^libgoffice-@GOFFICE_API_VER@.pc: libgoffice.pc$' Makefile.in
fi

if [ -f src/gnumeric.rc ]; then
    for n in org.gnumeric.gnumeric.appdata.xml org.gnumeric.gnumeric.desktop; do
        sed -i "/^$n:/,/^[^	]/ s|\$<|\$(srcdir)/$n.in|" Makefile.in
        sed -n "/^$n:/,/^[^	]/p" Makefile.in | grep -q "(srcdir)/$n.in \$@.tmp"
    done
    sed -i 's|(GLIB_COMPILE_RESOURCES) \$< |(GLIB_COMPILE_RESOURCES) $(srcdir)/gnm.gresource.xml |' src/Makefile.in
    [ "$(grep -c 'COMPILE_RESOURCES) $(srcdir)/gnm.gresource.xml ' src/Makefile.in)" = 2 ]
    sed -i 's| -i \$< -o \$@$| -i $(srcdir)/gnumeric.rc -o $@|' src/Makefile.in
    grep -q ' -i $(srcdir)/gnumeric.rc -o \$@$' src/Makefile.in
fi
