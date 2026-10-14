package dev.cloudbridge.gateway;

import dev.cloudbridge.gateway.health.OrderReadinessProbe;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

import java.net.http.HttpResponse;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.BDDMockito.given;

/**
 * /healthz/cell drains the cell only when it can't take orders. No Valkey at all in this test:
 * the cache is deliberately not part of cell health. Owns its Postgres so it can stop it.
 */
@Testcontainers
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
		properties = { "cloudbridge.cell=cb-test-cell", "cloudbridge.health.cache-ttl=0s" })
@DirtiesContext
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class CellHealthIT {

	@Container
	@ServiceConnection
	static PostgreSQLContainer postgres = new PostgreSQLContainer("postgres:18.4-alpine");

	@Value("${local.server.port}")
	int port;

	@MockitoBean
	OrderReadinessProbe orderService;

	@Test
	@Order(1)
	void upWhenOrderServiceAndDatabaseAreUpEvenWithNoCache() {
		given(this.orderService.ready()).willReturn(true);
		HttpResponse<String> res = Http.send(Http.at(this.port, "/healthz/cell"));
		assertThat(res.statusCode()).isEqualTo(200);
		assertThat(res.headers().firstValue("X-CB-Cell")).hasValue("cb-test-cell");
		assertThat(res.body()).contains("\"status\":\"UP\"");
	}

	@Test
	@Order(2)
	void downWhenOrderServiceIsNotReady() {
		given(this.orderService.ready()).willReturn(false);
		HttpResponse<String> res = Http.send(Http.at(this.port, "/healthz/cell"));
		assertThat(res.statusCode()).isEqualTo(503);
		assertThat(res.body()).contains("\"orderService\":\"DOWN\"");
	}

	@Test
	@Order(3)
	void downWhenCellDatabaseIsGone() {
		given(this.orderService.ready()).willReturn(true);
		postgres.stop();
		HttpResponse<String> res = Http.send(Http.at(this.port, "/healthz/cell"));
		assertThat(res.statusCode()).isEqualTo(503);
		assertThat(res.body()).contains("\"database\":\"DOWN\"");
	}

}
