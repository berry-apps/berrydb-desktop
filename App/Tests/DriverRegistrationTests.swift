import BerryDriverBootstrap
import Testing
@testable import BerryApp

struct DriverRegistrationTests {
    @Test
    func appCompositionRegistersTheExactDriverFamilies() {
        var sql: [String] = []
        var dataSource: [String] = []
        var keyValue: [String] = []
        let registrar = BerryDriverRegistrar(
            registerSQL: { sql.append($0.id.rawValue) },
            registerDataSource: { dataSource.append($0.id.rawValue) },
            registerKeyValue: { keyValue.append($0.id.rawValue) }
        )

        let registered = BerryDBAppComposition.registerDrivers(using: registrar)

        #expect(sql == ["sqlite", "postgres", "mysql", "dynamodb", "sqlserver"])
        #expect(dataSource == ["qdrant", "mongodb", "elasticsearch"])
        #expect(keyValue == ["redis"])
        #expect(registered.sql.map(\.rawValue) == sql)
        #expect(registered.dataSource.map(\.rawValue) == dataSource)
        #expect(registered.keyValue.map(\.rawValue) == keyValue)
    }
}
