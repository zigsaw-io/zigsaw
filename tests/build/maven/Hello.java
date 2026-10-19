import org.apache.commons.lang3.StringUtils;

public class Hello {
    public static void main(String[] args) {
        String name = args.length > 0 ? args[0] : "world";
        System.out.println("hello, " + name + ", from Java " + System.getProperty("java.version"));
        System.out.println(StringUtils.capitalize("built with a vendored package"));
        System.out.println("runs on " + System.getProperty("java.home"));
        System.out.println("home is " + System.getProperty("user.home"));
    }
}
