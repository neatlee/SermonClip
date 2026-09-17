import Foundation

enum AppResources {
    static func url(forResource name: String, withExtension ext: String?, subdirectory: String = "Resources") -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let root = Bundle.main.resourceURL else { return nil }
            let resources = root.appendingPathComponent("SermonCut_SermonCut.bundle")
                .appendingPathComponent(subdirectory)
            let file = resources.appendingPathComponent(name + (ext.map { "." + $0 } ?? ""))
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}
