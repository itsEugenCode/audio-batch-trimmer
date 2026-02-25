//
//  ContentView.swift
//  audio-batch-trimmer
//
//  Created by Eugen on 24.02.2026.
//

import SwiftUI
import AVFoundation
import AppKit
import Combine

// MARK: - Модели

struct AudioFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let duration: TimeInterval
    var isValid: Bool
    var isSelected: Bool = false
    var status: ProcessingStatus = .pending

    var fileName: String {
        url.lastPathComponent
    }

    var formattedDuration: String {
        duration.formatted
    }
}

enum ProcessingStatus: Equatable, Hashable {
    case pending
    case processing
    case completed
    case failed(String)

    var description: String {
        switch self {
        case .pending: return "Ожидает"
        case .processing: return "Обработка..."
        case .completed: return "Готово"
        case .failed(let error): return "Ошибка: \(error)"
        }
    }
}

struct TrimSettings: Equatable {
    /// Сколько секунд оставить от начала трека
    var secondsToKeep: Int = 0
    /// Длительность затухания в секундах (применяется к концу фрагмента)
    var fadeDuration: Int = 0

    func isValid(for duration: TimeInterval) -> Bool {
        let value = secondsToKeep
        return value > 0 && TimeInterval(value) < duration
    }

    func isValidFadeDuration() -> Bool {
        return fadeDuration >= 0 && TimeInterval(fadeDuration) < TimeInterval(secondsToKeep)
    }
}

struct TrimResult: Identifiable {
    let id = UUID()
    let originalFile: AudioFile
    let success: Bool
    let outputURL: URL?
    let errorMessage: String?
    let originalDuration: TimeInterval
    let newDuration: TimeInterval?

    init(success: Bool,
         originalFile: AudioFile,
         outputURL: URL? = nil,
         errorMessage: String? = nil,
         newDuration: TimeInterval? = nil) {
        self.success = success
        self.originalFile = originalFile
        self.outputURL = outputURL
        self.errorMessage = errorMessage
        self.originalDuration = originalFile.duration
        self.newDuration = newDuration
    }
}

// MARK: - Константы и утилиты

enum Constants {
    static let maxDuration: TimeInterval = 600 // 10 минут
    static let supportedFormats = ["mp3"]
    static let maxFilesInFolder = 1000
}

extension TimeInterval {
    var formatted: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension URL {
    var isMP3: Bool {
        pathExtension.lowercased() == "mp3"
    }
}

// MARK: - Сервисы

class AudioScanner {
    func scanFolder(_ folderURL: URL) async -> [AudioFile] {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else {
            return []
        }

        var audioFiles: [AudioFile] = []

        for url in contents {
            guard url.isMP3 else { continue }

            let asset = AVURLAsset(url: url)
            let duration = await getDuration(of: asset)
            let isValid = duration > 0 && duration <= Constants.maxDuration

            let audioFile = AudioFile(
                url: url,
                duration: duration,
                isValid: isValid
            )

            audioFiles.append(audioFile)
        }

        return audioFiles.sorted { $0.fileName < $1.fileName }
    }

    private func getDuration(of asset: AVAsset) async -> TimeInterval {
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }
}

enum ValidationResult {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

class AudioValidator {
    func validateTrimSettings(_ settings: TrimSettings, for audioFile: AudioFile) -> ValidationResult {
        guard audioFile.isValid else {
            return .invalid("Файл превышает максимальную длительность (10 минут)")
        }

        guard settings.secondsToKeep > 0 else {
            return .invalid("Укажите длительность фрагмента")
        }

        guard settings.isValid(for: audioFile.duration) else {
            return .invalid("Длительность фрагмента должна быть меньше длительности трека")
        }

        guard settings.isValidFadeDuration() else {
            return .invalid("Длительность затухания должна быть меньше длительности фрагмента")
        }

        return .valid
    }
}

protocol AudioTrimmerProtocol {
    func trim(audioFile: AudioFile, settings: TrimSettings, outputURL: URL) async throws
}

enum TrimmerError: Error, LocalizedError {
    case exportSessionCreationFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Не удалось создать сессию экспорта"
        case .exportFailed:
            return "Ошибка при экспорте аудио"
        }
    }
}

class AudioTrimmerEngine: AudioTrimmerProtocol {
    func trim(audioFile: AudioFile, settings: TrimSettings, outputURL: URL) async throws {
        let endSeconds = Double(settings.secondsToKeep)
        let fadeSeconds = Double(settings.fadeDuration)
        
        // Создаём выходной файл M4A (AAC)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000
        ]
        
        let audioFile = try AVAudioFile(forReading: audioFile.url)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        
        // Вычисляем количество кадров для обрезки
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let keepFrames = AVAudioFrameCount(endSeconds * sampleRate)
        let framesToRead = min(totalFrames, keepFrames)
        
        guard framesToRead > 0 else { throw TrimmerError.exportFailed }
        
        // Создаём буфер для обрезанных данных
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
            throw TrimmerError.exportFailed
        }
        
        // Читаем только нужное количество кадров
        try audioFile.read(into: buffer, frameCount: framesToRead)
        
        // Применяем затухание если указано
        if fadeSeconds > 0 {
            let fadeFrames = AVAudioFrameCount(fadeSeconds * sampleRate)
            let startFadeFrame = max(0, buffer.frameLength - fadeFrames)
            
            let channelCount = Int(format.channelCount)
            for channel in 0..<channelCount {
                guard let channelData = buffer.floatChannelData?[channel] else { continue }
                
                for frame in Int(startFadeFrame)..<Int(buffer.frameLength) {
                    let progress = Double(frame - Int(startFadeFrame)) / Double(fadeFrames)
                    let gain = 1.0 - progress
                    channelData[frame] *= Float(gain)
                }
            }
        }
        
        // Создаём выходной M4A файл
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        try outputFile.write(from: buffer)
    }
}

class FileNamingService {
    func generateUniqueName(originalURL: URL, in folder: URL, preferredExtension: String? = nil) -> URL {
        let originalName = originalURL.deletingPathExtension().lastPathComponent
        let baseName = "\(originalName)_trimmed"
        let extensionName = preferredExtension ?? originalURL.pathExtension

        var counter = 0
        var finalName = baseName
        var finalURL = folder.appendingPathComponent("\(finalName).\(extensionName)")

        while FileManager.default.fileExists(atPath: finalURL.path) {
            counter += 1
            finalName = "\(baseName)_\(counter)"
            finalURL = folder.appendingPathComponent("\(finalName).\(extensionName)")
        }

        return finalURL
    }
}

// MARK: - ViewModel

@MainActor
class MainViewModel: ObservableObject {
    @Published var selectedFolder: URL?
    @Published var audioFiles: [AudioFile] = []
    @Published var selectedFiles: [AudioFile] = []
    @Published var trimSettings = TrimSettings()
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var results: [TrimResult] = []
    @Published var showResults = false
    @Published var errorMessage: String?
    @Published var tooManyFilesMessage: String?

    private let scanner = AudioScanner()
    private let validator = AudioValidator()
    private let trimmer = AudioTrimmerEngine()
    private let namingService = FileNamingService()
    var canStartTrimming: Bool {
        !selectedFiles.isEmpty &&
        !isProcessing &&
        selectedFiles.allSatisfy { validator.validateTrimSettings(trimSettings, for: $0).isValid }
    }

    var isSingleFileMode: Bool {
        selectedFiles.count == 1
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await loadFolder(url)
            }
        }
    }

    func loadFolder(_ url: URL) async {
        selectedFolder = url
        audioFiles = await scanner.scanFolder(url)
        selectedFiles.removeAll()
        tooManyFilesMessage = nil

        let mp3Count = audioFiles.count
        if mp3Count > Constants.maxFilesInFolder {
            tooManyFilesMessage = "В выбранной папке найдено \(mp3Count) MP3-файлов. " +
            "Приложение рассчитано на обработку до \(Constants.maxFilesInFolder) файлов за раз. " +
            "Рекомендуется уменьшить количество файлов."
        }
    }

    func toggleSelection(_ file: AudioFile) {
        if let index = audioFiles.firstIndex(where: { $0.id == file.id }) {
            audioFiles[index].isSelected.toggle()
            updateSelectedFiles()
        }
    }

    private func updateSelectedFiles() {
        selectedFiles = audioFiles.filter { $0.isSelected && $0.isValid }
    }

    func startTrimming() async {
        guard !selectedFiles.isEmpty else { return }

        isProcessing = true
        progress = 0
        results.removeAll()

        let totalFiles = Double(selectedFiles.count)

        for (index, file) in selectedFiles.enumerated() {
            let result = await processFile(file)
            results.append(result)
            progress = Double(index + 1) / totalFiles
        }

        isProcessing = false

        // Показываем окно результатов только если есть хотя бы один результат
        if !results.isEmpty {
            showResults = true
        }

        if let folder = selectedFolder {
            await loadFolder(folder)
        }
    }

    private func processFile(_ file: AudioFile) async -> TrimResult {
        let validation = validator.validateTrimSettings(trimSettings, for: file)
        guard validation.isValid else {
            return TrimResult(success: false, originalFile: file, errorMessage: validation.errorMessage)
        }

        guard let folder = selectedFolder else {
            return TrimResult(success: false, originalFile: file, errorMessage: "Не выбрана папка")
        }

        // Сохраняем в формате M4A (AAC), который нативно поддерживает AVFoundation
        let outputURL = namingService.generateUniqueName(originalURL: file.url, in: folder, preferredExtension: "m4a")

        do {
            try await trimmer.trim(audioFile: file, settings: trimSettings, outputURL: outputURL)

            let asset = AVURLAsset(url: outputURL)
            let duration = try await asset.load(.duration)
            let newDuration = CMTimeGetSeconds(duration)

            return TrimResult(
                success: true,
                originalFile: file,
                outputURL: outputURL,
                newDuration: newDuration
            )
        } catch {
            return TrimResult(
                success: false,
                originalFile: file,
                errorMessage: error.localizedDescription
            )
        }
    }

    func cancelTrimming() {
        // Для полноценной отмены нужно хранить Task и вызывать cancel()
        isProcessing = false
    }
}

// MARK: - Основные вью

struct MainView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Верхний заголовок окна
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Batch Trimmer")
                        .font(.title2.bold())
                    Text("Быстрая обрезка MP3 по длительности фрагмента")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding([.top, .horizontal])

            FolderSelectionView(viewModel: viewModel)
                .padding([.horizontal, .top])

            if let message = viewModel.tooManyFilesMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .textSelection(.enabled)
            }

            Divider()

            if !viewModel.audioFiles.isEmpty {
                VStack(spacing: 12) {
                    FileListView(viewModel: viewModel)
                    TrimSettingsView(viewModel: viewModel)
                }
                .padding()
            } else {
                DropAreaView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $viewModel.showResults) {
            ResultReportView(results: viewModel.results)
        }
    }
}

struct DropAreaView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .foregroundColor(.gray)
                .opacity(0.5)

            VStack(spacing: 16) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text("Выберите папку с MP3-файлами")
                    .font(.title2)
                    .foregroundColor(.secondary)

                Button("Выбрать папку") {
                    viewModel.selectFolder()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectFolder()
        }
    }
}

struct FolderSelectionView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Папка:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let folder = viewModel.selectedFolder {
                    Text(folder.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("Не выбрана")
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }
}

struct FileListView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        GroupBox("Файлы (\(viewModel.audioFiles.count))") {
            VStack(alignment: .leading, spacing: 8) {
                List(viewModel.audioFiles) { file in
                    FileRow(file: file, isSelected: file.isSelected) {
                        viewModel.toggleSelection(file)
                    }
                }
                .listStyle(.plain)
                .frame(height: 220)

                HStack {
                    Text("Выбрано: \(viewModel.selectedFiles.count) файлов")
                        .font(.caption)

                    Spacer()

                    if viewModel.selectedFiles.count < viewModel.audioFiles.filter({ $0.isValid }).count {
                        Button("Выбрать все") {
                            for index in viewModel.audioFiles.indices where viewModel.audioFiles[index].isValid {
                                viewModel.audioFiles[index].isSelected = true
                            }
                            viewModel.selectedFiles = viewModel.audioFiles.filter { $0.isSelected && $0.isValid }
                        }
                        .font(.caption)
                    }

                    if !viewModel.selectedFiles.isEmpty {
                        Button("Снять выделение") {
                            for index in viewModel.audioFiles.indices {
                                viewModel.audioFiles[index].isSelected = false
                            }
                            viewModel.selectedFiles.removeAll()
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(4)
        }
    }
}

struct FileRow: View {
    let file: AudioFile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(file.isValid ? .blue : .gray)

                Text(file.fileName)
                    .strikethrough(!file.isValid)
                    .textSelection(.enabled)

                Spacer()

                Text(file.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)

                if !file.isValid {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .help("Длительность более 10 минут")
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!file.isValid)
    }
}

struct TrimSettingsView: View {
    @ObservedObject var viewModel: MainViewModel

    var selectedFile: AudioFile? {
        viewModel.isSingleFileMode ? viewModel.selectedFiles.first : nil
    }

    var body: some View {
        GroupBox("Настройки обрезки") {
            VStack(alignment: .leading, spacing: 12) {
                // Информация о выбранных файлах
                if viewModel.isSingleFileMode, let file = selectedFile {
                    HStack {
                        Text("Файл:")
                            .foregroundColor(.secondary)
                        Text(file.fileName)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Text(file.formattedDuration)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else if viewModel.selectedFiles.count > 1 {
                    Text("Выбрано файлов: \(viewModel.selectedFiles.count)")
                        .foregroundColor(.secondary)
                }

                // Настройки длительности фрагмента
                HStack {
                    Text("Длительность фрагмента (сек):")

                    TextField("0", value: $viewModel.trimSettings.secondsToKeep, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    Spacer()
                }

                // Настройки длительности затухания
                HStack {
                    Text("Длительность затухания (сек):")

                    TextField("0", value: $viewModel.trimSettings.fadeDuration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    Spacer()
                }

                // Кнопка обрезки и подсказки
                HStack {
                    Spacer()

                    // Кнопка обрезки
                    if viewModel.canStartTrimming {
                        Button("Обрезать") {
                            Task {
                                await viewModel.startTrimming()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }

                if !viewModel.canStartTrimming {
                    Text("Выберите файлы и укажите корректное время обрезки")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .padding(4)
        }
    }
}

struct ResultReportView: View {
    let results: [TrimResult]
    @Environment(\.dismiss) private var dismiss

    var successfulResults: [TrimResult] {
        results.filter { $0.success }
    }

    var failedResults: [TrimResult] {
        results.filter { !$0.success }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Результаты обработки")
                .font(.title2)

            HStack(spacing: 40) {
                Label("\(successfulResults.count) успешно", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)

                Label("\(failedResults.count) ошибок", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .font(.headline)

            if !successfulResults.isEmpty {
                GroupBox("Успешно обработаны") {
                    List(successfulResults) { result in
                        HStack {
                            Text(result.originalFile.fileName)
                            Spacer()
                            Text("\(result.originalDuration.formatted) → \(result.newDuration?.formatted ?? "--:--")")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 150)
                }
            }

            if !failedResults.isEmpty {
                GroupBox("Ошибки") {
                    List(failedResults) { result in
                        HStack {
                            Text(result.originalFile.fileName)
                            Spacer()
                            Text(result.errorMessage ?? "Неизвестная ошибка")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .frame(height: 100)
                }
            }

            Button("Закрыть") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 520, height: 420)
        .textSelection(.enabled)
    }
}
