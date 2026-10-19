import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;

// gradle-vendor <gradle user home> <dir>: makes <dir> a Maven repository of
// everything a build downloaded into <gradle user home>, which a recipe's
// vendor step pins, and its build reads through ZIGSAW_GRADLE_REPO
// (zigsaw-offline.gradle). Gradle keeps each download as
// caches/modules-2/files-2.1/<group>/<module>/<version>/<sha1>/<file>, and
// its other records there change from run to run, so only these are kept, as
// <group, dots as directories>/<module>/<version>/<file>.
public class GradleVendor {
    public static void main(String[] args) throws IOException {
        if (args.length != 2) {
            System.err.println("usage: gradle-vendor <gradle user home> <dir>");
            System.exit(2);
        }
        Path files = Path.of(args[0], "caches", "modules-2", "files-2.1");
        Path out = Path.of(args[1]);
        if (!Files.isDirectory(files)) {
            System.err.println("gradle-vendor: " + files + " doesn't exist: did the build download anything?");
            System.exit(1);
        }
        SortedMap<Path, Path> copies = new TreeMap<>();
        List<String> clashes = new ArrayList<>();
        try (Stream<Path> walk = Files.walk(files)) {
            for (Path f : (Iterable<Path>) walk.filter(Files::isRegularFile).sorted()::iterator) {
                Path rel = files.relativize(f);
                if (rel.getNameCount() != 5) continue;
                String group = rel.getName(0).toString();
                Path to = out.resolve(Path.of(group.replace('.', '/'), rel.getName(1).toString(),
                        rel.getName(2).toString(), rel.getName(4).toString()));
                Path before = copies.putIfAbsent(to, f);
                if (before != null && Files.mismatch(before, f) != -1) clashes.add(out.relativize(to).toString());
            }
        }
        if (!clashes.isEmpty()) {
            System.err.println("gradle-vendor: different files of the same name: " + String.join(", ", clashes));
            System.exit(1);
        }
        for (Map.Entry<Path, Path> c : copies.entrySet()) {
            Files.createDirectories(c.getKey().getParent());
            Files.copy(c.getValue(), c.getKey(), StandardCopyOption.REPLACE_EXISTING);
        }
        System.out.println("gradle-vendor: " + copies.size() + " files in " + out);
    }
}
