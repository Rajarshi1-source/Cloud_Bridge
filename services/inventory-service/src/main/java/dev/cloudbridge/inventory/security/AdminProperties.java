package dev.cloudbridge.inventory.security;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

import java.net.URI;
import java.time.Duration;
import java.util.Set;

/** Fail closed: a missing value stops start-up instead of silently disabling admin auth. */
@Validated
@ConfigurationProperties("cloudbridge.admin")
public record AdminProperties(@NotNull URI teamDomain, @NotBlank String audience,
		@NotEmpty Set<String> allowedServiceTokens, @NotNull Duration clockSkew) {

	public String jwksUri() {
		return this.teamDomain + "/cdn-cgi/access/certs";
	}

	public String issuer() {
		return this.teamDomain.toString();
	}

}
