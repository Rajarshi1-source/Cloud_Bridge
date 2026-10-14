package dev.cloudbridge.gateway;

import dev.cloudbridge.gateway.health.OrderReadinessProbe;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import java.net.http.HttpResponse;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.BDDMockito.given;

/** An overloaded cell sheds with 503 + Retry-After but stays in the Cloudflare pool. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
		properties = { "cloudbridge.shedding.max-in-flight=0", "cloudbridge.health.cache-ttl=0s" })
class LoadSheddingIT {

	@Value("${local.server.port}")
	int port;

	@MockitoBean
	OrderReadinessProbe orderService;

	@Test
	void shedsTrafficButKeepsCellHealthGreen() {
		HttpResponse<String> shed = Http.send(Http.at(this.port, "/inventory/SKU-1"));
		assertThat(shed.statusCode()).isEqualTo(503);
		assertThat(shed.headers().firstValue("Retry-After")).hasValue("2");
		assertThat(shed.body()).contains("/problems/overloaded");

		given(this.orderService.ready()).willReturn(true);
		assertThat(Http.send(Http.at(this.port, "/healthz/cell")).statusCode()).isEqualTo(200);
	}

}
