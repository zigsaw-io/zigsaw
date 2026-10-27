import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

/** tests/certs.sh's Java client: prints what the URL answers, or why not. */
public class Get {
    public static void main(String[] args) {
        try {
            HttpClient client = HttpClient.newHttpClient();
            HttpResponse<String> r = client.send(HttpRequest.newBuilder(URI.create(args[0])).build(), HttpResponse.BodyHandlers.ofString());
            System.out.println(r.body().trim());
        } catch (Exception e) {
            Throwable cause = e;
            while (cause.getCause() != null) cause = cause.getCause();
            System.out.println(cause);
            System.exit(1);
        }
    }
}
