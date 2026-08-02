import Foundation
import LeafiyUICore
import UniformTypeIdentifiers

enum QuickShareService {
    static func share(fileURL: URL, settings: QuickShareSettings, session: URLSession = .shared) async throws -> String {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw EddyQuickShareError.unreadableFile(fileURL.lastPathComponent)
        }

        let ext = sanitizedExtension(fileURL.pathExtension)
        let contentType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let filename = uploadFilename(for: fileURL, ext: ext)
        let uploader = QuickShareUploader(settings: settings, session: session)
        return try await uploader.upload(data: data, filename: filename, contentType: contentType).absoluteString
    }

    private static func uploadFilename(for fileURL: URL, ext: String) -> String {
        let timestamp = timestampFormatter.string(from: Date())
        let base = sanitized(fileURL.deletingPathExtension().lastPathComponent)
        let token = UUID().uuidString.prefix(8).lowercased()
        return "\(timestamp)-\(token)-\(base).\(ext)"
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_.")).nilIfEmpty ?? "image"
    }

    private static func sanitizedExtension(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let ext = String(value.unicodeScalars.filter { allowed.contains($0) }).lowercased()
        return ext.nilIfEmpty ?? "bin"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private enum EddyQuickShareError: LocalizedError {
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name):
            return String(format: L("Quick Share can’t read the file: %@"), name)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
