package dev.cloudbridge.inventory.lease;

import dev.cloudbridge.inventory.LeaseTestSupport;
import org.hamcrest.Matchers;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

import java.time.OffsetDateTime;
import java.util.UUID;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** The grant endpoint from a caller's point of view: inventory re-checks the JWT even behind the gateway. */
@Import(LeaseTestSupport.class)
@SpringBootTest
@AutoConfigureMockMvc
class LeaseApiIT {

	@Autowired
	MockMvc mvc;

	@Autowired
	JdbcClient jdbc;

	String sku;

	@BeforeEach
	void product() {
		this.sku = "SKU-" + UUID.randomUUID();
		this.jdbc.sql("INSERT INTO inventory.products (sku, name, price_paise) VALUES (:s, 'W', 1)")
			.param("s", this.sku)
			.update();
	}

	private MockHttpServletRequestBuilder grant(long epoch, OffsetDateTime expires) {
		return post("/admin/leases/grant").contentType(MediaType.APPLICATION_JSON).content("""
				{"sku":"%s","remainingQty":10,"reportedSold":0,"epoch":%d,"expiresAt":"%s"}"""
			.formatted(this.sku, epoch, expires));
	}

	private static RequestPostProcessor allocator() {
		return jwt().jwt((j) -> j.claim("common_name", "allocator-client-id"))
			.authorities(new SimpleGrantedAuthority("ROLE_LEASE_ALLOCATOR"));
	}

	@Test
	void forgedGrantWithoutATokenIsUnauthorized() throws Exception {
		this.mvc.perform(grant(1, OffsetDateTime.now().plusMinutes(15))).andExpect(status().isUnauthorized());
	}

	@Test
	void garbageTokenIsUnauthorized() throws Exception {
		this.mvc.perform(grant(1, OffsetDateTime.now().plusMinutes(15)).header("Cf-Access-Jwt-Assertion", "not.a.jwt"))
			.andExpect(status().isUnauthorized());
	}

	@Test
	void tokenWithoutTheRoleIsForbidden() throws Exception {
		this.mvc.perform(grant(1, OffsetDateTime.now().plusMinutes(15)).with(jwt()))
			.andExpect(status().isForbidden());
	}

	@Test
	void allocatorGrantsThenSeesItInTheReport() throws Exception {
		this.mvc.perform(grant(1, OffsetDateTime.now().plusMinutes(15)).with(allocator()))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.epoch").value(1))
			.andExpect(jsonPath("$.grantedQty").value(10))
			.andExpect(jsonPath("$.replayed").value(false));
		this.mvc.perform(get("/admin/leases/report").with(allocator()))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$[?(@.sku == '%s')].grantedQty".formatted(this.sku)).value(10))
			.andExpect(jsonPath("$[?(@.sku == '%s')].leaseEpoch".formatted(this.sku)).value(1));
	}

	@Test
	void staleEpochIs409AndOutOfBoundsIs422() throws Exception {
		OffsetDateTime ok = OffsetDateTime.now().plusMinutes(15);
		this.mvc.perform(grant(5, ok).with(allocator())).andExpect(status().isOk());
		this.mvc.perform(grant(4, ok).with(allocator()))
			.andExpect(status().isConflict())
			.andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON))
			.andExpect(jsonPath("$.type").value(Matchers.endsWith("/stale-lease-epoch")));
		this.mvc.perform(grant(6, OffsetDateTime.now().plusHours(2)).with(allocator()))
			.andExpect(status().isUnprocessableContent())
			.andExpect(jsonPath("$.rule").value("ttl"));
	}

	@Test
	void anythingElseUnderAdminIsDenied() throws Exception {
		this.mvc.perform(delete("/admin/leases/report").with(allocator())).andExpect(status().isForbidden());
	}

	@Test
	void unknownInternalPathIsHidden() throws Exception {
		this.mvc.perform(get("/nope")).andExpect(status().isNotFound());
	}

}
