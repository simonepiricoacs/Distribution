# baseLib — BASE classpath JARs for LOCAL runs (Spring/system classloader)

JARs in this folder are put on the **system/launch classpath** — the SAME classloader as Spring —
when the app is started **locally** via the Gradle task:

```
./gradlew :Distribution-spring-app:runLocal
```

They mirror the container's `/baselib`, but **only for local execution**. They are NOT packaged:

- excluded from the Docker build context (`.dockerignore`), and
- added only to the `runLocal` task classpath (never to `sourceSets`/`shadowJar`),

so they never leak into the fat jar or the image. **Do not touch the Dockerfile for these** — in
Docker `/baselib` is auto-populated (the Dockerfile seeds `javax.servlet-api`, and the entrypoint
adds any `WATER_BASE_MODULES` at runtime), and `/extlib` is auto-populated from `WATER_MODULES`.

## What goes here

Libraries that Spring / Hibernate / Hikari must see at bean-creation time and that must NOT live in
the isolated `/extlib` child loader, e.g.:

- `javax.servlet-api` — the Water `*-service-spring` modules bundle JAX-RS/CXF controllers that
  carry a `@Context javax.servlet.http.HttpServletRequest` field (see Authentication #34/#37).
  Spring Boot 3 uses `jakarta.servlet`, so without the `javax` API on the classpath, introspecting
  the Spring controller (which extends the JAX-RS one) fails with
  `NoClassDefFoundError: javax/servlet/http/HttpServletRequest`. The field stays inert at runtime
  (the Spring controller reads the request via `RequestContextHolder`/jakarta).
- JDBC drivers, if you want them available for a local run without downloading them.

Module jars (Water `*-service-spring`) for a local run go in the sibling `extraLib/` folder instead
(WaterLauncher loads those into its isolated child classloader via `EXTRA_CLASSPATH_DIR`).
