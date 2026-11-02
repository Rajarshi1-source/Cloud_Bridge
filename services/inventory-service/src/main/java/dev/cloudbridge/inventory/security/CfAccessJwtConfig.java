package dev.cloudbridge.inventory.security;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtClaimNames;
import org.springframework.security.oauth2.jwt.JwtClaimValidator;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtIssuerValidator;
import org.springframework.security.oauth2.jwt.JwtTimestampValidator;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.web.BearerTokenResolver;

import java.util.Collection;
import java.util.List;

/** Validates the Cloudflare Access JWT at the origin. One identical copy in gateway and inventory-service. */
@Configuration(proxyBeanMethods = false)
public class CfAccessJwtConfig {

	public static final String ACCESS_HEADER = "Cf-Access-Jwt-Assertion";

	public static final String ROLE_LEASE_ALLOCATOR = "ROLE_LEASE_ALLOCATOR";

	/** Cloudflare puts the Access JWT in its own header, not in Authorization: Bearer. */
	@Bean
	BearerTokenResolver cfAccessTokenResolver() {
		return (request) -> request.getHeader(ACCESS_HEADER);
	}

	@Bean
	JwtDecoder cfAccessJwtDecoder(AdminProperties props) {
		NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(props.jwksUri()).build();
		decoder.setJwtValidator(validator(props));
		return decoder;
	}

	/** Package-visible so tests can exercise the exact production validator. */
	static OAuth2TokenValidator<Jwt> validator(AdminProperties props) {
		return new DelegatingOAuth2TokenValidator<>(new JwtTimestampValidator(props.clockSkew()),
				new JwtIssuerValidator(props.issuer()), new JwtClaimValidator<List<String>>(JwtClaimNames.AUD,
						(aud) -> aud != null && aud.contains(props.audience())));
	}

	/** Service token Client ID (claim common_name) → ROLE_LEASE_ALLOCATOR if allowlisted, else no authority. */
	static Converter<Jwt, Collection<GrantedAuthority>> serviceTokenAuthorities(AdminProperties props) {
		return (jwt) -> {
			String clientId = jwt.getClaimAsString("common_name");
			return (clientId != null && props.allowedServiceTokens().contains(clientId))
					? List.of(new SimpleGrantedAuthority(ROLE_LEASE_ALLOCATOR)) : List.of();
		};
	}

	@Bean
	JwtAuthenticationConverter cfAccessAuthenticationConverter(AdminProperties props) {
		JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
		converter.setJwtGrantedAuthoritiesConverter(serviceTokenAuthorities(props));
		converter.setPrincipalClaimName("common_name");
		return converter;
	}

}
