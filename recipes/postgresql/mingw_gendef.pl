# mingw_gendef.pl <nm> <deffile> <library>...: writes the .def file that
# exports everything the backend's libraries define, for postgres.exe, so
# that extensions (and PL/pgSQL, PL/Perl, PL/Python, contrib) link against
# its import library. This is what msvc_gendef.pl does for MSVC, with nm in
# place of dumpbin: zig's linker has no --export-all-symbols, which a MinGW
# build otherwise uses. nm is the GTK SDK's (recipes/gtk4-sdk/nm.c), whose
# BSD format is "value type name"; T is code, and B, C, D, R and S data,
# exported as DATA (-g leaves out the lower case, static ones).
#
# Meson makes the libraries thin archives, which name their objects rather
# than hold them, and that nm reads only whole ones: the objects are listed
# from each archive's names, then given to nm a batch at a time, as there
# are too many for one command line.

use strict;
use warnings FATAL => 'all';
use File::Basename qw(dirname);

my ($nm, $deffile, @libs) = @ARGV;
die "usage: mingw_gendef.pl <nm> <deffile> <library>...\n" unless @libs;

# The objects a library holds or names.
sub members
{
	my ($lib) = @_;
	open(my $f, '<:raw', $lib) or die "can't read $lib: $!\n";
	local $/;
	my $data = <$f>;
	close($f);
	return ($lib) unless substr($data, 0, 8) eq "!<thin>\n";

	my ($pos, $names, @objects) = (8, '');
	while ($pos + 60 <= length($data))
	{
		my $name = substr($data, $pos, 16) =~ s/ +$//r;
		my $size = substr($data, $pos + 48, 10) + 0;
		$pos += 60;
		if ($name eq '/' || $name eq '/SYM64/')
		{
			$pos += $size + ($size & 1);
		}
		elsif ($name eq '//')
		{
			$names = substr($data, $pos, $size);
			$pos += $size + ($size & 1);
		}
		else
		{
			# A thin archive's members have no data, only names: short ones
			# end in "/", long ones are "/<offset>" in the names table.
			if ($name =~ m{^/(\d+)$})
			{
				$name = substr($names, $1);
				$name =~ s{/\n.*}{}s;
			}
			else
			{
				$name =~ s{/$}{};
			}
			push @objects, $name =~ m{^([A-Za-z]:)?[/\\]} ? $name : dirname($lib) . "/$name";
		}
	}
	return @objects;
}

my @objects = map { members($_) } @libs;
my %def;
while (my @batch = splice(@objects, 0, 100))
{
	open(my $in, '-|', $nm, '-g', '--defined-only', @batch) or die "can't run $nm: $!\n";
	while (<$in>)
	{
		my ($value, $type, $name) = split;
		next unless defined $name;
		# Constants and auto-import stubs the compiler makes, and imports.
		next if $name =~ /^(\.|__imp_|__real|__xmm|_head_|__dyn_tls)/;
		if ($type eq 'T')
		{
			$def{$name} = '';
		}
		elsif ($type =~ /^[BCDRS]$/)
		{
			$def{$name} = ' DATA';
		}
	}
	close($in) or die "$nm failed\n";
}

open(my $out, '>', $deffile) or die "can't write $deffile: $!\n";
print $out "EXPORTS\n";
print $out "  $_$def{$_}\n" foreach sort keys %def;
close($out) or die "can't write $deffile: $!\n";
