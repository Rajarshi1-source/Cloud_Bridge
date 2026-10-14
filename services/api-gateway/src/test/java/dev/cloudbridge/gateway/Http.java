package dev.cloudbridge.gateway;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

/** Plain JDK HTTP client for tests: sees exactly what a real client sees, servlet filters included. */
final class Http {

	private static final HttpClient CLIENT = HttpClient.newHttpClient();

	private Http() {
	}

	static HttpResponse<String> send(HttpRequest.Builder request) {
		try {
			return CLIENT.send(request.build(), HttpResponse.BodyHandlers.ofString());
		}
		catch (IOException ex) {
			throw new UncheckedIOException(ex);
		}
		catch (InterruptedException ex) {
			Thread.currentThread().interrupt();
			throw new IllegalStateException(ex);
		}
	}

	static HttpRequest.Builder at(int port, String path) {
		return HttpRequest.newBuilder(URI.create("http://localhost:" + port + path));
	}

}
