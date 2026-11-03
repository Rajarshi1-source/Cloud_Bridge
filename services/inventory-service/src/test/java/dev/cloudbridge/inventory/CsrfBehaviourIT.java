package dev.cloudbridge.inventory;

import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestComponent;
import org.springframework.context.annotation.Import;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * CSRF stays on for routes nobody listed, without costing anything on a stateless service: a refused
 * POST must not open a server session, and an exempt route's error must keep its real status when the
 * container re-dispatches it to /error.
 */
@Import({ TestcontainersConfiguration.class, CsrfBehaviourIT.Failing.class })
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class CsrfBehaviourIT {

	private static final HttpClient HTTP = HttpClient.newHttpClient();

	@Value("${local.server.port}")
	int port;

	HttpResponse<String> post(String path) throws Exception {
		return HTTP.send(HttpRequest.newBuilder(URI.create("http://localhost:" + this.port + path))
			.POST(HttpRequest.BodyPublishers.noBody())
			.build(), HttpResponse.BodyHandlers.ofString());
	}

	@Test
	void aPostToAnUnlistedRouteIsRefusedWithoutASession() throws Exception {
		HttpResponse<String> res = post("/not-a-route");
		assertThat(res.statusCode()).isEqualTo(404);
		assertThat(res.headers().firstValue("Set-Cookie")).isEmpty();
	}

	@Test
	void anExemptRouteKeepsItsErrorStatus() throws Exception {
		assertThat(post("/reservations/test-send-error").statusCode()).isEqualTo(507);
	}

	@TestComponent
	@RestController
	static class Failing {

		@PostMapping("/reservations/test-send-error")
		void fail(HttpServletResponse response) throws IOException {
			response.sendError(507);
		}

	}

}
