#!/usr/bin/env bash
# GDAL end to end (recipes/gdal.json: GDAL's tools, built with zig on its
# SDK's GEOS, PROJ, SQLite, json-c and expat, with its internal TIFF, PNG and
# JPEG), from a work directory the app may use (its cwd permission): the
# versions, PROJ's proj.db through PROJ_DATA (an SRS, a point transformed),
# a GeoTIFF made, read with statistics, warped to Web Mercator and turned
# into a PNG, GeoJSON into a GeoPackage (SQLite, with its R-tree) and KML
# (expat), clipped (GEOS), and the `gdal` command's subcommands; under soft,
# at low integrity and in an AppContainer. Nothing is written in the store's
# deployments.
#
#   GDAL_HOME=path\to\store bash tests/gdal.sh [path\to\zigsaw.exe]
#
# Building GDAL's SDK takes a while, so this uses a store that has the app
# (GDAL_HOME, or BUILD_HOME as tests/published.sh leaves it), and says so and
# stops if neither has.

set -u
export MSYS_NO_PATHCONV=1

root=$(cygpath -w "$(cd "$(dirname "$0")/.." && pwd)")
zigsaw=${1:-$root/zig-out/bin/zigsaw.exe}
ZIGSAW_HOME=${GDAL_HOME:-${BUILD_HOME:-}}
APP=org.gdal.GDAL
if [ -z "$ZIGSAW_HOME" ] || [ ! -f "$ZIGSAW_HOME\\refs\\$APP.json" ]; then
    echo "tests/gdal.sh needs a store with $APP in GDAL_HOME or BUILD_HOME;"
    echo "build recipes\\gdal-sdk.json and recipes\\gdal.json into one first."
    exit 1
fi
export ZIGSAW_HOME
work=$(cygpath -w "$(mktemp -d)")

failures=0
check() {
    local label=$1
    shift
    local out
    if out=$("$@" 2>&1); then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n      %s\n' "$label" "$(grep -v '^\s*$' <<<"$out" | tail -1 | cut -c1-110)"
        failures=$((failures + 1))
    fi
}

# g <command> [args...]: one of the app's commands, run from the work
# directory, in $SANDBOX if set.
g() {
    local command=$1
    shift
    timeout 120 "$zigsaw" run ${SANDBOX:+--sandbox=$SANDBOX} --command="$command" $APP "$@" | tr -d '\r'
}
# has <pattern> <command> [args...]: the command's output has a line matching.
has() {
    local pattern=$1 out
    shift
    out=$(g "$@" 2>&1) && grep -q -- "$pattern" <<<"$out" || { echo "$out" | tail -3; return 1; }
}

cd "$work" || exit 1
touch "$work\\start"
printf '%s\n' '{"type":"FeatureCollection","features":[' \
    '{"type":"Feature","properties":{"name":"a"},"geometry":{"type":"Point","coordinates":[0.5,0.5]}},' \
    '{"type":"Feature","properties":{"name":"b"},"geometry":{"type":"Point","coordinates":[5,5]}}]}' >points.geojson

versions() { has '^GDAL 3.13.3 ' gdalinfo --version && has '^GDAL 3.13.3 ' gdal --version; }
transform() { [ "$(echo 20 10 | g gdaltransform -s_srs EPSG:4326 -t_srs EPSG:3857 -output_xy | cut -c1-26)" = "2226389.81586547 1118889.9" ]; }
raster() {
    rm -f r.tif w.tif r.png
    g gdal_create -q -of GTiff -outsize 20 10 -bands 1 -burn 7 -a_srs EPSG:4326 -a_ullr 0 10 20 0 r.tif &&
        has 'STATISTICS_MEAN=7' gdalinfo -stats r.tif && has 'Size is 20, 10' gdalinfo r.tif
}
warp() { g gdalwarp -q -t_srs EPSG:3857 r.tif w.tif && has 'ID\["EPSG",3857\]' gdalinfo w.tif; }
png() { g gdal_translate -q -of PNG r.tif r.png && [ "$(head -c 4 r.png | tail -c 3)" = PNG ]; }
gpkg() {
    rm -f points.gpkg
    g ogr2ogr -f GPKG points.gpkg points.geojson && has 'Feature Count: 2' ogrinfo -so -al points.gpkg &&
        has 'rtree_points_geom' ogrinfo points.gpkg -sql "select name from sqlite_master where name like 'rtree%'"
}
kml() { rm -f points.kml; g ogr2ogr -f KML points.kml points.geojson && has 'Feature Count: 2' ogrinfo -so -al points.kml; }
clip() { rm -f clip.geojson; g ogr2ogr -clipsrc 0 0 1 1 clip.geojson points.geojson && has 'Feature Count: 1' ogrinfo -so -al clip.geojson; }

for SANDBOX in soft low appcontainer; do
    [ $SANDBOX = soft ] && label= || label="$SANDBOX: "
    check "${label}gdalinfo and gdal are GDAL 3.13.3" versions
    check "${label}PROJ's proj.db names EPSG:3857" has 'Pseudo-Mercator' gdalsrsinfo -o wkt2 EPSG:3857
    check "${label}gdaltransform takes a point to Web Mercator" transform
    check "${label}a GeoTIFF made and read with statistics" raster
    check "${label}gdalwarp reprojects it" warp
    check "${label}gdal_translate makes a PNG of it" png
    check "${label}ogr2ogr makes a GeoPackage, with its R-tree" gpkg
    check "${label}and KML, read back with expat" kml
    check "${label}ogr2ogr clips with GEOS" clip
    check "${label}gdal raster info" has '"size":\[' gdal raster info --format=json r.tif
done
unset SANDBOX

written() {
    local new
    new=$(find "$(cygpath -u "$ZIGSAW_HOME")"/deploy/*/ -newer "$work\\start" -type f -print 2>/dev/null | head -3)
    [ -z "$new" ] || { echo "written: $new"; return 1; }
}
check "nothing was written in the store's deployments" written

check "no run labelled or granted the repository" sh -c "! icacls '$root' | grep -q -e 'Mandatory Label' -e 'S-1-15-'"

cd "$root" || exit 1
rm -rf "$work"
echo
echo "$failures check(s) failed."
exit $((failures > 0))
