# Makes a Windows icon of PNGs an app has at several sizes, as svg2ico.sh
# does of an SVG: an .ico may hold PNGs in place of bitmaps.
#   sh png2ico.sh <out.ico> <size>:<in.png>...
set -e
ico=$1
shift

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
for arg; do
    size=${arg%%:*}
    png=${arg#*:}
    bytes=$(wc -c < "$png")
    header=$header$(le "$size" 1; le "$size" 1; le 0 2; le 1 2; le 32 2; le "$bytes" 4; le "$offset" 4)
    offset=$((offset + bytes))
done
{
    printf "$header"
    for arg; do cat "${arg#*:}"; done
} > "$ico"
