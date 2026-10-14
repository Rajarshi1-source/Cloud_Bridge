package dev.cloudbridge.gateway.web;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

/** Only the control-plane dashboard may call the API from a browser. Nothing is registered for /admin/**. */
@Configuration(proxyBeanMethods = false)
class CorsConfig {

	@Bean
	CorsConfigurationSource corsConfigurationSource(@Value("${cloudbridge.cors.allowed-origins}") List<String> origins) {
		CorsConfiguration cfg = new CorsConfiguration();
		cfg.setAllowedOrigins(origins); // exact origins, never "*"
		cfg.setAllowedMethods(List.of("GET", "POST", "OPTIONS"));
		cfg.setAllowedHeaders(List.of("Content-Type", "Idempotency-Key"));
		cfg.setExposedHeaders(List.of("X-CB-Cell", "Idempotent-Replayed", "RateLimit-Limit", "RateLimit-Remaining",
				"RateLimit-Reset", "Retry-After"));
		cfg.setAllowCredentials(false);
		cfg.setMaxAge(600L);
		UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
		source.registerCorsConfiguration("/orders", cfg);
		source.registerCorsConfiguration("/orders/**", cfg);
		source.registerCorsConfiguration("/inventory/**", cfg);
		return source;
	}

}
