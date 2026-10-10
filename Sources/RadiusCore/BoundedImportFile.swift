// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Read only the selected regular file, with the limit enforced on its actual
/// bytes even if it grows after opening. Pipes and symbolic links are rejected.
public enum BoundedImportFile {
    public enum Kind: Sendable {
        case bookmarks, setup, module
        fileprivate var label: String {
            switch self { case .bookmarks: "bookmarks HTML"; case .setup: "setup JSON"; case .module: "module" }
        }
    }
    public static func read(_ url: URL, maximumBytes: Int, kind: Kind) throws -> Data {
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max else {
            throw ValidationError("Choose a local \(kind.label) file within its size limit.")
        }
        // Opening nonblocking prevents a renamed pipe from hanging the picker;
        // fstat checks the descriptor actually read, rather than earlier metadata.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw ValidationError("Choose a readable, regular \(kind.label) file. Symbolic links are not supported.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              UInt32(status.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG), status.st_size >= 0 else {
            throw ValidationError("Choose a regular \(kind.label) file. Folders and streams are not supported.")
        }
        let size: String
        if maximumBytes.isMultiple(of: 1024 * 1024) { size = "\(maximumBytes / (1024 * 1024)) MB" }
        else if maximumBytes.isMultiple(of: 1024) { size = "\(maximumBytes / 1024) KB" }
        else { size = "\(maximumBytes) bytes" }
        let tooLarge = ValidationError("The \(kind.label) file must contain at most \(size).")
        guard status.st_size <= maximumBytes else { throw tooLarge }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw tooLarge }
        }
        return data
    }
}
