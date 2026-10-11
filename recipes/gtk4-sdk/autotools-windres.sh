# $RC for libtool: GNU windres's command line, for zig's rc. libtool
# passes `-i <in> --output-format=coff -o <out>`; zig's rc takes the input
# and output as plain arguments, and its other options (-D, -I) as windres's.
# windres hands -D to its preprocessor through a shell, which makes
# -DV=\"1.0\" a string; zig's rc would keep the backslashes.
for a do
  shift
  case $a in
  -i | -o | --output-format=coff) continue ;;
  -D*) a=$(printf '%s\n' "$a" | sed 's/\\"/"/g') ;;
  esac
  set -- "$@" "$a"
done
exec zig rc /:auto-includes gnu /:output-format coff "$@"
