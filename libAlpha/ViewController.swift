import UIKit

class ViewController: UIViewController {

    // MARK: - UI

    private var playerView: UIView?
    private let statusLabel = UILabel()
    private let playButton  = UIButton(type: .system)

    // Checkerboard background so alpha transparency is visible
    private let checkerView = CheckerboardView()

    private let videoURL = URL(string: "https://storage.googleapis.com/rmbr/h264_main_720p_3000_rgba.webm")!
    private var hasLoadedPlayer = false
    private var localFileURL: URL?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupBackground()
        setupStatusLabel()
        setupPlayerLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasLoadedPlayer else { return }
        hasLoadedPlayer = true
        downloadAndPlay()
    }

    // MARK: - Layout

    private func setupBackground() {
        checkerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checkerView)
        NSLayoutConstraint.activate([
            checkerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            checkerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            checkerView.topAnchor.constraint(equalTo: view.topAnchor),
            checkerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupStatusLabel() {
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func setupPlayerLayout() {
        let player = VP9AlphaPlayerView(frame: .zero)
        player.translatesAutoresizingMaskIntoConstraints = false
        player.backgroundColor = .clear
        player.isLooping = true
        player.onPlaybackEnd = { [weak self] in
            self?.statusLabel.text = "Playback ended."
        }
        view.addSubview(player)
        playerView = player

        // Center player, maintain 3:4 aspect ratio (360x480)
        let aspectRatio: CGFloat = 360.0 / 480.0
        NSLayoutConstraint.activate([
            player.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            player.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            player.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
            player.heightAnchor.constraint(equalTo: player.widthAnchor, multiplier: 1.0 / aspectRatio)
        ])

        statusLabel.text = "Downloading..."
    }

    // MARK: - Download & Play

    private func downloadAndPlay() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cachedFile = cacheDir.appendingPathComponent("h264_main_720p_3000_rgba.webm")

        // Use cached file if already downloaded
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            print("[VC] Using cached file: \(cachedFile.lastPathComponent)")
            localFileURL = cachedFile
            loadAndPlay()
            return
        }

        statusLabel.text = "Downloading video..."
        print("[VC] Downloading \(videoURL)")

        URLSession.shared.downloadTask(with: videoURL) { [weak self] tmpURL, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Download failed: \(error.localizedDescription)"
                }
                return
            }

            guard let tmpURL = tmpURL else {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Download failed: no file received."
                }
                return
            }

            do {
                // Move downloaded file to caches
                if FileManager.default.fileExists(atPath: cachedFile.path) {
                    try FileManager.default.removeItem(at: cachedFile)
                }
                try FileManager.default.moveItem(at: tmpURL, to: cachedFile)
                print("[VC] Downloaded to \(cachedFile.lastPathComponent)")
                self.localFileURL = cachedFile

                DispatchQueue.main.async {
                    self.statusLabel.text = "Loading..."
                    self.loadAndPlay()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "File save failed: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func loadAndPlay() {
        guard let player = playerView as? VP9AlphaPlayerView,
              let url = localFileURL else { return }

        player.onDecoderReady = { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    player.play()
                    self?.statusLabel.text = "VP9 + Alpha  ·  libvpx software decode + Metal"
                } else {
                    self?.statusLabel.text = "libvpx VP9 decoder failed to initialize."
                }
            }
        }

        player.load(fileURL: url)
    }
}

// MARK: - CheckerboardView

/// Draws a grey/white checker pattern to make transparency obvious.
private final class CheckerboardView: UIView {

    private let tileSize: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ rect: CGRect) {
        let ctx = UIGraphicsGetCurrentContext()!
        let cols = Int(ceil(rect.width  / tileSize)) + 1
        let rows = Int(ceil(rect.height / tileSize)) + 1
        for row in 0 ..< rows {
            for col in 0 ..< cols {
                let isLight = (row + col) % 2 == 0
                ctx.setFillColor(isLight
                    ? UIColor(white: 0.75, alpha: 1).cgColor
                    : UIColor(white: 0.55, alpha: 1).cgColor)
                ctx.fill(CGRect(x: CGFloat(col) * tileSize,
                                y: CGFloat(row) * tileSize,
                                width: tileSize, height: tileSize))
            }
        }
    }
}
