import Foundation
import Testing
@testable import AletheFoundation

@Suite struct JSONCTests {
    @Test func stripsCommentsAndTrailingCommas() throws {
        let source = """
        // header
        { /* block
          comment */ "a": "http://x.y/*not*/ // kept", "b": [1, 2, /* c */ ], "c": {"d": "\\"q\\"",  // tail
        },
        }
        """
        let object = try JSONSerialization.jsonObject(with: Data(JSONC.strip(source).utf8)) as? [String: Any]
        #expect(object?["a"] as? String == "http://x.y/*not*/ // kept")
        #expect(object?["b"] as? [Int] == [1, 2])
        #expect((object?["c"] as? [String: String])?["d"] == "\"q\"")
    }

    @Test func leavesPlainJSONAndEscapedQuotesAlone() {
        let source = #"{"a": "x\\", "b": "// no", "c": [1,2]}"#
        #expect(JSONC.strip(source) == source)
        #expect(JSONC.strip(Data(source.utf8)) == Data(source.utf8))
    }

    @Test func dropsCommentAtEndOfFileWithoutNewline() {
        #expect(JSONC.strip("{} // end") == "{} ")
        #expect(JSONC.strip("{} /* open") == "{} ")
    }
}
