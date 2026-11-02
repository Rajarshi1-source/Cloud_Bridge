package dev.cloudbridge.gateway.security;

import org.junit.jupiter.api.Test;

import org.springframework.security.oauth2.jwt.Jwt;

import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class CfAccessJwtConfigTest {

	static final String TEAM = "https://team.cloudflareaccess.com";

	static final AdminProperties PROPS = new AdminProperties("admin-aws.example.test", URI.create(TEAM), "aud-aws",
			Set.of("allocator-client-id"), Duration.ofSeconds(30));

	static Jwt jwt(String aud, String issuer, String commonName, Instant expires) {
		return Jwt.withTokenValue("t")
			.header("alg", "RS256")
			.issuer(issuer)
			.audience(List.of(aud))
			.claim("common_name", commonName)
			.issuedAt(expires.minusSeconds(600))
			.expiresAt(expires)
			.build();
	}

	static Jwt jwt(String aud, String issuer, String commonName) {
		return jwt(aud, issuer, commonName, Instant.now().plusSeconds(300));
	}

	@Test
	void acceptsCorrectIssuerAndAudience() {
		assertThat(CfAccessJwtConfig.validator(PROPS).validate(jwt("aud-aws", TEAM, "allocator-client-id")).hasErrors())
			.isFalse();
	}

	@Test
	void rejectsOtherCellsAudience() {
		assertThat(CfAccessJwtConfig.validator(PROPS).validate(jwt("aud-gcp", TEAM, "allocator-client-id")).hasErrors())
			.isTrue();
	}

	@Test
	void rejectsForeignTeam() {
		assertThat(CfAccessJwtConfig.validator(PROPS)
			.validate(jwt("aud-aws", "https://attacker.cloudflareaccess.com", "allocator-client-id"))
			.hasErrors()).isTrue();
	}

	@Test
	void rejectsExpiredToken() {
		assertThat(CfAccessJwtConfig.validator(PROPS)
			.validate(jwt("aud-aws", TEAM, "allocator-client-id", Instant.now().minusSeconds(120)))
			.hasErrors()).isTrue();
	}

	@Test
	void onlyAllowlistedServiceTokenGetsTheRole() {
		var conv = CfAccessJwtConfig.serviceTokenAuthorities(PROPS);
		assertThat(conv.convert(jwt("aud-aws", TEAM, "allocator-client-id"))).extracting(Object::toString)
			.containsExactly(CfAccessJwtConfig.ROLE_LEASE_ALLOCATOR);
		assertThat(conv.convert(jwt("aud-aws", TEAM, "someone-else"))).isEmpty();
	}

}
