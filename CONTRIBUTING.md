# Contributing

We welcome contributions! This project follows a standard GitHub workflow.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/<you>/trino-databricks-auth.git`
3. Create a branch: `git checkout -b feature/my-change`
4. Make your changes
5. Build and test: `mvn clean package`
6. Commit and push
7. Open a Pull Request

## Development Setup

**Prerequisites:**
- Java 21+ (JDK)
- Maven 3.8+

**Build:**
```bash
cd plugin
mvn clean package
```

The plugin JAR appears at `plugin/target/trino-databricks-auth-1.0.0.jar`.

## Design Principles

This plugin intentionally has **zero external dependencies** beyond the JDK and Trino SPI. This is a deliberate choice, not a shortcut:

- **No Guava**: We use `ConcurrentHashMap` instead of Guava's `LoadingCache`. Trino's plugin classloader isolates plugins, and Guava version conflicts between the plugin and Trino's internal Guava cause `ClassNotFoundException` at runtime.
- **No Jackson**: We use regex to parse a single JSON field (`userName`) from the SCIM response. Adding a full JSON library for one field extraction adds risk for no benefit.
- **No shading**: Since there are no external dependencies, we don't need maven-shade-plugin. The JAR is tiny and clean.

If you need to add a dependency, consider:
1. Can you use a JDK class instead?
2. Will it conflict with Trino's internal classloader?
3. Is it worth the added complexity for this narrow use case?

## Code Style

- Follow existing code formatting (Trino-style braces)
- Add Javadoc for public methods
- Use `java.util.logging` (not SLF4J) to avoid dependency conflicts

## Testing

Currently tested manually against Trino 476 on EMR. If you're contributing automated tests:
- Unit tests with mocked HTTP responses are welcome
- Integration tests should document their Trino version requirements

## Reporting Issues

Please include:
- Trino version
- Java version (both build and runtime)
- Deployment environment (EMR, Kubernetes, bare metal)
- Relevant Trino server.log entries
