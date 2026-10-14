# syntax=docker/dockerfile:1.7
# Layered jar: a code-only change ships a ~100 KB layer, so cells pull fast during an evacuation scale-up.
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN --mount=type=cache,target=/root/.m2 sh mvnw -q -B dependency:go-offline
COPY src src
RUN --mount=type=cache,target=/root/.m2 sh mvnw -q -B -DskipTests package  && java -Djarmode=tools -jar target/inventory-service-*.jar extract --layers --launcher --destination /out

FROM eclipse-temurin:21-jre
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /out/dependencies/ ./
COPY --from=build /out/spring-boot-loader/ ./
COPY --from=build /out/snapshot-dependencies/ ./
COPY --from=build /out/application/ ./
USER 10001
EXPOSE 8082 9080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=70", "-XX:+ExitOnOutOfMemoryError", "org.springframework.boot.loader.launch.JarLauncher"]
