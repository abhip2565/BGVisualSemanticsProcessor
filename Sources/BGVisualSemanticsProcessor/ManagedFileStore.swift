import Foundation

/// Manages temporary files written during enqueue of `.data` sources.
actor ManagedFileStore {
    nonisolated let rootDirectory: URL
    
    init(directoryName: String) throws {
        let cachesURL = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        self.rootDirectory = cachesURL.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent("temp", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private nonisolated func createRootDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    /// Writes data atomically to a new managed file.
    /// - Returns: The absolute path to the written file.
    func writeData(_ data: Data, suggestedExtension: String) throws -> String {
        try createRootDirectoryIfNeeded() // Ensure it exists in case caches were purged
        
        let filename = UUID().uuidString + (suggestedExtension.isEmpty ? "" : ".\(suggestedExtension)")
        let fileURL = rootDirectory.appendingPathComponent(filename)
        
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            throw VisualSemanticsError.storageFailure(reason: "Failed to write managed data to \(fileURL.path): \(error)")
        }
    }
    
    /// Deletes a managed file at the given path.
    func deleteFile(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    
    /// Sweeps the managed directory and deletes any files not present in the referenced set.
    func sweepOrphans(referencedPaths: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(at: rootDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        
        for case let fileURL as URL in enumerator {
            if !referencedPaths.contains(fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
