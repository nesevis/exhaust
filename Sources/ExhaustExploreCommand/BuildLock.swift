import Foundation
#if canImport(WinSDK)
    import WinSDK
#elseif canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Holds an OS-owned lock for the campaign; process termination releases it too.
final class BuildLock {
    #if os(Windows)
        private let handle: HANDLE
    #else
        private let descriptor: Int32
    #endif

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("explore.lock").nativePath
        let busy = "Another explore command is using \(directory.nativePath). Wait for it to finish."
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
                let message = error == ERROR_SHARING_VIOLATION ? busy : "Cannot open the explore build lock (Windows error \(error))."
                throw CommandError(message)
            }
            handle = opened
        #else
            let opened = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard opened >= 0 else {
                throw CommandError("Cannot open the explore build lock (errno \(errno)).")
            }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                let error = errno
                close(opened)
                let message = error == EWOULDBLOCK || error == EAGAIN ? busy : "Cannot acquire the explore build lock (errno \(error))."
                throw CommandError(message)
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
