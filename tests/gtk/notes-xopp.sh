# Writes a Xournal++ document (gzipped XML) for tests/gtk.sh to stdout: $1
# pages, each with a line of text in Virgil, one of Rnote's own fonts (its
# family is "Virgil 3 YOFF"), one in Segoe UI and a pen stroke. rnote-cli
# imports it, and lays out and draws the pages on rayon's threads when it
# exports them.
pages=${1:-1}
{
    echo '<?xml version="1.0" standalone="no"?>'
    echo '<xournal creator="zigsaw tests" fileversion="4">'
    echo '<title>Xournal++ document - see https://xournalpp.github.io/</title>'
    i=1
    while [ "$i" -le "$pages" ]; do
        echo '<page width="595.27559" height="841.88976">'
        echo '<background type="solid" color="#ffffffff" style="plain"/>'
        echo '<layer>'
        echo "<text font=\"Virgil 3 YOFF\" size=\"24\" x=\"72\" y=\"72\" color=\"#000000ff\">Rnote on zigsaw, page $i</text>"
        echo "<text font=\"Segoe UI\" size=\"14\" x=\"72\" y=\"140\" color=\"#3333ccff\">Grüße, ñandú, 中文 $i</text>"
        echo '<stroke tool="pen" color="#000000ff" width="2.26">72 220 150 260 230 230 310 280 390 240</stroke>'
        echo '</layer>'
        echo '</page>'
        i=$((i + 1))
    done
    echo '</xournal>'
} | gzip -c
