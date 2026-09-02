import com.sun.net.httpserver.HttpServer;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;

public class JavaOkServer {
    public static void main(String[] args) throws Exception {
        byte[] body = "OK".getBytes();
        HttpServer server = HttpServer.create(new InetSocketAddress(18081), 8192);
        server.setExecutor(Executors.newFixedThreadPool(200)); // Tomcat default maxThreads
        server.createContext("/ok", exchange -> {
            exchange.sendResponseHeaders(200, body.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(body);
            }
        });
        server.start();
        System.out.println("java ok-server (fixed pool 200) listening on :18081");
    }
}
