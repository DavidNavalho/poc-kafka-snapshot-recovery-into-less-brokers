FROM maven:3.9.9-eclipse-temurin-21 AS build

WORKDIR /build
COPY tooling/snapshot-rewrite/pom.xml tooling/snapshot-rewrite/pom.xml
COPY tooling/snapshot-rewrite/src tooling/snapshot-rewrite/src
RUN mvn -f tooling/snapshot-rewrite/pom.xml --batch-mode --no-transfer-progress package

FROM eclipse-temurin:21-jre

WORKDIR /app
COPY --from=build /build/tooling/snapshot-rewrite/target/snapshot-rewrite-tool.jar /app/snapshot-rewrite-tool.jar
ENTRYPOINT ["java", "-jar", "/app/snapshot-rewrite-tool.jar"]
