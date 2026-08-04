import SwiftUI
import ShazamKit
import AVFoundation

enum RecognitionState: Equatable {
    case idle
    case listening
    case matching
    case playing
    case error(String)
}

struct SongRecognitionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var player: PlayerManager

    @State private var state: RecognitionState = .idle
    @State private var matchedTitle = ""
    @State private var matchedArtist = ""
    @State private var recognizer: SongRecognizer?

    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(state == .listening ? 0.25 : 0.15))
                        .frame(width: 180, height: 180)
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 180, height: 180)
                    Image(systemName: stateIcon)
                        .font(.system(size: 64))
                        .foregroundColor(.accentColor)
                }
                .scaleEffect(state == .listening ? 1.05 : 1)
                .animation(state == .listening ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: state)

                Text(statusText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                if case .matching = state {
                    ProgressView()
                }

                if case .error(let msg) = state {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                if case .playing = state {
                    VStack(spacing: 8) {
                        Text(matchedTitle)
                            .font(.title2.bold())
                        Text(matchedArtist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 10)
                }

                Spacer()

                if state != .listening {
                    Button(action: startRecognition) {
                        Label(state == .playing ? "再识别一首" : "开始识别", systemImage: "waveform")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                } else {
                    Button(role: .destructive, action: stopRecognition) {
                        Text("停止")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 30)
            .navigationTitle("听歌识曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onDisappear { recognizer?.stop() }
    }

    private var stateIcon: String {
        switch state {
        case .listening: return "waveform"
        case .playing: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        default: return "mic.fill"
        }
    }

    private var statusText: String {
        switch state {
        case .idle: return "点击开始，将麦克风对准正在播放的音乐"
        case .listening: return "正在聆听…请保持安静"
        case .matching: return "已识别，正在搜索并播放…"
        case .playing: return "已匹配"
        case .error(let msg): return msg
        }
    }

    private func startRecognition() {
        state = .listening
        let recognizer = SongRecognizer()
        recognizer.onMatch = { title, artist in
            matchedTitle = title
            matchedArtist = artist
            playMatch(title: title, artist: artist)
        }
        recognizer.onError = { msg in
            state = .error(msg)
        }
        self.recognizer = recognizer
        recognizer.start()
    }

    private func stopRecognition() {
        recognizer?.stop()
        recognizer = nil
        state = .idle
    }

    private func playMatch(title: String, artist: String) {
        state = .matching
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        Task {
            let songs = (try? await LXAPIClient.shared.search(name: query, source: "kw", page: 1, pages: 3)) ?? []
            if let song = songs.first {
                player.play(song: song, in: songs, index: 0)
                state = .playing
            } else {
                state = .error("未搜索到可播放的歌曲")
            }
        }
    }
}

final class SongRecognizer: NSObject, SHSessionDelegate {
    var onMatch: ((String, String) -> Void)?
    var onError: ((String) -> Void)?

    private var session: SHSession?
    private var audioEngine: AVAudioEngine?
    private var isRunning = false

    func start() {
        stop()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard granted else {
                    self.onError?("请在设置中允许麦克风权限")
                    return
                }
                self.startEngine()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        session = nil
    }

    private func startEngine() {
        let session = SHSession()
        session.delegate = self
        self.session = session

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak session] buffer, time in
            session?.matchStreamingBuffer(buffer, at: time)
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            isRunning = true
        } catch {
            onError?("麦克风启动失败: \(error.localizedDescription)")
        }
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        guard isRunning else { return }
        stop()
        guard let item = match.mediaItems.first else {
            onError?("识别失败，请重试")
            return
        }
        let title = item.title ?? ""
        let artist = item.artist ?? ""
        guard !title.isEmpty else {
            onError?("识别失败，请重试")
            return
        }
        DispatchQueue.main.async {
            self.onMatch?(title, artist)
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        guard isRunning else { return }
        stop()
        DispatchQueue.main.async {
            self.onError?("未识别到歌曲，请重试")
        }
    }
}
