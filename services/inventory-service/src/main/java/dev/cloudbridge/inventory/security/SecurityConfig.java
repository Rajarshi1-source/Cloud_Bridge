package dev.cloudbridge.inventory.security;

import jakarta.servlet.DispatcherType;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.web.BearerTokenResolver;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;

/**
 * Defence in depth: the gateway already validated the Access JWT, and this service validates the
 * same token again, so a pod that reaches inventory directly still cannot grant stock. The host
 * check lives in the gateway; the rest of this API is internal and guarded by NetworkPolicy.
 */
@Configuration(proxyBeanMethods = false)
class SecurityConfig {

	private static final PathPatternRequestMatcher.Builder PATHS = PathPatternRequestMatcher.withDefaults();

	@Bean
	@Order(1)
	SecurityFilterChain adminChain(HttpSecurity http, BearerTokenResolver resolver, JwtDecoder decoder,
			JwtAuthenticationConverter converter) throws Exception {
		http.securityMatcher(PATHS.matcher("/admin/**"))
			.authorizeHttpRequests((a) -> a
				.requestMatchers(PATHS.matcher(HttpMethod.POST, "/admin/leases/grant"),
						PATHS.matcher(HttpMethod.GET, "/admin/leases/report"))
				.hasAuthority(CfAccessJwtConfig.ROLE_LEASE_ALLOCATOR)
				.anyRequest()
				.denyAll())
			.oauth2ResourceServer((o) -> o.bearerTokenResolver(resolver)
				.jwt((j) -> j.decoder(decoder).jwtAuthenticationConverter(converter)))
			.sessionManagement((s) -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
			.csrf((c) -> c.ignoringRequestMatchers(PATHS.matcher("/admin/**"))) // header-authenticated, no cookies
			.cors((c) -> c.disable()); // no browser ever calls the admin API
		return http.build();
	}

	@Bean
	@Order(2)
	SecurityFilterChain internalChain(HttpSecurity http) throws Exception {
		http.authorizeHttpRequests((a) -> a
			.dispatcherTypeMatchers(DispatcherType.FORWARD, DispatcherType.ERROR).permitAll()
			.requestMatchers(PATHS.matcher("/reservations/**"), PATHS.matcher(HttpMethod.GET, "/inventory/*"))
			.permitAll()
			.requestMatchers(PATHS.matcher("/actuator/health/**"), PATHS.matcher("/actuator/prometheus"),
					PATHS.matcher("/actuator/info"))
			.permitAll() // management port 9080, NetworkPolicy-guarded
			.anyRequest()
			.denyAll())
			.exceptionHandling((e) -> e
				.authenticationEntryPoint((req, res, ex) -> res.sendError(HttpServletResponse.SC_NOT_FOUND))
				.accessDeniedHandler((req, res, ex) -> res.sendError(HttpServletResponse.SC_NOT_FOUND)))
			.sessionManagement((s) -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
			.csrf((c) -> c.ignoringRequestMatchers(PATHS.matcher("/reservations/**"))); // called by order-service only
		return http.build();
	}

}
