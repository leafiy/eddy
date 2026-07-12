import AppKit
import CryptoKit
import Foundation
import LeafiyUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

enum QuickShareProvider: String, CaseIterable {
    case s3Compatible = "s3_compatible"
    case aliyunOSS = "aliyun_oss"
    case tencentCOS = "tencent_cos"
    case awsS3 = "aws_s3"
    case cloudflareR2 = "cloudflare_r2"

    var label: String {
        switch self {
        case .s3Compatible: return L("S3-compatible")
        case .aliyunOSS: return L("Alibaba Cloud OSS")
        case .tencentCOS: return L("Tencent Cloud COS")
        case .awsS3: return L("AWS S3")
        case .cloudflareR2: return L("Cloudflare R2")
        }
    }
}

/// Quick Share storage account. Persisted as individual UserDefaults keys,
/// matching eddy's other settings (@AppStorage in the Settings pane, direct
/// reads at action time).
struct QuickShareSettings {
    enum Keys {
        static let provider = "quickShareProvider"
        static let endpointURL = "quickShareEndpointURL"
        static let region = "quickShareRegion"
        static let bucket = "quickShareBucket"
        static let accessKeyID = "quickShareAccessKeyID"
        static let secretAccessKey = "quickShareSecretAccessKey"
        static let keyPrefix = "quickShareKeyPrefix"
    }

    var provider: QuickShareProvider
    var endpointURL: String
    var region: String
    var bucket: String
    var accessKeyID: String
    var secretAccessKey: String
    var keyPrefix: String

    static let defaultKeyPrefix = "eddy"

    static func load(from defaults: UserDefaults = .standard) -> QuickShareSettings {
        QuickShareSettings(
            provider: QuickShareProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .s3Compatible,
            endpointURL: defaults.string(forKey: Keys.endpointURL) ?? "",
            region: defaults.string(forKey: Keys.region) ?? "",
            bucket: defaults.string(forKey: Keys.bucket) ?? "",
            accessKeyID: defaults.string(forKey: Keys.accessKeyID) ?? "",
            secretAccessKey: defaults.string(forKey: Keys.secretAccessKey) ?? "",
            keyPrefix: defaults.string(forKey: Keys.keyPrefix) ?? defaultKeyPrefix
        )
    }

    var isConfigured: Bool {
        !endpointURL.trimmed.isEmpty &&
        !region.trimmed.isEmpty &&
        !bucket.trimmed.isEmpty &&
        !accessKeyID.trimmed.isEmpty &&
        !secretAccessKey.trimmed.isEmpty
    }
}

// MARK: - Errors

enum QuickShareError: LocalizedError {
    case notConfigured
    case invalidEndpoint
    case unreadableFile(String)
    case uploadFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L("Set up Quick Share storage in Settings first.")
        case .invalidEndpoint:
            return L("The Quick Share endpoint URL is invalid.")
        case .unreadableFile(let name):
            return String(format: L("Quick Share can’t read the file: %@"), name)
        case .uploadFailed(let status, let body):
            if body.isEmpty {
                return String(format: L("Quick Share upload failed with HTTP %d."), status)
            }
            return String(format: L("Quick Share upload failed with HTTP %1$d: %2$@"), status, body)
        }
    }
}

// MARK: - Service

/// Uploads a compressed file to S3-compatible object storage with a SigV4
/// PUT and returns the public object URL. Ported from fifi's
/// QuickShareService, reduced to the single-file case.
enum QuickShareService {
    static func share(fileURL: URL, settings: QuickShareSettings, session: URLSession = .shared) async throws -> String {
        guard settings.isConfigured else { throw QuickShareError.notConfigured }
        let config = try UploadConfig(settings: settings)

        guard let data = try? Data(contentsOf: fileURL) else {
            throw QuickShareError.unreadableFile(fileURL.lastPathComponent)
        }
        let ext = sanitizedExtension(fileURL.pathExtension)
        let contentType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let key = objectKey(for: fileURL, ext: ext, prefix: config.keyPrefix)

        var request = URLRequest(url: config.objectURL(for: key))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

        let signedHeaders = S3Signer.signedHeaders(
            method: "PUT",
            url: request.url!,
            body: data,
            accessKeyID: config.accessKeyID,
            secretAccessKey: config.secretAccessKey,
            region: config.region
        )
        for (field, value) in signedHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (body, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: body.prefix(400), encoding: .utf8) ?? ""
            throw QuickShareError.uploadFailed(http.statusCode, text)
        }
        return config.objectURL(for: key).absoluteString
    }

    private static func objectKey(for fileURL: URL, ext: String, prefix: String) -> String {
        let timestamp = timestampFormatter.string(from: Date())
        let base = sanitized(fileURL.deletingPathExtension().lastPathComponent)
        let token = UUID().uuidString.prefix(8).lowercased()
        let filename = "\(timestamp)-\(token)-\(base).\(ext)"
        guard !prefix.isEmpty else { return filename }
        return "\(prefix)/\(filename)"
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

private struct UploadConfig {
    let endpoint: URL
    let region: String
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String
    let keyPrefix: String
    let provider: QuickShareProvider

    init(settings: QuickShareSettings) throws {
        let endpointText = Self.normalizedEndpointText(settings.endpointURL)
        guard let endpoint = URL(string: endpointText), endpoint.scheme != nil, endpoint.host != nil else {
            throw QuickShareError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.region = settings.region.trimmed
        self.bucket = settings.bucket.trimmed
        self.accessKeyID = settings.accessKeyID.trimmed
        self.secretAccessKey = settings.secretAccessKey
        self.keyPrefix = settings.keyPrefix.pathPrefix
        self.provider = settings.provider
    }

    private static func normalizedEndpointText(_ value: String) -> String {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return trimmed }
        guard trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) == nil else {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    func objectURL(for key: String) -> URL {
        if isBucketScopedEndpoint {
            return endpoint.appendingObjectKey(key)
        }
        if usesVirtualHostedStyle {
            return endpoint.withBucketHost(bucket).appendingObjectKey(key)
        }
        return endpoint.appendingPathComponent(bucket).appendingObjectKey(key)
    }

    private var usesVirtualHostedStyle: Bool {
        switch provider {
        case .aliyunOSS, .tencentCOS, .awsS3, .cloudflareR2:
            return true
        case .s3Compatible:
            return false
        }
    }

    private var isBucketScopedEndpoint: Bool {
        guard let host = endpoint.host?.lowercased(), !bucket.isEmpty else { return false }
        let normalizedBucket = bucket.lowercased()
        if host == normalizedBucket || host.hasPrefix("\(normalizedBucket).") {
            return true
        }
        return endpoint.path
            .split(separator: "/")
            .last
            .map { String($0).lowercased() == normalizedBucket } ?? false
    }
}

// MARK: - AWS Signature V4

private enum S3Signer {
    static func signedHeaders(
        method: String,
        url: URL,
        body: Data,
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        now: Date = Date()
    ) -> [String: String] {
        let payloadHash = sha256Hex(body)
        let amzDate = amzDateFormatter.string(from: now)
        let date = shortDateFormatter.string(from: now)
        let host = url.hostWithPort

        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = [
            "host:\(host)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)"
        ].joined(separator: "\n") + "\n"
        let canonicalRequest = [
            method,
            canonicalURI(url.path),
            url.query ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = signingKey(secretAccessKey: secretAccessKey, date: date, region: region)
        let signature = hmacHex(Data(stringToSign.utf8), key: signingKey)
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return [
            "Host": host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate,
            "Authorization": authorization
        ]
    }

    private static func signingKey(secretAccessKey: String, date: String, region: String) -> SymmetricKey {
        let dateKey = hmac(Data(date.utf8), key: SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8)))
        let regionKey = hmac(Data(region.utf8), key: SymmetricKey(data: dateKey))
        let serviceKey = hmac(Data("s3".utf8), key: SymmetricKey(data: regionKey))
        let signingKey = hmac(Data("aws4_request".utf8), key: SymmetricKey(data: serviceKey))
        return SymmetricKey(data: signingKey)
    }

    private static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hmacHex(_ data: Data, key: SymmetricKey) -> String {
        hmac(data, key: key).hexString
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    private static func canonicalURI(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.map { percentEncode(String($0)) }.joined(separator: "/")
    }

    private static func percentEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var output = ""
        for scalar in value.unicodeScalars {
            if unreserved.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    output += String(format: "%%%02X", byte)
                }
            }
        }
        return output
    }

    private static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

// MARK: - Settings pane

struct EddyShareSettingsPane: View {
    @AppStorage(QuickShareSettings.Keys.provider) private var providerRaw = QuickShareProvider.s3Compatible.rawValue
    @AppStorage(QuickShareSettings.Keys.endpointURL) private var endpointURL = ""
    @AppStorage(QuickShareSettings.Keys.region) private var region = ""
    @AppStorage(QuickShareSettings.Keys.bucket) private var bucket = ""
    @AppStorage(QuickShareSettings.Keys.accessKeyID) private var accessKeyID = ""
    @AppStorage(QuickShareSettings.Keys.secretAccessKey) private var secretAccessKey = ""
    @AppStorage(QuickShareSettings.Keys.keyPrefix) private var keyPrefix = QuickShareSettings.defaultKeyPrefix

    private var providerBinding: Binding<QuickShareProvider> {
        Binding {
            QuickShareProvider(rawValue: providerRaw) ?? .s3Compatible
        } set: { newValue in
            providerRaw = newValue.rawValue
        }
    }

    var body: some View {
        SettingsPane(L("Share"), systemImage: "square.and.arrow.up", height: 560) {
            Section(L("Quick Share")) {
                Picker(L("Provider"), selection: providerBinding) {
                    ForEach(QuickShareProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                Text(L("Quick Share uploads the compressed file to your public object storage and copies the public URL to the clipboard."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("Storage account")) {
                TextField(
                    L("Endpoint URL"),
                    text: $endpointURL,
                    prompt: Text(verbatim: "https://s3.us-west-2.amazonaws.com")
                )
                TextField(L("Region"), text: $region, prompt: Text(verbatim: "us-west-2"))
                TextField(L("Bucket"), text: $bucket, prompt: Text(verbatim: "my-public-bucket"))
                TextField(L("Access Key"), text: $accessKeyID)
                SecureField(L("Secret Key"), text: $secretAccessKey)
            }
            Section(L("Public URL")) {
                TextField(L("Object prefix"), text: $keyPrefix, prompt: Text(verbatim: QuickShareSettings.defaultKeyPrefix))
                Text(L("Eddy builds the public URL from Endpoint, Bucket, Object prefix, and the generated filename."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("Quick guide")) {
                Text(L("1. Create a bucket or prefix that is public-read.\n2. Create a least-privileged key that can PutObject only to that bucket or prefix.\n3. Fill Endpoint, Region, Bucket, Access Key, Secret Key, and Object prefix.\nExamples: Alibaba OSS endpoint https://oss-cn-hangzhou.aliyuncs.com or https://<bucket>.oss-cn-hangzhou.aliyuncs.com; Tencent COS endpoint https://cos.ap-shanghai.myqcloud.com or https://<bucket>.cos.ap-shanghai.myqcloud.com; AWS S3 endpoint https://s3.us-west-2.amazonaws.com; Cloudflare R2 endpoint https://<account-id>.r2.cloudflarestorage.com with region auto."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Small helpers

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var pathPrefix: String {
        trimmed
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

private extension URL {
    func withBucketHost(_ bucket: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let host = components.host,
              !bucket.isEmpty else {
            return self
        }
        components.host = "\(bucket).\(host)"
        return components.url ?? self
    }

    func appendingObjectKey(_ key: String) -> URL {
        key.split(separator: "/").reduce(self) { url, segment in
            url.appendingPathComponent(String(segment))
        }
    }

    var hostWithPort: String {
        guard let host else { return "" }
        if let port {
            return "\(host):\(port)"
        }
        return host
    }
}
