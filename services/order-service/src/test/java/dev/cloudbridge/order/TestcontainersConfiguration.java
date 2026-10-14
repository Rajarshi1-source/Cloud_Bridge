package dev.cloudbridge.order;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

@TestConfiguration(proxyBeanMethods = false)
class TestcontainersConfiguration {

	@Bean
	@ServiceConnection
	PostgreSQLContainer postgresContainer() {
		return new PostgreSQLContainer(DockerImageName.parse("postgres:18.4-alpine"));
	}

	@Bean
	@ServiceConnection(name = "redis") // Valkey speaks the Redis protocol
	GenericContainer<?> valkeyContainer() {
		return new GenericContainer<>(DockerImageName.parse("valkey/valkey:9.0-alpine")).withExposedPorts(6379);
	}

}
