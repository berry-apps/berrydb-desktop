# Third-Party Notices & Licenses

BerryDB incorporates or links to open-source software packages under various licenses. This document acknowledges and attributes these third-party components.

---

### 1. FreeTDS (libsybdb)
- **License:** GNU Lesser General Public License, version 2.1 (LGPL-2.1)
- **Project URL:** [https://www.freetds.org/](https://www.freetds.org/)
- **Notice:** BerryDB dynamically links `libsybdb` (FreeTDS DB-Library) at runtime to connect to Microsoft SQL Server. FreeTDS DB-Library is licensed under LGPL-2.1, and is used unmodified. See [`deploy/third-party-notices/LGPL-2.1.txt`](deploy/third-party-notices/LGPL-2.1.txt) and [`deploy/third-party-notices/NOTICE-FreeTDS.txt`](deploy/third-party-notices/NOTICE-FreeTDS.txt).
- **How LGPL-2.1 section 6 is satisfied:** BerryDB embeds its own copy of `libsybdb` rather than loading one already present on the user's system, and is signed with the macOS hardened runtime, whose library validation refuses a library signed by anyone else. Section 6(b) therefore does not apply. BerryDB relies on **6(a) and 6(d)**: the complete source of the work that uses the library is this repository, published under Apache-2.0, so anyone can modify `libsybdb`, rebuild, and run the result; and the complete source of the exact FreeTDS version shipped is published alongside every release, from the same place as the application download.
- **Pinned version:** the FreeTDS version is fixed in [`deploy/freetds-version.txt`](deploy/freetds-version.txt). `scripts/check-size.sh` fails the build if the library actually embedded is not that version, so what ships always matches the source offered.

### 2. sqlite-vec
- **License:** MIT License
- **Copyright:** (c) 2024 Alex Garcia
- **Project URL:** [https://github.com/asg017/sqlite-vec](https://github.com/asg017/sqlite-vec)
- **Notice:** Vendored in `Packages/BerryStore/Sources/CSQLiteVec` for vector search capabilities. Full license text located at [`Packages/BerryStore/Sources/CSQLiteVec/LICENSE`](Packages/BerryStore/Sources/CSQLiteVec/LICENSE).

### 3. Mermaid.js
- **License:** MIT License
- **Copyright:** (c) 2014 - 2024 Knut Sveidqvist and Mermaid Contributors
- **Project URL:** [https://github.com/mermaid-js/mermaid](https://github.com/mermaid-js/mermaid)
- **Notice:** Embedded minified asset located at `Packages/BerryUI/Sources/Resources/mermaid.min.js`.

### 4. GRDB.swift
- **License:** MIT License
- **Copyright:** (c) 2015-2024 Gwendal Roué
- **Project URL:** [https://github.com/groue/GRDB.swift](https://github.com/groue/GRDB.swift)

### 5. PostgresNIO
- **License:** MIT License
- **Copyright:** (c) 2019 Tanner Nelson
- **Project URL:** [https://github.com/vapor/postgres-nio](https://github.com/vapor/postgres-nio)

### 6. MySQLNIO
- **License:** MIT License
- **Copyright:** (c) 2023 Qutheory, LLC
- **Project URL:** [https://github.com/vapor/mysql-nio](https://github.com/vapor/mysql-nio)

### 7. Valkey-Swift
- **License:** Apache License 2.0
- **Copyright:** (c) 2024 Valkey-Swift contributors
- **Project URL:** [https://github.com/valkey-io/valkey-swift](https://github.com/valkey-io/valkey-swift)

### 8. Citadel (SSH Client)
- **License:** MIT License
- **Copyright:** (c) 2020 Joannis Orlandos
- **Project URL:** [https://github.com/orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel)

### 9. Sparkle Framework
- **License:** MIT / BSD Licenses
- **Copyright:** (c) 2006-2024 Andy Matuschak, Kornel Lesiński, and Sparkle Project Contributors
- **Project URL:** [https://github.com/sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)

### 10. Lucide Icons
- **License:** ISC License
- **Copyright:** (c) 2022-2024 Lucide Contributors
- **Project URL:** [https://lucide.dev/](https://lucide.dev/)

---

## Swift Package Dependencies

Resolved from `Package.resolved` and linked into the application binary. Each is
listed with the licence its own `LICENSE` file states.

### 11. Apache License 2.0

Full text: [https://www.apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

| Package | Copyright | Project URL |
| :--- | :--- | :--- |
| SwiftNIO | (c) 2017, 2018 The SwiftNIO Project | [apple/swift-nio](https://github.com/apple/swift-nio) |
| SwiftNIO SSL | (c) 2017, 2018 The SwiftNIO Project | [apple/swift-nio-ssl](https://github.com/apple/swift-nio-ssl) |
| SwiftNIO SSH | (c) The SwiftNIO Project authors | [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) |
| SwiftNIO Transport Services | (c) The SwiftNIO Project authors | [apple/swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) |
| Swift Crypto | (c) 2019 The SwiftCrypto Project | [apple/swift-crypto](https://github.com/apple/swift-crypto) |
| SwiftASN1 | (c) 2022 The SwiftASN1 Project | [apple/swift-asn1](https://github.com/apple/swift-asn1) |
| Swift Collections | (c) The Swift project authors | [apple/swift-collections](https://github.com/apple/swift-collections) |
| Swift Algorithms | (c) The Swift project authors | [apple/swift-algorithms](https://github.com/apple/swift-algorithms) |
| Swift Async Algorithms | (c) The Swift project authors | [apple/swift-async-algorithms](https://github.com/apple/swift-async-algorithms) |
| Swift Atomics | (c) The Swift project authors | [apple/swift-atomics](https://github.com/apple/swift-atomics) |
| Swift Numerics | (c) The Swift project authors | [apple/swift-numerics](https://github.com/apple/swift-numerics) |
| Swift System | (c) The Swift project authors | [apple/swift-system](https://github.com/apple/swift-system) |
| Swift Log | (c) 2018, 2019 The SwiftLog Project | [apple/swift-log](https://github.com/apple/swift-log) |
| Swift Metrics | (c) 2018, 2019 The SwiftMetrics Project | [apple/swift-metrics](https://github.com/apple/swift-metrics) |
| Swift Configuration | (c) 2025 The SwiftConfiguration Project | [apple/swift-configuration](https://github.com/apple/swift-configuration) |
| Swift Service Context | (c) 2024 The Swift Service Context Project | [apple/swift-service-context](https://github.com/apple/swift-service-context) |
| Swift Service Lifecycle | (c) 2019-2023 The ServiceLifecycle Project | [swift-server/swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) |
| Swift Distributed Tracing | (c) The Swift Distributed Tracing project authors | [apple/swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing) |

### 12. BigInt
- **License:** MIT License
- **Copyright:** (c) 2016-2017 Károly Lőrentey
- **Project URL:** [https://github.com/attaswift/BigInt](https://github.com/attaswift/BigInt)
