# Makes a Windows icon of an SVG, for shortcuts and file associations, which
# can't show an SVG: the SVG drawn at each size by rsvg-convert, as PNGs,
# which an .ico may hold in place of bitmaps.
#   sh svg2ico.sh <in.svg> <out.ico> [<size>...]
set -e
svg=$1
ico=$2
shift 2
[ $# -gt 0 ] || set -- 16 24 32 48 64 256

# le <number> <bytes>: the number as that many bytes, low byte first, as
# octal escapes for printf.
le() {
    n=$1
    i=0
    while [ "$i" -lt "$2" ]; do
        printf '\\%03o' $((n & 255))
        n=$((n >> 8))
        i=$((i + 1))
    done
}

# The header: reserved, type 1 (icon), the number of images. Then an entry
# for each: width and height (0 for 256), no palette, reserved, 1 plane, 32
# bits a pixel, the image's size and where it starts.
offset=$((6 + 16 * $#))
header=$(le 0 2; le 1 2; le $# 2)
for size; do
    # Through a pipe: this rsvg-convert misreads a file, named or as its
    # standard input.
    cat "$svg" | rsvg-convert -w "$size" -h "$size" -o "$ico.$size.png"
    bytes=$(wc -c < "$ico.$size.png")
    header=$header$(le "$size" 1; le "$size" 1; le 0 2; le 1 2; le 32 2; le "$bytes" 4; le "$offset" 4)
    offset=$((offset + bytes))
done
{
    printf "$header"
    for size; do cat "$ico.$size.png"; done
} > "$ico"
for size; do rm "$ico.$size.png"; done
