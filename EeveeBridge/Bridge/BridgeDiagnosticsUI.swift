import UIKit

// Diagnostic controls live inside the host app; they do not need a second app or App Group.
@MainActor
final class BridgeDiagnosticsUI {
    static let shared = BridgeDiagnosticsUI()
    private weak var button: UIButton?
    private var installed = false

    func install() {
        if !installed {
            installed = true
            NotificationCenter.default.addObserver(self, selector: #selector(attach),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        attach()
    }

    @objc private func attach() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attach() }
            return
        }
        if button?.window === window { return }
        button?.removeFromSuperview()
        let control = UIButton(type: .system)
        control.setTitle("LD · diagnostic", for: .normal)
        control.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        control.backgroundColor = .black.withAlphaComponent(0.85)
        control.setTitleColor(.systemGreen, for: .normal)
        control.layer.cornerRadius = 16
        control.accessibilityLabel = "Ouvrir le diagnostic LyricsDrive"
        control.addTarget(self, action: #selector(present), for: .touchUpInside)
        control.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(control)
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            control.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
            control.widthAnchor.constraint(equalToConstant: 118),
            control.heightAnchor.constraint(equalToConstant: 32)
        ])
        button = control
    }

    @objc private func present() {
        guard var top = button?.window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        guard !(top is DiagnosticsViewController) else { return }
        top.present(DiagnosticsViewController(), animated: true)
    }
}

@MainActor
private final class DiagnosticsViewController: UIViewController {
    private let report = UITextView()
    private var timer: Timer?
    private let offsetLabel = UILabel()
    private let offsetSlider = UISlider()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        report.isEditable = false
        report.isSelectable = true
        report.accessibilityLabel = "Rapport diagnostic LyricsDrive"
        let actions = UIStackView()
        actions.axis = .vertical
        actions.spacing = 6
        for (title, selector) in [
            ("Tester l’affichage · 30 secondes", #selector(startTest)),
            ("Revenir à Spotify", #selector(stopTest)),
            ("Copier le diagnostic", #selector(copyReport)),
            ("Fermer", #selector(close))
        ] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.addTarget(self, action: selector, for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
            actions.addArrangedSubview(button)
        }
        offsetSlider.minimumValue = -2_000
        offsetSlider.maximumValue = 2_000
        offsetSlider.value = Float(UserDefaults.standard.integer(forKey: "LyricsDrive.SyncOffsetMilliseconds"))
        offsetSlider.isContinuous = false
        offsetSlider.accessibilityLabel = "Décalage des paroles en millisecondes"
        offsetSlider.addTarget(self, action: #selector(changeOffset), for: .valueChanged)
        offsetLabel.font = .systemFont(ofSize: 12)
        offsetLabel.numberOfLines = 2
        updateOffsetLabel()
        let controls = UIStackView(arrangedSubviews: [offsetLabel, offsetSlider])
        controls.axis = .vertical
        controls.spacing = 4
        let stack = UIStackView(arrangedSubviews: [actions, controls, report])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        LyricsDriveBridge.shared.diagnosticReport { [weak self] text in
            guard let self else { return }
            let offset = self.report.contentOffset
            self.report.text = text
            self.report.setContentOffset(offset, animated: false)
        }
    }

    private func updateOffsetLabel() {
        offsetLabel.text = String(format: "Décalage : %+.0f ms · + avance, − retarde\n0 ms = horodatages des paroles sans compensation", offsetSlider.value)
    }

    @objc private func changeOffset() {
        let milliseconds = Int((offsetSlider.value / 100).rounded()) * 100
        offsetSlider.value = Float(milliseconds)
        updateOffsetLabel()
        LyricsDriveBridge.shared.setSynchronizationOffset(milliseconds: milliseconds)
        refresh()
    }

    @objc private func startTest() { LyricsDriveBridge.shared.setDemo(true); refresh() }
    @objc private func stopTest() { LyricsDriveBridge.shared.setDemo(false); refresh() }
    @objc private func copyReport() {
        LyricsDriveBridge.shared.diagnosticReport { text in UIPasteboard.general.string = text }
    }
    @objc private func close() { dismiss(animated: true) }
}
