package dev.cloudbridge.gateway.security;

import com.sun.net.httpserver.HttpServer;
import dev.cloudbridge.gateway.GatewayTestSupport;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Who can reach the lease API: only the allowlisted service token, only on the admin host. */
@Import(GatewayTestSupport.class)
@SpringBootTest
@AutoConfigureMockMvc
class AdminChainIT {

	static final String ADMIN = "https://admin-aws.example.test";

	static final String PUBLIC = "https://app.example.test";

	static final HttpServer INVENTORY = startInventory();

	@Autowired
	MockMvc mvc;

	static HttpServer startInventory() {
		try {
			HttpServer server = HttpServer.create(new InetSocketAddress("localhost", 0), 0);
			server.createContext("/", (exchange) -> {
				byte[] out = "from-inventory".getBytes(StandardCharsets.UTF_8);
				exchange.sendResponseHeaders(200, out.length);
				exchange.getResponseBody().write(out);
				exchange.close();
			});
			server.start();
			return server;
		}
		catch (IOException ex) {
			throw new UncheckedIOException(ex);
		}
	}

	@DynamicPropertySource
	static void upstream(DynamicPropertyRegistry registry) {
		registry.add("cloudbridge.inventory-url", () -> "http://localhost:" + INVENTORY.getAddress().getPort());
	}

	@AfterAll
	static void stopInventory() {
		INVENTORY.stop(0);
	}

	private static RequestPostProcessor allocator() {
		return jwt().jwt((j) -> j.claim("common_name", "allocator-client-id"))
			.authorities(new SimpleGrantedAuthority(CfAccessJwtConfig.ROLE_LEASE_ALLOCATOR));
	}

	@Test
	void adminHostWithoutTokenIsUnauthorized() throws Exception {
		this.mvc.perform(post(ADMIN + "/admin/leases/grant").contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isUnauthorized());
		this.mvc.perform(get(ADMIN + "/admin/leases/report")).andExpect(status().isUnauthorized());
	}

	@Test
	void adminHostWithAGarbageTokenIsUnauthorized() throws Exception {
		this.mvc.perform(get(ADMIN + "/admin/leases/report").header(CfAccessJwtConfig.ACCESS_HEADER, "not.a.jwt"))
			.andExpect(status().isUnauthorized());
	}

	@Test
	void tokenNotOnTheAllowlistIsForbidden() throws Exception {
		this.mvc.perform(get(ADMIN + "/admin/leases/report").with(jwt())).andExpect(status().isForbidden());
	}

	@Test
	void allowlistedTokenReachesInventoryOnTheAdminHost() throws Exception {
		// A port in the Host header, as a client on a non-default port sends, must not change the route.
		this.mvc.perform(get(ADMIN + "/admin/leases/report").header("Host", "admin-aws.example.test:8443").with(allocator()))
			.andExpect(status().isOk())
			.andExpect(content().string("from-inventory"));
	}

	@Test
	void adminPathOnThePublicHostIsHiddenEvenWithAValidToken() throws Exception {
		this.mvc.perform(get(PUBLIC + "/admin/leases/report").with(allocator())).andExpect(status().isNotFound());
		this.mvc.perform(post(PUBLIC + "/admin/leases/grant").with(allocator())).andExpect(status().isNotFound());
	}

	@Test
	void publicRoutesDoNotExistOnTheAdminHost() throws Exception {
		this.mvc.perform(get(ADMIN + "/orders?customerId=x")).andExpect(status().isNotFound());
		this.mvc.perform(get(ADMIN + "/healthz/cell")).andExpect(status().isNotFound());
	}

}
