import UIKit

class ViewController: UIViewController {

    // MARK: - UI

    private var playerView: UIView?
    private var player: VP9AlphaPlayerView?
    private let statusLabel   = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let seekSlider    = UISlider()
    private let timeLabel     = UILabel()

    // Suppress slider updates while user is dragging
    private var isSeeking = false

    // Checkerboard background so alpha transparency is visible
    private let checkerView = CheckerboardView()
    private let bgImageView = UIImageView(image: UIImage(named: "Gemini_Generated_Image_mo8yhqmo8yhqmo8y"))

    // Video sources
    private let webmURL = URL(string: "https://storage.googleapis.com/rmbr/h264_main_720p_3000_rgba.webm")!
    private let dashURL = URL(string: "https://storage.googleapis.com/rmbr/h264_main_720p_3000_rgba_dash_alpha/manifest.mpd")!

    private var hasLoadedPlayer = false
    private var localFileURL: URL?
    private var dashController: DASHStreamController?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupBackground()
        setupStatusLabel()
        setupPlayerLayout()
        setupControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasLoadedPlayer else { return }
        hasLoadedPlayer = true
        showSourcePicker()
    }

    // MARK: - Source Picker

    private func showSourcePicker() {
        let alert = UIAlertController(
            title: "VP9+Alpha Player",
            message: "Choose playback mode",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "WebM (single file)", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.statusLabel.text = "Downloading WebM..."
            self.downloadAndPlay(url: self.webmURL)
        })

        alert.addAction(UIAlertAction(title: "DASH (MPD streaming)", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.loadDASHAndPlay(mpdURL: self.dashURL)
        })

        // iPad popover anchor
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
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

        bgImageView.contentMode = .scaleAspectFill
        bgImageView.clipsToBounds = true
        bgImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bgImageView)
        NSLayoutConstraint.activate([
            bgImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bgImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bgImageView.topAnchor.constraint(equalTo: view.topAnchor),
            bgImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
        let p = VP9AlphaPlayerView(frame: .zero)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.backgroundColor = .clear
        p.isLooping = true
        p.onPlaybackEnd = { [weak self] in
            self?.statusLabel.text = "Playback ended."
        }
        view.addSubview(p)
        playerView = p
        player = p

        // Center player, maintain 3:4 aspect ratio (360x480)
        let aspectRatio: CGFloat = 360.0 / 480.0
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            p.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            p.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
            p.heightAnchor.constraint(equalTo: p.widthAnchor, multiplier: 1.0 / aspectRatio)
        ])


        statusLabel.text = "Choose playback mode..."
    }

    private func setupControls() {
        // Seek slider
        seekSlider.minimumValue = 0
        seekSlider.maximumValue = 1
        seekSlider.value = 0
        seekSlider.isEnabled = false
        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.addTarget(self, action: #selector(seekBegan), for: .touchDown)
        seekSlider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        seekSlider.addTarget(self, action: #selector(seekEnded), for: [.touchUpInside, .touchUpOutside])
        view.addSubview(seekSlider)

        // Time label
        timeLabel.text = "0:00 / 0:00"
        timeLabel.textColor = .white
        timeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textAlignment = .center
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timeLabel)

        // Play/Pause button
        playPauseButton.setTitle("Play", for: .normal)
        playPauseButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        playPauseButton.isEnabled = false
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        view.addSubview(playPauseButton)

        guard let pv = playerView else { return }

        NSLayoutConstraint.activate([
            // Seek slider: below player view
            seekSlider.topAnchor.constraint(equalTo: pv.bottomAnchor, constant: 12),
            seekSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            seekSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Time label: below slider
            timeLabel.topAnchor.constraint(equalTo: seekSlider.bottomAnchor, constant: 4),
            timeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Play/pause: below time label
            playPauseButton.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 8),
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    // MARK: - Controls Actions

    @objc private func togglePlayPause() {
        guard let p = player else { return }
        if p.state == .playing {
            p.pause()
        } else {
            p.play()
        }
    }

    @objc private func seekBegan() {
        isSeeking = true
    }

    @objc private func seekChanged() {
        guard let p = player, let dur = p.duration, dur > 0 else { return }
        let targetTime = Double(seekSlider.value) * dur
        timeLabel.text = "\(formatTime(targetTime)) / \(formatTime(dur))"
    }

    @objc private func seekEnded() {
        guard let p = player, let dur = p.duration, dur > 0 else {
            isSeeking = false
            return
        }
        let targetTime = Double(seekSlider.value) * dur
        p.seek(to: targetTime)
        isSeeking = false
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func bindPlayerCallbacks(_ p: VP9AlphaPlayerView) {
        p.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .playing:
                    print("video playing")
                    self.playPauseButton.setTitle("Pause", for: .normal)
                    self.playPauseButton.isEnabled = true
                    self.seekSlider.isEnabled = true
                case .paused:
                    print("video paused")

                    self.playPauseButton.setTitle("Play", for: .normal)
                case .loading, .buffering:
                    print("video loading/buffering")
                    self.playPauseButton.isEnabled = false
                    self.seekSlider.isEnabled = state == .buffering
                case .ended:
                    print("video ended")
                    self.playPauseButton.setTitle("Play", for: .normal)
                    self.playPauseButton.isEnabled = false
                default:
                    break
                }
            }
        }

        p.onTimeUpdate = { [weak self] time in
            DispatchQueue.main.async {
                guard let self, !self.isSeeking,
                      let dur = self.player?.duration, dur > 0 else { return }
                self.timeLabel.text = "\(self.formatTime(time)) / \(self.formatTime(dur))"
                self.seekSlider.value = Float(time / dur)
            }
        }
    }

    // MARK: - WebM (Single File) Download & Play

    private func downloadAndPlay(url: URL) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cachedFile = cacheDir.appendingPathComponent(url.lastPathComponent)

        // Use cached file if already downloaded
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            print("[VC] Using cached file: \(cachedFile.lastPathComponent)")
            localFileURL = cachedFile
            loadAndPlay()
            return
        }

        statusLabel.text = "Downloading video..."
        print("[VC] Downloading \(url)")

        URLSession.shared.downloadTask(with: url) { [weak self] tmpURL, response, error in
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
        guard let p = player, let url = localFileURL else { return }

        bindPlayerCallbacks(p)
        p.onDecoderReady = { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    p.play()
                    self?.statusLabel.text = "VP9 + Alpha  ·  WebM single file + Metal"
                } else {
                    self?.statusLabel.text = "libvpx VP9 decoder failed to initialize."
                }
            }
        }

        p.load(fileURL: url)
    }

    // MARK: - DASH Streaming

    private func loadDASHAndPlay(mpdURL: URL) {
        statusLabel.text = "Loading DASH manifest..."
        print("[VC] Fetching MPD: \(mpdURL)")

        URLSession.shared.dataTask(with: mpdURL) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.statusLabel.text = "MPD fetch failed: \(error.localizedDescription)"
                }
                return
            }

            guard let data = data,
                  let manifest = MPDManifest(xmlData: data, baseURL: mpdURL) else {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Failed to parse MPD manifest."
                }
                return
            }

            print("[VC] MPD parsed: \(manifest.periods.count) period(s)")

            let controller = DASHStreamController(manifest: manifest)

            DispatchQueue.main.async {
                guard let p = self.player else { return }

                self.dashController = controller
                self.statusLabel.text = "Buffering..."

                self.bindPlayerCallbacks(p)
                p.onDecoderReady = { [weak self] success in
                    DispatchQueue.main.async {
                        if success {
                            self?.statusLabel.text = "VP9 + Alpha  ·  DASH streaming + Metal"
                        } else {
                            self?.statusLabel.text = "libvpx VP9 decoder failed to initialize."
                        }
                    }
                }

                p.loadStream(controller: controller)
            }
        }.resume()
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
