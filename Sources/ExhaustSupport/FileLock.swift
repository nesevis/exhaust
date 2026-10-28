import Foundation
#if canImport(WinSDK)
    import WinSDK
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Keeps file ownership unique until the owning scope ends; process termination also releases the operating system lock.
package struct FileLock: ~Copyable {
    /// Distinguishes contention from filesystem failures so callers can supply domain-specific guidance.
    package enum Failure: Error {
        case busy
        case operation(String)
    }

    #if os(Windows)
        private let handle: HANDLE
    #else
        private let descriptor: Int32
    #endif

    package init(lockFileURL: URL) throws(Failure) {
        do {
            try FileManager.default.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw .operation("Cannot create the lock directory: \(error)")
        }
        guard let path = lockFileURL.withUnsafeFileSystemRepresentation({ pointer in
            pointer.map { String(cString: $0) }
        }) else {
            throw Failure.operation("Cannot represent the file lock path.")
        }
        #if os(Windows)
            // Denying sharing makes opening the file an atomic, nonblocking lock. A nil SECURITY_ATTRIBUTES pointer keeps the handle out of children.
            let opened = path.withCString(encodedAs: UTF16.self) { widePath in
                CreateFileW(
                    widePath,
                    DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                    0,
                    nil,
                    DWORD(OPEN_ALWAYS),
                    DWORD(FILE_ATTRIBUTE_NORMAL),
                    nil
                )
            }
            guard let opened, opened != INVALID_HANDLE_VALUE else {
                let error = GetLastError()
                if error == ERROR_SHARING_VIOLATION {
                    throw .busy
                }
                throw .operation("Cannot open the file lock (Windows error \(error)).")
            }
            handle = opened
        #else
            let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard opened >= 0 else {
                throw Failure.operation("Cannot open the file lock (errno \(errno)).")
            }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                let error = errno
                close(opened)
                if error == EWOULDBLOCK || error == EAGAIN {
                    throw .busy
                }
                throw .operation("Cannot acquire the file lock (errno \(error)).")
            }
            descriptor = opened
        #endif
    }

    deinit {
        #if os(Windows)
            CloseHandle(handle)
        #else
            flock(descriptor, LOCK_UN)
            close(descriptor)
        #endif
    }
}

package extension FileLock.Failure {
    /// Explains the failure, using `busy` when another owner holds the lock.
    func message(busy: String) -> String {
        switch self {
            case .busy:
                busy
            case let .operation(message):
                message
        }
    }
}
