package dev.cloudbridge.gateway.health;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.time.Duration;

/** Is order-service in this cell ready (its own DB pool included)? Short timeouts: a probe must not hang. */
@Component
public class OrderReadinessProbe {

	private final RestClient http;

	public OrderReadinessProbe(@Value("${cloudbridge.order-readiness-url}") String readinessUrl) {
		SimpleClientHttpRequestFactory rf = new SimpleClientHttpRequestFactory();
		rf.setConnectTimeout(Duration.ofMillis(300));
		rf.setReadTimeout(Duration.ofMillis(500));
		this.http = RestClient.builder().baseUrl(readinessUrl).requestFactory(rf).build();
	}

	public boolean ready() {
		try {
			return this.http.get().retrieve().toBodilessEntity().getStatusCode().is2xxSuccessful();
		}
		catch (RuntimeException ex) {
			return false;
		}
	}

}
