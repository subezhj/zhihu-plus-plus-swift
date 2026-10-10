import Foundation
import CryptoKit

struct OfflineQuestionManifest: Codable, Identifiable, Hashable, Sendable {
    let questionID: Int64
    let title: String
    let answerCount: Int
    let cachedAnswerCount: Int
    let totalByteSize: Int64
    let cachedAt: Date

    var id: Int64 { questionID }
}

struct OfflineQuestionPackage: Codable, Sendable {
    let manifest: OfflineQuestionManifest
    let question: QuestionDTO
    let answers: [AnswerDTO]
    let comments: [Int64: [CommentDTO]] // answerID -> 热门评论列表

    init(
        manifest: OfflineQuestionManifest,
        question: QuestionDTO,
        answers: [AnswerDTO],
        comments: [Int64: [CommentDTO]] = [:]
    ) {
        self.manifest = manifest
        self.question = question
        self.answers = answers
        self.comments = comments
    }

    enum CodingKeys: String, CodingKey {
        case manifest
        case question
        case answers
        case comments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(OfflineQuestionManifest.self, forKey: .manifest)
        question = try container.decode(QuestionDTO.self, forKey: .question)
        answers = try container.decode([AnswerDTO].self, forKey: .answers)
        comments = try container.decodeIfPresent([Int64: [CommentDTO]].self, forKey: .comments) ?? [:]
    }
}

actor OfflineStorageService {
    static let shared = OfflineStorageService()

    private let fileManager: FileManager
    private let baseDirectory: URL
    private let indexFileURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let root = rootURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseDirectory = root.appendingPathComponent("OfflineCache", isDirectory: true)
        self.indexFileURL = baseDirectory.appendingPathComponent("index.json")
        ensureBaseDirectoriesExist()
    }

    private func ensureBaseDirectoriesExist() {
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let questionsDir = baseDirectory.appendingPathComponent("questions", isDirectory: true)
        try? fileManager.createDirectory(at: questionsDir, withIntermediateDirectories: true)
        let imagesDir = baseDirectory.appendingPathComponent("images", isDirectory: true)
        try? fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - Manifest / Index Management

    func allManifests() -> [OfflineQuestionManifest] {
        guard let data = try? Data(contentsOf: indexFileURL),
              let manifests = try? JSONDecoder().decode([OfflineQuestionManifest].self, from: data)
        else {
            return []
        }
        return manifests.sorted { $0.cachedAt > $1.cachedAt }
    }

    private func saveManifests(_ manifests: [OfflineQuestionManifest]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifests) {
            try? data.write(to: indexFileURL, options: .atomic)
        }
    }

    func isQuestionCached(questionID: Int64) -> Bool {
        allManifests().contains { $0.questionID == questionID }
    }

    // MARK: - Package Read & Write

    private func questionDirectory(for questionID: Int64) -> URL {
        baseDirectory
            .appendingPathComponent("questions", isDirectory: true)
            .appendingPathComponent(String(questionID), isDirectory: true)
    }

    func save(package: OfflineQuestionPackage) throws {
        let dir = questionDirectory(for: package.manifest.questionID)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let packageURL = dir.appendingPathComponent("package.json")
        let data = try encoder.encode(package)
        try data.write(to: packageURL, options: .atomic)

        // 更新索引
        var manifests = allManifests()
        manifests.removeAll { $0.questionID == package.manifest.questionID }
        manifests.append(package.manifest)
        saveManifests(manifests)
    }

    func loadPackage(questionID: Int64) -> OfflineQuestionPackage? {
        let packageURL = questionDirectory(for: questionID).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONDecoder().decode(OfflineQuestionPackage.self, from: data)
        else {
            return nil
        }
        return package
    }

    func deleteQuestion(questionID: Int64) {
        let dir = questionDirectory(for: questionID)
        try? fileManager.removeItem(at: dir)

        var manifests = allManifests()
        manifests.removeAll { $0.questionID == questionID }
        saveManifests(manifests)
    }

    func deleteAll() {
        let questionsDir = baseDirectory.appendingPathComponent("questions", isDirectory: true)
        try? fileManager.removeItem(at: questionsDir)
        let imagesDir = baseDirectory.appendingPathComponent("images", isDirectory: true)
        try? fileManager.removeItem(at: imagesDir)
        try? fileManager.removeItem(at: indexFileURL)
        ensureBaseDirectoriesExist()
    }

    // MARK: - Offline Images Management

    private static func imageFilename(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        return "\(hashString).\(ext)"
    }

    func offlineImageFileURL(for url: URL) -> URL {
        baseDirectory
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(Self.imageFilename(for: url))
    }

    func hasCachedImage(for url: URL) -> Bool {
        let fileURL = offlineImageFileURL(for: url)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    func cachedImageData(for url: URL) -> Data? {
        let fileURL = offlineImageFileURL(for: url)
        return try? Data(contentsOf: fileURL)
    }

    func saveImageData(_ data: Data, for url: URL) {
        let fileURL = offlineImageFileURL(for: url)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Total Cache Size

    func calculateTotalCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = resourceValues.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }
}
