import Foundation

enum ToolError: LocalizedError {
    case failed(tool: String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .failed(let tool, let status, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr.prefix(200))"
            return "\(tool) failed (exit \(status))\(detail)"
        }
    }
}

/// Locates and runs the external optimizer binaries (the same engines
/// ImageOptim bundles). Looked up once per launch from the app bundle's
/// Resources/bin, then the usual Homebrew / MacPorts locations.
enum Tools {

    private static let searchPaths: [URL] = {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("bin", isDirectory: true))
            dirs.append(resources)
        }
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))       // Apple Silicon Homebrew
        dirs.append(URL(fileURLWithPath: "/usr/local/bin"))          // Intel Homebrew
        dirs.append(URL(fileURLWithPath: "/opt/local/bin"))          // MacPorts
        return dirs
    }()

    static let pngquant  = find("pngquant")
    static let oxipng    = find("oxipng")
    static let optipng   = find("optipng")
    static let jpegoptim = find("jpegoptim")
    static let gifsicle  = find("gifsicle")
    static let avifenc   = find("avifenc")

    static func find(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = dir.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @discardableResult
    static func run(
        _ tool: URL,
        _ arguments: [String],
        allowedExitCodes: Set<Int32> = [0]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        // Drain stderr before waiting so a chatty tool can never deadlock the pipe.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let status = process.terminationStatus
        guard allowedExitCodes.contains(status) else {
            let stderr = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ToolError.failed(tool: tool.lastPathComponent, status: status, stderr: stderr)
        }
        return status
    }

    // MARK: - Availability report for the UI

    struct Availability {
        let name: String
        let url: URL?
        let brewFormula: String
    }

    static let all: [Availability] = [
        Availability(name: "pngquant",  url: pngquant,  brewFormula: "pngquant"),
        Availability(name: "oxipng",    url: oxipng,    brewFormula: "oxipng"),
        Availability(name: "jpegoptim", url: jpegoptim, brewFormula: "jpegoptim"),
        Availability(name: "gifsicle",  url: gifsicle,  brewFormula: "gifsicle"),
        Availability(name: "avifenc",   url: avifenc,   brewFormula: "libavif"),
    ]

    static var missingFormulae: [String] {
        all.filter { $0.url == nil }.map(\.brewFormula)
    }
}
