import Darwin
import Foundation

public enum VoiceDownloadError: Codable, Equatable, LocalizedError, Sendable {
    case invalidManifest
    case invalidFile
    case serverResponse(Int)
    case connection
    case insufficientStorage
    case storage
    case unavailable

    public static func classify(_ error: any Error) -> Self {
        if let downloadError = error as? Self { return downloadError }
        let failure = error as NSError
        switch failure.domain {
        case NSURLErrorDomain: return .connection
        case NSCocoaErrorDomain:
            return failure.code == NSFileWriteOutOfSpaceError ? .insufficientStorage : .storage
        case NSPOSIXErrorDomain where failure.code == Int(ENOSPC): return .insufficientStorage
        case NSPOSIXErrorDomain: return .storage
        default: return .unavailable
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "This voice is unavailable. Please update the app and try again."
        case .invalidFile: "The voice download could not be verified. Please try again."
        case .connection: "The voice could not be downloaded. Check your connection and try again."
        case .serverResponse, .unavailable: "This voice is unavailable."
        case .insufficientStorage: CocoaError(.fileWriteOutOfSpace).localizedDescription
        case .storage: "This voice is unavailable."
        }
    }
}
