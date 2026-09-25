import Darwin
import Foundation

public enum FileOperationError: Error, Hashable, Sendable {
    case invalidName
    case alreadyExists
    case notFound
    case rootNotModifiable
    case failed(String)
}

/// Result of `moveToTrash`: when the volume has no Trash the UI confirms a permanent delete.
public enum TrashOutcome: Hashable, Sendable {
    case trashed(URL?)
    case trashUnavailable
}

/// Explorer file operations (upstream `rename_filesystem_entry` / `delete_filesystem_entry`).
public enum FileOperations {
    /// Returns the trimmed name, or throws when it is empty, `.`/`..`, holds a separator or NUL,
    /// or exceeds the 255-byte APFS limit.
    public static func validateName(_ name: String) throws(FileOperationError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\0"),
              trimmed.utf8.count <= 255
        else { throw .invalidName }
        return trimmed
    }

    private static func existing(_ url: URL) throws(FileOperationError) -> URL {
        let target = url.standardizedFileURL
        guard target.path != "/" else { throw .rootNotModifiable }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil
        guard exists || isLink else { throw .notFound }
        return target
    }

    private static func occupied(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Renames in place; a case-only rename of the same entry is allowed.
    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws(FileOperationError) -> URL {
        let target = try existing(url)
        let name = try validateName(newName)
        let destination = target.deletingLastPathComponent().appendingPathComponent(name)
        guard name != target.lastPathComponent else { return target }
        let caseOnly = name.lowercased() == target.lastPathComponent.lowercased()
        if occupied(destination), !caseOnly { throw .alreadyExists }
        guard Darwin.rename(target.path, destination.path) == 0 else {
            throw .failed(String(cString: strerror(errno)))
        }
        return destination
    }

    @discardableResult
    public static func createFile(named name: String, in directory: URL) throws(FileOperationError) -> URL {
        let destination = directory.standardizedFileURL.appendingPathComponent(try validateName(name))
        guard !occupied(destination) else { throw .alreadyExists }
        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
            throw .failed("could not create \(destination.lastPathComponent)")
        }
        return destination
    }

    @discardableResult
    public static func createFolder(named name: String, in directory: URL) throws(FileOperationError) -> URL {
        let destination = directory.standardizedFileURL.appendingPathComponent(try validateName(name))
        guard !occupied(destination) else { throw .alreadyExists }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw .failed(error.localizedDescription)
        }
        return destination
    }

    public static func moveToTrash(_ url: URL) throws(FileOperationError) -> TrashOutcome {
        let target = try existing(url)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
            return .trashed(resulting as URL?)
        } catch {
            if isTrashUnavailable(error) { return .trashUnavailable }
            throw .failed(error.localizedDescription)
        }
    }

    /// Errors meaning the volume has no Trash (network or read-only-for-trash volumes).
    public static func isTrashUnavailable(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSFeatureUnsupportedError
    }

    /// Permanent delete, used only after the user confirms when the Trash is unavailable.
    public static func deletePermanently(_ url: URL) throws(FileOperationError) {
        let target = try existing(url)
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw .failed(error.localizedDescription)
        }
    }
}
