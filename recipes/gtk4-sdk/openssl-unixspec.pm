# Loaded into every Perl that OpenSSL's build runs (PERL5OPT), so that
# Strawberry Perl, a native Windows Perl, makes the forward-slash paths
# OpenSSL's Unix makefiles (target mingw64) expect: File::Spec uses its Unix
# flavour, drive letters count as absolute, and rel2abs folds "dir/.."
# (on Unix, OpenSSL's Configure uses realpath for that).
require File::Spec; require File::Spec::Unix; @File::Spec::ISA = ('File::Spec::Unix');
no warnings 'redefine';
*File::Spec::Unix::file_name_is_absolute = sub { $_[1] =~ m{^(?:[A-Za-z]:)?/} };
my $rel2abs = \&File::Spec::Unix::rel2abs;
*File::Spec::Unix::rel2abs = sub { my $p = $rel2abs->(@_); $p =~ tr{\\}{/}; 1 while $p =~ s{(^|/)(?!\.\.(?:/|$))[^/]+/\.\.(?:/|$)}{$1}; $p };
1;
