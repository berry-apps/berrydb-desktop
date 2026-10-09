import BerryDBMCP
import BerryMCP
import Foundation
import Testing

struct HelperArgumentsTests {
    private let project = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test
    func noArgumentsSelectsNothingExplicitly() throws {
        #expect(try HelperArguments.parse([]) == HelperArguments(project: nil, storePath: nil))
    }

    @Test
    func projectAndStorePathAreParsedInEitherOrder() throws {
        let expected = HelperArguments(project: .id(project), storePath: "/tmp/store.sqlite")

        #expect(
            try HelperArguments.parse(["--project", project.uuidString, "--store-path", "/tmp/store.sqlite"])
                == expected
        )
        #expect(
            try HelperArguments.parse(["--store-path", "/tmp/store.sqlite", "--project", project.uuidString])
                == expected
        )
    }

    @Test
    func eachFlagIsOptional() throws {
        #expect(
            try HelperArguments.parse(["--project", project.uuidString.lowercased()])
                == HelperArguments(project: .id(project), storePath: nil)
        )
        #expect(
            try HelperArguments.parse(["--store-path", "/var/store.sqlite"])
                == HelperArguments(project: nil, storePath: "/var/store.sqlite")
        )
    }

    @Test
    func unknownFlagIsRejected() {
        #expect(throws: HelperArgumentsError.unknown("--verbose")) {
            try HelperArguments.parse(["--verbose"])
        }
        #expect(throws: HelperArgumentsError.unknown("-v")) {
            try HelperArguments.parse(["-v"])
        }
    }

    /// An `=` form or a stray value may carry a store path; the error keeps
    /// only the flag name, or nothing of a positional argument.
    @Test
    func rejectedArgumentsNeverCarryTheirValue() {
        #expect(throws: HelperArgumentsError.unknown("--store-path=")) {
            try HelperArguments.parse(["--store-path=/Users/me/store.sqlite"])
        }
        #expect(throws: HelperArgumentsError.positional) {
            try HelperArguments.parse(["--project", project.uuidString, "/Users/me/store.sqlite"])
        }
    }

    /// A value written straight after a flag, with no `=` or space, is cut
    /// off at the first character that cannot be part of a flag name.
    @Test
    func valueAttachedToAFlagIsNeverEchoed() {
        #expect(throws: HelperArgumentsError.unknown("--store-path")) {
            try HelperArguments.parse(["--store-path/Users/me/store.sqlite"])
        }
        #expect(throws: HelperArgumentsError.unknown("-s")) {
            try HelperArguments.parse(["-s/Users/me/store.sqlite"])
        }
        #expect(throws: HelperArgumentsError.unknown("--store-path=")) {
            try HelperArguments.parse(["--store-path=~/store.sqlite"])
        }
    }

    @Test
    func flagWithoutValueIsRejected() {
        #expect(throws: HelperArgumentsError.missingValue("--project")) {
            try HelperArguments.parse(["--project"])
        }
        #expect(throws: HelperArgumentsError.missingValue("--store-path")) {
            try HelperArguments.parse(["--project", project.uuidString, "--store-path"])
        }
    }

    @Test
    func repeatedFlagIsRejected() {
        #expect(throws: HelperArgumentsError.repeated("--project")) {
            try HelperArguments.parse(["--project", project.uuidString, "--project", UUID().uuidString])
        }
        #expect(throws: HelperArgumentsError.repeated("--project")) {
            try HelperArguments.parse(["--project", "Billing", "--project", "Ledger"])
        }
        #expect(throws: HelperArgumentsError.repeated("--project")) {
            try HelperArguments.parse(["--project", "Billing", "--project", project.uuidString])
        }
        #expect(throws: HelperArgumentsError.repeated("--store-path")) {
            try HelperArguments.parse(["--store-path", "/a.sqlite", "--store-path", "/b.sqlite"])
        }
    }

    /// A value `UUID(uuidString:)` accepts is an ID, in either case and
    /// with surrounding whitespace; anything else is a name, trimmed.
    @Test
    func projectIsAnIDWhenItParsesAsAUUIDAndANameOtherwise() throws {
        func parsed(_ value: String) throws -> MCPProjectReference? {
            try HelperArguments.parse(["--project", value]).project
        }
        #expect(try parsed(project.uuidString) == .id(project))
        #expect(try parsed(project.uuidString.lowercased()) == .id(project))
        #expect(try parsed(" \(project.uuidString)\n") == .id(project))
        #expect(try parsed("shop") == .name("shop"))
        #expect(try parsed("  Shop Ops \n") == .name("Shop Ops"))
        #expect(try parsed("6F9619FF-8B86-D011-B42D") == .name("6F9619FF-8B86-D011-B42D"))
    }

    @Test
    func projectNameMustNotBeBlank() {
        #expect(throws: HelperArgumentsError.invalidProject) {
            try HelperArguments.parse(["--project", ""])
        }
        #expect(throws: HelperArgumentsError.invalidProject) {
            try HelperArguments.parse(["--project", " \t\n"])
        }
    }

    /// The value after `--project` is taken as given, even when it looks
    /// like a flag; what follows it is then rejected as a stray argument.
    @Test
    func aFlagAfterProjectIsTakenAsItsValue() {
        #expect(throws: HelperArgumentsError.positional) {
            try HelperArguments.parse(["--project", "--store-path", "/tmp/store.sqlite"])
        }
    }

    @Test
    func storePathMustBeAbsolute() {
        #expect(throws: HelperArgumentsError.relativeStorePath) {
            try HelperArguments.parse(["--store-path", "store.sqlite"])
        }
        #expect(throws: HelperArgumentsError.relativeStorePath) {
            try HelperArguments.parse(["--store-path", "~/store.sqlite"])
        }
        #expect(throws: HelperArgumentsError.relativeStorePath) {
            try HelperArguments.parse(["--store-path", ""])
        }
    }

    @Test
    func errorMessagesNameTheOffendingFlag() {
        #expect(HelperArgumentsError.unknown("--verbose").description == "unknown argument '--verbose'")
        #expect(HelperArgumentsError.positional.description == "unexpected positional argument")
        #expect(HelperArgumentsError.missingValue("--project").description == "missing value for --project")
        #expect(HelperArgumentsError.repeated("--project").description == "--project given more than once")
        #expect(HelperArgumentsError.invalidProject.description == "--project expects a project UUID or name")
        #expect(HelperArgumentsError.relativeStorePath.description == "--store-path expects an absolute path")
    }
}
