# Distribution-spring-app

Minimal Spring Boot application with the Water Framework enabled. It acts as the executable entry point for all Water modules in a Spring/Spring Boot environment and supports dynamic runtime extension through external JARs.

---

## Table of contents

1. [Architectural overview](#1-architectural-overview)
2. [Prerequisites](#2-prerequisites)
3. [Building the module](#3-building-the-module)
4. [Running as a classic Java runner](#4-running-as-a-classic-java-runner)
5. [Building and running the Docker container](#5-building-and-running-the-docker-container)
6. [Environment variables reference](#6-environment-variables-reference)
7. [Runtime extension system (extlib)](#7-runtime-extension-system-extlib)
8. [Dynamic module provisioning from Maven repositories](#8-dynamic-module-provisioning-from-maven-repositories)
9. [Database configuration](#9-database-configuration)
10. [Certificate and keystore configuration](#10-certificate-and-keystore-configuration)
11. [Health check](#11-health-check)
12. [Production best practices](#12-production-best-practices)

---

## 1. Architectural overview

The module is made of two main classes that work in sequence:

```
java -jar app.jar
       │
       ▼
  WaterLauncher.main()           ← actual entry point
       │
       ├─ 1. Reads water.extra.classpath.dir (application.properties / env)
       ├─ 2. Builds a URLClassLoader with all the .jar files in /extlib
       ├─ 3. Reads it.water.application.properties from each external JAR
       ├─ 4. Registers the external properties as a WaterPropertiesPropertySource
       │
       ▼
  SpringApplication.run(WaterSpringApplication.class)
       │
       ├─ @EnableWaterFramework      → registers all Water infrastructure
       ├─ @EnableJpaRepositories     → configures RepositoryFactory over it.water.*
       ├─ @EntityScan("it.water")    → JPA entity scan across all modules
       └─ @ComponentScan("it.water") → Spring bean scan across all modules
```

### Why two classes?

`WaterLauncher` sets up the classloader **before** Spring initializes the application context. This makes the JARs dropped into `/extlib` visible to Spring during auto-configuration, allowing Water modules to be added at runtime without recompiling the main JAR.

---

## 2. Prerequisites

| Component | Minimum version |
|---|---|
| Java JDK | 17 |
| Gradle | 7.x (managed by the wrapper) |
| Node.js (for the generator) | 18.20.8 |
| Yeoman + yo water | see NVM setup |
| Docker (optional) | 20.x+ |

Environment check:

```bash
java -version          # must show openjdk 17+
gradle --version       # or ./gradlew --version
node --version         # v18.20.8
yo water:help          # must respond with the list of commands
```

---

## 3. Building the module

> **Rule**: always use `yo water:build` — never `./gradlew` directly.

### Single-module build

```bash
# Activate the correct Node version (if using NVM)
source /opt/homebrew/Cellar/nvm/0.39.0/nvm.sh && nvm use 18.20.8

# Distribution-spring-app is a subproject of the "Distribution" Gradle build:
# build it by passing the registered project "Distribution" (not "Distribution-spring-app").
yo water:build --projects Distribution
```

### Full build from the root (with all dependencies)

```bash
yo water:build --projects Core,Implementation,Repository,JpaRepository,Rest,Distribution
```

The produced artifact is an **executable fat JAR** (~64MB, all dependencies included,
`Main-Class: it.water.distribution.spring.app.WaterLauncher`) created via Gradle Shadow:

```
Distribution-spring-app/build/libs/Distribution-spring-app-3.0.0.jar
```

> The fat JAR is built **without** the Spring Boot plugin: `shadowJar` merges the
> Atteo ClassIndex descriptors (`META-INF/annotations`), the `META-INF/services` files and the Spring
> descriptors (`spring.factories`, `AutoConfiguration.imports`) required for auto-configuration.

---

## 4. Running as a classic Java runner

### Minimal start (in-memory database, default configuration)

```bash
java -jar Distribution-spring-app-3.0.0.jar
```

The application will be reachable at `http://localhost:8080/water`.

### Start with custom environment variables

```bash
java \
  -DSERVER_PORT=9090 \
  -DDB_HOST="jdbc:postgresql://localhost:5432/waterdb" \
  -DDB_DRIVER_CLASS_NAME="org.postgresql.Driver" \
  -DDB_USERNAME="water_user" \
  -DDB_PASSWORD="secret" \
  -DEXTRA_CLASSPATH_DIR="/opt/water/modules" \
  -jar Distribution-spring-app-3.0.0.jar
```

Variables can be passed interchangeably as:
- **System property** (`-Dkey=value`)
- **Environment variable** (`export KEY=value` before launching)

### Start with additional modules in extlib

```bash
export EXTRA_CLASSPATH_DIR=/opt/water/modules
export EXTRA_SCAN_PACKAGES=it.water.mymodule,it.water.anothermodule

java -jar Distribution-spring-app-3.0.0.jar
```

The JARs found in `/opt/water/modules` are automatically loaded by `WaterLauncher` before Spring starts.

### Recommended startup script (production)

```bash
#!/usr/bin/env bash
# start-water.sh

export SERVER_PORT=8080
export SERVER_SERVLET_CONTEXT_PATH=/water
export EXTRA_CLASSPATH_DIR=/opt/water/modules

# Database
export DB_DRIVER_CLASS_NAME=org.postgresql.Driver
export DB_HOST=jdbc:postgresql://db-host:5432/waterdb
export DB_USERNAME=water_user
export DB_PASSWORD=changeme

# Keystore
export WATER_KEYSTORE_FILE=/opt/water/certs/server.keystore
export WATER_KEYSTORE_PASSWORD=changeme
export WATER_PRIVATE_KEY_PASSWORD=changeme

# JVM tuning
exec java \
  -Xms512m -Xmx1024m \
  -XX:+UseG1GC \
  -Djava.security.egd=file:/dev/./urandom \
  -jar /opt/water/app.jar
```

---

## 5. Building and running the Docker container

### 5.1 Building the image

The JAR must already be compiled before building the image:

```bash
# 1. Build the JAR
yo water:build --projects Distribution

# 2. Build the Docker image (from the module directory)
cd Distribution/Distribution-spring-app

docker build \
  -t water-spring-app:3.0.0 \
  -t water-spring-app:latest \
  .
```

The Dockerfile uses `eclipse-temurin:17-jre-jammy` as the base image and copies the JAR produced by Gradle:

```
build/libs/Distribution-spring-app-*.jar → /app/app.jar
```

The image:
- Creates a non-root `water` user (least-privilege principle)
- Exposes port `8080`
- Declares the `/extlib` volume for runtime modules

### 5.2 Running the container — minimal configuration

```bash
docker run -d \
  --name water-app \
  -p 8080:8080 \
  water-spring-app:latest
```

### 5.3 Running the container — full configuration

```bash
docker run -d \
  --name water-app \
  -p 8080:8080 \
  -e SERVER_PORT=8080 \
  -e SERVER_SERVLET_CONTEXT_PATH=/water \
  -e DB_DRIVER_CLASS_NAME=org.postgresql.Driver \
  -e DB_HOST=jdbc:postgresql://postgres:5432/waterdb \
  -e DB_USERNAME=water_user \
  -e DB_PASSWORD=secret \
  -e DB_POOL_SIZE=20 \
  -e WATER_KEYSTORE_TYPE=jks \
  -e WATER_KEYSTORE_FILE=/certs/server.keystore \
  -e WATER_KEYSTORE_PASSWORD=changeme \
  -e WATER_KEYSTORE_ALIAS=server-cert \
  -e WATER_PRIVATE_KEY_PASSWORD=changeme \
  -e EXTRA_CLASSPATH_DIR=/extlib \
  -e EXTRA_SCAN_PACKAGES=it.water.mymodule \
  -v /host/path/modules:/extlib \
  -v /host/path/certs:/certs:ro \
  water-spring-app:latest
```

### 5.4 Docker Compose (full stack with PostgreSQL)

```yaml
# docker-compose.yml
version: "3.9"

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: waterdb
      POSTGRES_USER: water_user
      POSTGRES_PASSWORD: secret
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U water_user -d waterdb"]
      interval: 10s
      timeout: 5s
      retries: 5

  water-app:
    image: water-spring-app:latest
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8080:8080"
    environment:
      SERVER_PORT: 8080
      SERVER_SERVLET_CONTEXT_PATH: /water

      # Database
      DB_DRIVER_CLASS_NAME: org.postgresql.Driver
      DB_HOST: jdbc:postgresql://postgres:5432/waterdb
      DB_USERNAME: water_user
      DB_PASSWORD: secret
      DB_POOL_SIZE: 20

      # Keystore
      WATER_KEYSTORE_TYPE: jks
      WATER_KEYSTORE_FILE: /certs/server.keystore
      WATER_KEYSTORE_PASSWORD: changeme
      WATER_KEYSTORE_ALIAS: server-cert
      WATER_PRIVATE_KEY_PASSWORD: changeme

      # Additional modules
      EXTRA_CLASSPATH_DIR: /extlib
      EXTRA_SCAN_PACKAGES: ""

    volumes:
      - ./modules:/extlib          # additional Water module JARs
      - ./certs:/certs:ro          # certificates and keystore

volumes:
  pg_data:
```

```bash
# Start the stack
docker compose up -d

# Live logs
docker compose logs -f water-app

# Stop
docker compose down
```

> **Note**: the PostgreSQL driver (`org.postgresql:postgresql`) must be present in the main JAR or added as a dependency in `build.gradle` before the build. It cannot be loaded through `/extlib` because the Spring datasource is initialized before the extended classloader.

---

## 6. Environment variables reference

All variables have a default value applied both in `application.properties` (via `${VAR:default}`) and in the `Dockerfile`.

### Server

| Variable | Default | Description |
|---|---|---|
| `SERVER_PORT` | `8080` | HTTP port Spring Boot listens on |
| `SERVER_SERVLET_CONTEXT_PATH` | `/water` | Application context path. All REST endpoints are relative to this path |

### Classpath and scanning

| Variable | Default | Description |
|---|---|---|
| `EXTRA_CLASSPATH_DIR` | `/extlib` | Directory from which `WaterLauncher` loads Water module JARs into an **isolated child classloader** before Spring starts |
| `BASE_CLASSPATH_DIR` | `/baselib` | Directory whose JARs are placed on the JVM **system classpath** (next to `app.jar`), sharing the application classloader with Spring. Use for libraries Spring/Hikari must see at bean-creation time — e.g. JDBC drivers |
| `EXTRA_SCAN_PACKAGES` | *(empty)* | Additional packages passed to `@ComponentScan`. Comma-separated. Needed only for modules outside `it.water.*` |

### Dynamic module provisioning (see section 8)

| Variable | Default | Description |
|---|---|---|
| `WATER_MODULES` | *(empty)* | Comma-separated Maven coordinates `groupId:artifactId:version`, downloaded into `/extlib` (Water modules → isolated child classloader) at startup |
| `WATER_BASE_MODULES` | *(empty)* | Comma-separated Maven coordinates downloaded into `/baselib` and put on the **system classpath** (shared with Spring). Use for JDBC drivers and other libraries Spring must see directly — e.g. `org.postgresql:postgresql:42.7.7` |
| `WATER_MAVEN_REPO_1_URL` | `https://nexus.acsoftware.it/nexus/repository/maven-water/` | Primary repository (public Water Nexus). Resolves Water artifacts out-of-the-box |
| `WATER_MAVEN_REPO_2_URL` | `file:///m2/repository` | Secondary repository: a Maven local repo, usable by mounting the host `~/.m2/repository` to `/m2/repository` (read by `curl`'s `file://` support) |
| `WATER_MAVEN_REPO_<n>_URL` | *(empty)* | Base URL of the n-th repository (`n`=1,2,3,...), tried in order with failover (first HTTP 200 wins) |
| `WATER_MAVEN_REPO_<n>_USER` | *(empty)* | Optional username for the n-th repo |
| `WATER_MAVEN_REPO_<n>_PASSWORD` | *(empty)* | Optional password/token for the n-th repo |

### Test mode

| Variable | Default | Description |
|---|---|---|
| `WATER_TEST_MODE` | `false` | If `true`, disables JWT validation and some security protections. **Never `true` in production.** |

### Keystore and certificates

| Variable | Default | Description |
|---|---|---|
| `WATER_KEYSTORE_TYPE` | `jks` | Keystore type: `jks` or `pkcs12` |
| `WATER_KEYSTORE_FILE` | `/app/default-certs/server.keystore` (container fallback) | **Plain file path** of the keystore (e.g. `/certs/server.keystore`) or `classpath:...`. Do **not** use the `file:` prefix. If the variable is absent, the entrypoint uses the demo keystore generated in the image (see note below) |
| `WATER_KEYSTORE_PASSWORD` | `water.` | Keystore password |
| `WATER_KEYSTORE_ALIAS` | `server-cert` | Server certificate alias in the keystore |
| `WATER_PRIVATE_KEY_PASSWORD` | `water.` | Private key password |

### Database

| Variable | Default | Description |
|---|---|---|
| `DB_DRIVER_CLASS_NAME` | `org.hsqldb.jdbcDriver` | JDBC driver class. Change it for PostgreSQL, MySQL, etc. |
| `DB_HOST` | `jdbc:hsqldb:mem:waterdb` | JDBC connection URL |
| `DB_USERNAME` | `sa` | Database username |
| `DB_PASSWORD` | *(empty)* | Database password |
| `DB_POOL_SIZE` | `10` | Maximum HikariCP pool size |

---

## 7. Runtime extension system (extlib)

`WaterLauncher` implements a **JAR plugin** mechanism that allows adding Water modules to the application without recompiling the main JAR.

### How it works

```
JVM start
   │
   ▼
WaterLauncher reads EXTRA_CLASSPATH_DIR (default: /extlib)
   │
   ├─ Builds a URLClassLoader with all the .jar files found
   │   └─ Sets it as the ContextClassLoader of the main thread
   │
   ├─ For each JAR: looks for it.water.application.properties
   │   └─ Loads the properties and registers them as a WaterPropertiesPropertySource
   │
   └─ Starts SpringApplication with the updated ResourceLoader
         └─ Spring sees all classes in the external JARs
```

### Structure of a compatible external module

A JAR to drop into `/extlib` must:

1. Contain classes annotated with `@FrameworkComponent` (or Spring's `@Component`)
2. Optionally: include `it.water.application.properties` at the JAR root

```
mymodule.jar
├─ it/water/mymodule/
│   ├─ MyService.class          (@FrameworkComponent)
│   └─ MyEntity.class           (@Entity)
└─ it.water.application.properties   ← module-specific properties
```

### Example of it.water.application.properties

```properties
# it.water.application.properties (at the external JAR root)
mymodule.feature.enabled=true
mymodule.timeout=5000
```

### Preloaded modules (extraLib)

The repository already includes ready-to-use modules under `extraLib/`:

| JAR | Function |
|---|---|
| `Authentication-service-spring-3.0.0.jar` | JWT authentication service |
| `User-service-spring-3.0.0.jar` | User, role and permission management |

To enable them in a container:

```bash
docker run -d \
  -v $(pwd)/extraLib:/extlib \
  water-spring-app:latest
```

---

## 8. Dynamic module provisioning from Maven repositories

In addition to statically placing JARs in `/extlib` (mounted volume or `extraLib/` baked into the image), the container can **download Water modules at runtime** directly from one or more Maven repositories, without rebuilding the image or mounting volumes.

### How it works

```
container start
   └─ entrypoint.sh
        ├─ 1. reads WATER_MODULES + WATER_BASE_MODULES (lists of Maven coordinates)
        ├─ 2. reads the WATER_MAVEN_REPO_<n>_URL/USER/PASSWORD repositories
        ├─ 3. WATER_MODULES      → downloads each jar into /extlib  (repo failover)
        │     WATER_BASE_MODULES → downloads each jar into /baselib (repo failover)
        ├─ 4. fail-fast if a module cannot be resolved in ANY repo
        └─ 5. exec java -cp "app.jar:/baselib/*" WaterLauncher   ← container env inherited
                  ├─ /baselib jars are on the SYSTEM classloader (visible to Spring/Hikari)
                  └─ WaterLauncher loads /extlib into a child classloader (section 7)
```

The container environment variables are **automatically inherited** by the `java` process (the entrypoint uses `exec`): no manual forwarding is needed, the Spring app resolves them through the `${VAR:default}` placeholders in `application.properties`.

### Configuration variables

| Variable | Description |
|---|---|
| `WATER_MODULES` | Comma-separated list of Maven coordinates `groupId:artifactId:version` → `/extlib` (isolated child classloader). If empty, no download (backward compatible with volume/`extraLib`). |
| `WATER_BASE_MODULES` | Comma-separated Maven coordinates → `/baselib`, put on the **system classpath** (shared with Spring). Use for JDBC drivers and other libraries Spring/Hikari must resolve at bean-creation time. |
| `WATER_MAVEN_REPO_<n>_URL` | Base URL of the n-th repository (`n` = 1, 2, 3, ...). Iterated in order while set. |
| `WATER_MAVEN_REPO_<n>_USER` | *(optional)* Username for the n-th repo. |
| `WATER_MAVEN_REPO_<n>_PASSWORD` | *(optional)* Password/token for the n-th repo. |

### Behavior

- **Flat download**: only the listed module JARs are downloaded (no transitive dependency resolution). Each `*-service-spring` module is expected to be **self-contained** (it bundles its own `api`/`model`/`service` via the build's `implementationInclude`); its non-Water dependencies are provided by the base `app.jar`. List every module you need explicitly in `WATER_MODULES`.
- **Non-Water libraries Spring must see directly** (e.g. JDBC drivers) go in `WATER_BASE_MODULES` → `/baselib` (system classpath). Putting a JDBC driver in `WATER_MODULES`/`/extlib` instead causes `Cannot load driver class` because the child classloader is invisible to Hikari.
- **Baked `javax.servlet-api`** (in `/baselib`): Water `*-service-spring` modules bundle their JAX-RS/CXF controllers, whose base class carries a `@Context javax.servlet.http.HttpServletRequest` field (Authentication #34/#37). The Spring controller `extends` that JAX-RS class, so Spring Boot 3 introspects the inherited `javax.servlet` field — which would throw `NoClassDefFoundError` (Spring Boot 3 ships only `jakarta.servlet`). The image ships `javax.servlet-api` on the base classpath so the field is loadable; it stays inert (the Spring controller reads the request via `RequestContextHolder`/jakarta).
- **JAR validation**: a download is accepted only if it starts with the ZIP magic bytes (`PK`). A misconfigured repo URL (e.g. the Nexus **web UI** URL `.../#browse/browse:<repo>` instead of the repository URL `.../repository/<repo>/`) returns HTML `200` that would be saved as a corrupt `.jar`; this is now rejected with a clear error and the next repo is tried.
- **Failover**: for each module the repositories are tried in order `1, 2, 3, ...`; the **first** that returns a valid jar wins. The log shows which repo each module was taken from.
- **Per-repo auth**: if `_USER`/`_PASSWORD` are set for a repo, `curl` uses basic authentication against that repo.
- **Fail-fast** (consistent with the keystore policy):
  - module not found in any repo → `exit 1` before starting Spring;
  - `WATER_MODULES` set but no repository configured → `exit 1`;
  - malformed coordinate (≠ `groupId:artifactId:version`) → `exit 1`;
  - `*-SNAPSHOT` version → `exit 1` (not supported: it would require resolving `maven-metadata.xml`).

> **Built URL**: `<repoBaseUrl>/<groupId with / instead of .>/<artifactId>/<version>/<artifactId>-<version>.jar`

### `docker run` example

```bash
docker run -d \
  --name water-app \
  -p 8080:8080 \
  -e WATER_MODULES="it.water.user:User-service-spring:3.0.0,it.water.authentication:Authentication-service-spring:3.0.0" \
  -e WATER_BASE_MODULES="org.postgresql:postgresql:42.7.7" \
  -e WATER_MAVEN_REPO_1_URL="https://nexus.company.com/repository/maven-releases" \
  -e WATER_MAVEN_REPO_1_USER="ci-reader" \
  -e WATER_MAVEN_REPO_1_PASSWORD="s3cr3t" \
  -e WATER_MAVEN_REPO_2_URL="https://repo1.maven.org/maven2" \
  -e WATER_KEYSTORE_TYPE=jks \
  -e WATER_KEYSTORE_FILE=/certs/server.keystore \
  -e WATER_KEYSTORE_PASSWORD=changeme \
  -e WATER_PRIVATE_KEY_PASSWORD=changeme \
  -v /host/certs:/certs:ro \
  water-spring-app:latest
```

### Docker Compose example

```yaml
services:
  water-app:
    image: water-spring-app:latest
    ports:
      - "8080:8080"
    environment:
      # Water modules downloaded at runtime (→ /extlib, child classloader)
      WATER_MODULES: "it.water.user:User-service-spring:3.0.0,it.water.authentication:Authentication-service-spring:3.0.0"
      # Base classpath jars (→ /baselib, system classloader): JDBC driver visible to Spring/Hikari
      WATER_BASE_MODULES: "org.postgresql:postgresql:42.7.7"

      # Repositories in failover order
      WATER_MAVEN_REPO_1_URL: "https://nexus.company.com/repository/maven-releases"
      WATER_MAVEN_REPO_1_USER: "ci-reader"
      WATER_MAVEN_REPO_1_PASSWORD: "s3cr3t"
      WATER_MAVEN_REPO_2_URL: "https://repo1.maven.org/maven2"

      # Keystore (fail-fast, see section 10)
      WATER_KEYSTORE_TYPE: jks
      WATER_KEYSTORE_FILE: /certs/server.keystore
      WATER_KEYSTORE_PASSWORD: changeme
      WATER_PRIVATE_KEY_PASSWORD: changeme
    volumes:
      - ./certs:/certs:ro
```

> **Combinable with `/extlib` and `/baselib`**: the JARs downloaded from `WATER_MODULES`/`WATER_BASE_MODULES` are **added** to those already present in `/extlib` and `/baselib` (volume or `extraLib`), they do not replace them.

---

## 9. Database configuration

### Default: in-memory HSQLDB (development / test)

Active by default, requires no external setup. Data is lost on restart (`create-drop`).

```properties
spring.datasource.driver-class-name=org.hsqldb.jdbcDriver
spring.datasource.url=jdbc:hsqldb:mem:waterdb
spring.datasource.username=sa
spring.datasource.password=
```

### PostgreSQL (recommended for production)

Add the dependency in `build.gradle` before the build:

```groovy
implementation 'org.postgresql:postgresql:42.7.3'
```

Then configure via environment variables:

```bash
DB_DRIVER_CLASS_NAME=org.postgresql.Driver
DB_HOST=jdbc:postgresql://localhost:5432/waterdb
DB_USERNAME=water_user
DB_PASSWORD=secret
DB_POOL_SIZE=20
```

### MySQL / MariaDB

```groovy
implementation 'com.mysql:mysql-connector-j:8.3.0'
```

```bash
DB_DRIVER_CLASS_NAME=com.mysql.cj.jdbc.Driver
DB_HOST=jdbc:mysql://localhost:3306/waterdb?useSSL=false&serverTimezone=UTC
DB_USERNAME=water_user
DB_PASSWORD=secret
```

### DDL strategy

The property `spring.jpa.hibernate.ddl-auto=create-drop` is fixed in `application.properties` and suited to development. For production it is recommended to override it by adding to the JVM:

```bash
-Dspring.jpa.hibernate.ddl-auto=validate
```

or by managing migrations with Flyway or Liquibase.

---

## 10. Certificate and keystore configuration

### Container demo keystore (development/test only)

The **JAR contains no certificate** (security fix #1: no well-known keys in the artifact,
a missing `WATER_KEYSTORE_FILE` → fail-fast). The demo certificate is instead a **container property**:
the image generates one with `keytool` at build time in `/app/default-certs/server.keystore`
(alias `server-cert`, password `water.`).

Entrypoint behavior:
- if `WATER_KEYSTORE_FILE` **is set** → that keystore is used (plain path, e.g. `/certs/server.keystore`);
- if `WATER_KEYSTORE_FILE` **is absent** → automatic fallback to the demo keystore `/app/default-certs/server.keystore`,
  with a warning in the logs.

This lets the container start directly for testing:

```bash
docker run -p 8080:8080 water-spring-app:3.0.0   # starts with the demo keystore, nothing to mount
```

> **Warning**: the demo keystore has password `water.` and is valid for development/test only.
> In production ALWAYS provide an external keystore via `WATER_KEYSTORE_FILE` (see below).
> The jar executed outside the container stays fail-fast: without `WATER_KEYSTORE_FILE` it does not start.

### External keystore (production)

Mount the keystore as a volume and point to it via an environment variable:

```bash
# External JKS keystore
docker run -d \
  -v /host/certs:/certs:ro \
  -e WATER_KEYSTORE_TYPE=jks \
  -e WATER_KEYSTORE_FILE=/certs/server.keystore \
  -e WATER_KEYSTORE_PASSWORD=strongpassword \
  -e WATER_KEYSTORE_ALIAS=server-cert \
  -e WATER_PRIVATE_KEY_PASSWORD=strongpassword \
  water-spring-app:latest
```

```bash
# PKCS12 keystore
docker run -d \
  -v /host/certs:/certs:ro \
  -e WATER_KEYSTORE_TYPE=pkcs12 \
  -e WATER_KEYSTORE_FILE=/certs/serverkeystore.p12 \
  -e WATER_KEYSTORE_PASSWORD=strongpassword \
  -e WATER_KEYSTORE_ALIAS=server-cert \
  -e WATER_PRIVATE_KEY_PASSWORD=strongpassword \
  water-spring-app:latest
```

### Generating a JKS keystore for production

```bash
keytool -genkeypair \
  -alias server-cert \
  -keyalg RSA \
  -keysize 2048 \
  -validity 365 \
  -keystore server.keystore \
  -storepass strongpassword \
  -keypass strongpassword \
  -dname "CN=myapp.example.com, OU=IT, O=MyOrg, L=City, ST=State, C=IT"
```

---

## 11. Health check

The Dockerfile configures an automatic TCP health check:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD bash -c 'exec 6<>/dev/tcp/localhost/${SERVER_PORT} && ...'
```

| Parameter | Value | Meaning |
|---|---|---|
| `--interval` | 30s | Check frequency |
| `--timeout` | 5s | Timeout for a single check |
| `--start-period` | 60s | Grace period at startup (Spring Boot takes ~30s) |
| `--retries` | 3 | Failed attempts before declaring the container `unhealthy` |

Check the health status in Docker:

```bash
docker inspect --format='{{.State.Health.Status}}' water-app
# → starting | healthy | unhealthy
```

---

## 12. Production best practices

### Security

- Set `WATER_TEST_MODE=false` (it is the default, verify it is not overridden)
- Use external keystores with certificates signed by a real CA
- Change all default passwords (`water.`, `sa`, etc.)
- The container already runs as the non-root `water` user — never run as `root`

### Database

- Use PostgreSQL or MySQL instead of in-memory HSQLDB
- Configure `spring.jpa.hibernate.ddl-auto=validate` or rely on Flyway/Liquibase
- Size `DB_POOL_SIZE` according to the expected load (default 10)

### JVM

```bash
java \
  -Xms512m -Xmx1024m \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=200 \
  -Djava.security.egd=file:/dev/./urandom \
  -jar app.jar
```

### Logging

Spring Boot writes to stdout by default. In a container environment, forward the logs to an aggregator (ELK, Loki, CloudWatch) via the Docker driver:

```bash
docker run -d \
  --log-driver=json-file \
  --log-opt max-size=50m \
  --log-opt max-file=3 \
  water-spring-app:latest
```

### Secrets management

Do not pass passwords as plaintext environment variables in versioned `docker-compose.yml` files. Use:
- **Docker Secrets** (`docker secret create`)
- **Kubernetes Secrets** (base64-encoded, with encryption at rest)
- **Vault** or dedicated secrets management systems

```yaml
# docker-compose with secrets
services:
  water-app:
    image: water-spring-app:latest
    secrets:
      - db_password
      - keystore_password
    environment:
      DB_PASSWORD_FILE: /run/secrets/db_password

secrets:
  db_password:
    external: true
  keystore_password:
    external: true
```
