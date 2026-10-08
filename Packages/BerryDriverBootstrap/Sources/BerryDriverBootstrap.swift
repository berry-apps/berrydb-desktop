import BerryDataSourceKit
import BerryDriverDynamoDB
import BerryDriverElasticsearch
import BerryDriverKit
import BerryDriverMongo
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverQdrant
import BerryDriverRedis
import BerryDriverSQLite
import BerryDriverSQLServer
import BerryKeyValueKit

/// The deterministic result of registering BerryDB's built-in drivers.
public struct BerryDriverRegistration: Equatable, Sendable {
    public let sql: [DriverID]
    public let dataSource: [DriverID]
    public let keyValue: [DriverID]
}

/// Injectable registration operations used to verify executable composition
/// roots without sharing the process-global registries between tests.
public struct BerryDriverRegistrar {
    public let registerSQL: (any DatabaseDriver.Type) -> Void
    public let registerDataSource: (any DataSourceDriver.Type) -> Void
    public let registerKeyValue: (any KeyValueDriver.Type) -> Void

    public init(
        registerSQL: @escaping (any DatabaseDriver.Type) -> Void,
        registerDataSource: @escaping (any DataSourceDriver.Type) -> Void,
        registerKeyValue: @escaping (any KeyValueDriver.Type) -> Void
    ) {
        self.registerSQL = registerSQL
        self.registerDataSource = registerDataSource
        self.registerKeyValue = registerKeyValue
    }

    public static var live: BerryDriverRegistrar {
        BerryDriverRegistrar(
            registerSQL: DriverRegistry.register,
            registerDataSource: DataSourceRegistry.register,
            registerKeyValue: KeyValueRegistry.register
        )
    }
}

/// Registers the concrete drivers shared by BerryDB's app and MCP executable.
///
/// This composition module intentionally owns concrete-driver knowledge so
/// `BerryCore` remains dependent only on driver contracts. Registration is
/// explicit and idempotent; no runtime plugin discovery is performed.
public enum BerryDriverBootstrap {
    @discardableResult
    public static func registerAll(
        using registrar: BerryDriverRegistrar = .live
    ) -> BerryDriverRegistration {
        let sqlDrivers: [any DatabaseDriver.Type] = [
            SQLiteDriver.self,
            PostgresDriver.self,
            MySQLDriver.self,
            DynamoDBDriver.self,
            SQLServerDriver.self,
        ]
        let dataSourceDrivers: [any DataSourceDriver.Type] = [
            QdrantDriver.self,
            MongoDriver.self,
            ElasticsearchDriver.self,
        ]
        let keyValueDrivers: [any KeyValueDriver.Type] = [RedisDriver.self]

        sqlDrivers.forEach(registrar.registerSQL)
        dataSourceDrivers.forEach(registrar.registerDataSource)
        keyValueDrivers.forEach(registrar.registerKeyValue)

        return BerryDriverRegistration(
            sql: sqlDrivers.map { $0.id },
            dataSource: dataSourceDrivers.map { $0.id },
            keyValue: keyValueDrivers.map { $0.id }
        )
    }
}
