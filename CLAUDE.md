# Distribution Module — Multi-Runtime Packaging & Deployment

## Purpose
Assembles all Water Framework modules into deployable artifacts for each supported runtime. Each sub-module produces a different output format targeting a specific deployment environment. No new business logic lives here — this is pure packaging and configuration assembly.

## Sub-modules

| Sub-module | Output Artifact | Target Environment |
|---|---|---|
| `Distribution-osgi` | `osgi-distribution.jar` (uber-JAR) + Karaf container | Apache Karaf 4.4.6 standalone |
| `Distribution-spring` | `spring-distribution.jar` (executable Spring Boot JAR) | Spring Boot 3.3.1 standalone |
| `Distribution-quarkus` | Quarkus JVM JAR or native binary | Quarkus / GraalVM native |
| `Distribution-karaf` | `features.xml` (Karaf feature descriptor) | Existing Karaf container (modular install) |

## Distribution-osgi

### Build Task
```bash
# Full Karaf container with Water embedded
./gradlew Distribution-osgi:karafWaterDistributionBuild

# Uber-JAR only (no Karaf container)
./gradlew Distribution-osgi:osgiJar
```

### JAR Merging Strategy (Gradle Shadow)
The OSGi distribution merges all module JARs into a single uber-JAR:
- **Atteo ClassIndex consolidation**: `META-INF/annotations/*.list` files are merged across all modules — critical for zero-reflection component discovery
- **OSGi manifest headers**: `Bundle-SymbolicName`, `Export-Package`, `Import-Package` are computed from merged contents
- **zip64**: enabled to handle large jar counts exceeding standard ZIP limits

### Karaf Container Assembly
```
Distribution-osgi/
  ├─ build/karaf-distribution/
  │   ├─ bin/ (karaf, client scripts)
  │   ├─ etc/ (org.ops4j.pax.url.mvn.cfg, etc.)
  │   ├─ system/ (pre-installed bundles)
  │   └─ deploy/ (hot-deploy folder)
  └─ src/main/karaf/
      └─ features.xml (custom feature definitions)
```

## Distribution-spring

### Build Task
```bash
./gradlew Distribution-spring:springJar
```

### Configuration
The Spring distribution includes a `@SpringBootApplication` entry point that:
1. Activates `@EnableWaterFramework` — registers all Water infrastructure beans
2. Configures JPA entity scanning across all modules (via `@EntityScan`)
3. Sets up the Spring MVC dispatcher with all REST controllers
4. Auto-configures Spring Security JWT filter chain

```java
@SpringBootApplication
@EnableWaterFramework
@EntityScan(basePackages = "it.water")
@ComponentScan(basePackages = "it.water")
public class WaterSpringDistributionApp {
    public static void main(String[] args) {
        SpringApplication.run(WaterSpringDistributionApp.class, args);
    }
}
```

### application.properties (Spring Distribution)
```properties
server.port=8080
spring.datasource.url=jdbc:h2:mem:waterdb;DB_CLOSE_DELAY=-1
spring.jpa.hibernate.ddl-auto=create-drop
# Keystore for JWT signing — ALL keystore inputs are env-driven and fail-fast (no insecure defaults)
water.keystore.file=${WATER_KEYSTORE_FILE}
water.keystore.password=${WATER_KEYSTORE_PASSWORD}
water.keystore.alias=${WATER_KEYSTORE_ALIAS:server-cert}
water.private.key.password=${WATER_PRIVATE_KEY_PASSWORD}
water.authentication.service.issuer=water
```

### Keystore is fail-fast — no bundled keys (#1, #3)
The deployable (`Distribution-spring-app`) **must** be given its keystore via environment:
- `water.keystore.file=${WATER_KEYSTORE_FILE}` — **no** `:src/main/resources/certs` fallback (#1). A missing
  `WATER_KEYSTORE_FILE` fails fast at startup instead of silently loading test certs shipped in the JAR.
- `water.keystore.password` / `water.private.key.password` have **no** default either (#3) — a missing env var
  fails fast rather than falling back to the well-known test password.

Test keystores live **only under `src/test/resources/certs/`** across all modules (never `src/main/resources`),
so no crypto material is packaged into the main/runtime JARs. The generator templates
(`scaffolding/*/service-module*`) place `certs/` under `src/test` as well, so newly scaffolded modules stay clean.
A real deployment provides its own keystore via `WATER_KEYSTORE_*` env vars.

## Distribution-quarkus

### Build Tasks
```bash
# Development mode with hot reload
./gradlew Distribution-quarkus:quarkusDev

# Production JVM JAR
./gradlew Distribution-quarkus:build

# Native binary (requires GraalVM)
./gradlew Distribution-quarkus:build -Dquarkus.native.enabled=true
```

### Quarkus-Specific Configuration
```properties
# application.properties (Quarkus)
quarkus.datasource.db-kind=postgresql
quarkus.datasource.jdbc.url=jdbc:postgresql://localhost:5432/waterdb
quarkus.hibernate-orm.database.generation=drop-and-create
quarkus.http.port=8080
```

### Native Image Considerations
For native compilation, all reflection usage must be declared in `reflect-config.json`. The Atteo ClassIndex replaces reflection-based component discovery, making most of the framework native-compatible out of the box.

## Distribution-karaf (Features Descriptor)

Produces a `features.xml` for incremental installation into an **existing** Karaf container:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<features name="water-features" xmlns="...">

  <feature name="water-core" version="3.0.0">
    <bundle>mvn:it.water.core/Core-api/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-model/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-security/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-permission/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-interceptors/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-registry/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-service/3.0.0</bundle>
    <bundle>mvn:it.water.core/Core-bundle/3.0.0</bundle>
    <bundle>mvn:it.water.implementation/Implementation-osgi/3.0.0</bundle>
  </feature>

  <feature name="water-persistence" version="3.0.0" depends-on="water-core">
    <bundle>mvn:it.water.repository/Repository-entity/3.0.0</bundle>
    <bundle>mvn:it.water.repository/Repository-persistence/3.0.0</bundle>
    <bundle>mvn:it.water.repository/Repository-service/3.0.0</bundle>
    <bundle>mvn:it.water.jparepository/JpaRepository-api/3.0.0</bundle>
    <bundle>mvn:it.water.jparepository/JpaRepository-osgi/3.0.0</bundle>
  </feature>

  <feature name="water-rest" version="3.0.0" depends-on="water-persistence">
    <bundle>mvn:it.water.rest/Rest-api/3.0.0</bundle>
    <bundle>mvn:it.water.rest/Rest-jaxrs-api/3.0.0</bundle>
    <!-- ... -->
  </feature>

  <feature name="water-user-management" version="3.0.0" depends-on="water-rest">
    <feature>water-persistence</feature>
    <bundle>mvn:it.water.user/User-api/3.0.0</bundle>
    <!-- ... -->
  </feature>

</features>
```

Install in Karaf:
```
karaf> feature:repo-add mvn:it.water.distribution/Distribution-karaf/3.0.0/xml/features
karaf> feature:install water-core water-persistence water-rest water-user-management
```

## Build Order (Full Rebuild)

When rebuilding from scratch (e.g., after a `Core` change), build in dependency order:
```bash
./gradlew Core:publishToMavenLocal -x test
./gradlew Implementation:publishToMavenLocal -x test
./gradlew Repository:publishToMavenLocal -x test
./gradlew JpaRepository:publishToMavenLocal -x test
./gradlew Rest:publishToMavenLocal -x test
# ... other modules ...
./gradlew Distribution:build
```

Or using the Water generator:
```bash
yo water:build --projects=Core,Implementation,Repository,JpaRepository,Rest,Distribution
```

## Dependencies
- All Water framework modules (Core, Implementation, Repository, JpaRepository, Rest, Authentication, User, Role, Permission, ...)
- `com.github.johnrengelman.shadow` — JAR merging for OSGi uber-JAR
- `org.springframework.boot:spring-boot-gradle-plugin` — Spring Boot JAR packaging
- `io.quarkus:quarkus-gradle-plugin` — Quarkus build integration

## Code Generation Rules
- NEVER add business logic to Distribution modules — only packaging configuration
- When adding a new module: add its bundles to the appropriate Karaf feature in `Distribution-karaf/features.xml`
- Atteo ClassIndex files MUST be merged (not overwritten) in the uber-JAR — the Shadow plugin `mergeServiceFiles()` handles this
- Spring Boot distribution: add new `@EntityScan` packages or `@ComponentScan` packages as new modules are added
- Quarkus native: register new reflection-using classes in `reflect-config.json` if discovered at runtime
