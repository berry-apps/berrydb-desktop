import BerryDBMCP
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
        let expected = HelperArguments(project: project, storePath: "/tmp/store.sqlite")

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
                == HelperArguments(project: project, storePath: nil)
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
        #expect(throws: HelperArgumentsError.unknown("--store-path=/tmp/store.sqlite")) {
            try HelperArguments.parse(["--store-path=/tmp/store.sqlite"])
        }
        #expect(throws: HelperArgumentsError.unknown("stray")) {
            try HelperArguments.parse(["--project", project.uuidString, "stray"])
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
        #expect(throws: HelperArgumentsError.repeated("--store-path")) {
            try HelperArguments.parse(["--store-path", "/a.sqlite", "--store-path", "/b.sqlite"])
        }
    }

    @Test
    func projectMustBeAUUID() {
        #expect(throws: HelperArgumentsError.invalidProject) {
            try HelperArguments.parse(["--project", "shop"])
        }
        #expect(throws: HelperArgumentsError.invalidProject) {
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
        #expect(HelperArgumentsError.missingValue("--project").description == "missing value for --project")
        #expect(HelperArgumentsError.repeated("--project").description == "--project given more than once")
        #expect(HelperArgumentsError.invalidProject.description == "--project expects a project UUID")
        #expect(HelperArgumentsError.relativeStorePath.description == "--store-path expects an absolute path")
    }
}
