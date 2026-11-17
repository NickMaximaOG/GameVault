# Build with Maven, run on a slim JRE. (Needs internet access to Maven Central.)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B -DskipTests package

FROM eclipse-temurin:21-jre
RUN useradd --system --uid 10001 gv
WORKDIR /app
COPY --from=build /src/target/gamevault-api-2.0.0.jar app.jar
USER gv
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=5 CMD ["bash","-c","exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /api/v1/health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q 200 <&3"]
ENTRYPOINT ["java","-Duser.timezone=UTC","-jar","app.jar"]
