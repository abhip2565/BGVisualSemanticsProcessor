import Foundation
import UIKit

/// Actor responsible for managing the specimen data and local image storage.
actor SpecimenStore {
    private var specimens: [String: Specimen] = [:]
    private let imagesDirectory: URL
    
    init() throws {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.imagesDirectory = cachesURL.appendingPathComponent("SemanticExplorer/images", isDirectory: true)
        
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }
    
    func add(_ specimen: Specimen, imageData: Data) throws {
        let fileURL = imagesDirectory.appendingPathComponent("\(specimen.id).jpg")
        try imageData.write(to: fileURL, options: .atomic)
        specimens[specimen.id] = specimen
    }
    
    func update(_ specimen: Specimen) {
        specimens[specimen.id] = specimen
    }
    
    func get(id: String) -> Specimen? {
        specimens[id]
    }
    
    func all() -> [Specimen] {
        Array(specimens.values).sorted { $0.createdAt > $1.createdAt }
    }
    
    func remove(id: String) {
        specimens.removeValue(forKey: id)
        let fileURL = imagesDirectory.appendingPathComponent("\(id).jpg")
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func clear() {
        specimens.removeAll()
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }
    
    func imageURL(for id: String) -> URL {
        imagesDirectory.appendingPathComponent("\(id).jpg")
    }
}
