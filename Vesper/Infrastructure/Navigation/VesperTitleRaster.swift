import SwiftUI
import UIKit
@preconcurrency import CoreImage

/// Animatable feeds interpolated values into UIViewRepresentable. UIKit does not
/// automatically interpolate arbitrary Core Image parameters in updateUIView.
struct VesperTitleRendering: View, Animatable {
    let title: String
    let scrollProgress: Double
    let reduceMotion: Bool
    let height: CGFloat
    var collapseProgress: Double

    var animatableData: Double {
        get { collapseProgress }
        set { collapseProgress = newValue }
    }

    var body: some View {
        // Continue from the current scroll appearance as soon as collapse starts;
        // max(scroll, collapse) would otherwise pause blur/fade until it catches up.
        let scroll = min(1, max(0, scrollProgress))
        let progress = min(1, max(0, scroll + (1 - scroll) * collapseProgress))
        VesperTitleRaster(title: title, radius: CGFloat(progress) * 12)
            // ScrollView alone supplies natural scroll displacement. This offset
            // is zero throughout dragging and deceleration, until idle collapses.
            .offset(y: reduceMotion ? 0 : -height * collapseProgress)
            .opacity(1 - progress)
    }
}

private struct VesperTitleRaster: UIViewRepresentable {
    let title: String
    let radius: CGFloat

    func makeUIView(context: Context) -> TitleRasterView { TitleRasterView() }

    func updateUIView(_ view: TitleRasterView, context: Context) {
        view.configure(title: title, radius: radius)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TitleRasterView, context: Context) -> CGSize? {
        uiView.measuredSize(width: proposal.width)
    }
}

/// Only immutable CGImage data crosses the serial worker boundary.
private struct TitleBitmap: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
}

/// The context is accessed only on this queue. Each view submits at most one
/// render at a time and retains only the latest desired radius while it runs.
private final class TitleBlurWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vesper.title.blur", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ bitmap: TitleBitmap, radius: CGFloat,
                completion: @escaping @MainActor @Sendable (TitleBitmap?) -> Void) {
        queue.async { [self] in
            let input = CIImage(cgImage: bitmap.image)
            let output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * bitmap.scale])
                .cropped(to: input.extent)
            let result = context.createCGImage(output, from: input.extent).map {
                TitleBitmap(image: $0, scale: bitmap.scale)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private final class TitleRasterView: UIView {
    // Snapshot the whole source container, so any future title icons/background
    // belong to the same image and receive the same Gaussian blur.
    private let source = UIView()
    private let label = UILabel()
    private let imageView = UIImageView()
    private let worker = TitleBlurWorker()
    private var bitmap: TitleBitmap?
    private var generation: UInt64 = 0
    private var rendering = false
    private var desiredRadius: CGFloat = 0
    private var displayedRadius: CGFloat?
    private var snapshotDirty = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        source.backgroundColor = .clear
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = UIColor(named: "VesperPrimaryText") ?? .label
        imageView.contentMode = .scaleToFill
        addSubview(source)
        source.addSubview(label)
        addSubview(imageView)
        imageView.isHidden = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        updateFont()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self,
                                 UITraitUserInterfaceStyle.self,
                                 UITraitAccessibilityContrast.self,
                                 UITraitDisplayScale.self]) { (view: TitleRasterView, _: UITraitCollection) in
            view.updateFont()
            view.invalidateSnapshot()
            view.invalidateIntrinsicContentSize()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, radius: CGFloat) {
        if label.text != title {
            label.text = title
            invalidateSnapshot()
            invalidateIntrinsicContentSize()
        }
        // Quantize to half-point steps; invisible subpixel differences do not
        // require a new GPU render. The unblurred original stays live at zero.
        desiredRadius = (max(0, radius) * 2).rounded() / 2
        refreshImage()
    }

    func measuredSize(width: CGFloat?) -> CGSize {
        let width = max(1, width ?? (label.intrinsicContentSize.width + 40))
        let text = label.sizeThatFits(CGSize(width: max(1, width - 40), height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(text.height) + 24)
    }

    override var intrinsicContentSize: CGSize { measuredSize(width: nil) }

    override func layoutSubviews() {
        super.layoutSubviews()
        if source.frame.size != bounds.size {
            source.frame = bounds
            imageView.frame = bounds
            label.frame = CGRect(x: 20, y: 8, width: max(0, bounds.width - 40), height: max(0, bounds.height - 24))
            invalidateSnapshot()
        }
        refreshImage()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    private func updateFont() {
        let base = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traitCollection)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        label.font = UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private func invalidateSnapshot() {
        generation += 1
        snapshotDirty = true
        bitmap = nil
        displayedRadius = nil
        imageView.image = nil
        imageView.isHidden = true
        source.isHidden = false
        setNeedsLayout()
    }

    private func refreshImage() {
        if desiredRadius == 0 {
            source.isHidden = false
            imageView.isHidden = true
            return
        }
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if snapshotDirty {
            source.isHidden = false
            source.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = min(2, traitCollection.displayScale)
            let snapshot = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                source.layer.render(in: context.cgContext)
            }
            guard let image = snapshot.cgImage else { return }
            bitmap = TitleBitmap(image: image, scale: format.scale)
            snapshotDirty = false
        }
        if displayedRadius == desiredRadius {
            source.isHidden = true
            imageView.isHidden = false
            return
        }
        guard !rendering, let bitmap else { return }
        rendering = true
        let token = generation
        let radius = desiredRadius
        worker.render(bitmap, radius: radius) { [weak self] result in
            guard let self else { return }
            rendering = false
            if generation == token, desiredRadius == radius, let result {
                imageView.image = UIImage(cgImage: result.image, scale: result.scale, orientation: .up)
                displayedRadius = radius
                source.isHidden = desiredRadius > 0
                imageView.isHidden = desiredRadius == 0
            }
            // Coalesce changes made during this render. Do not spin on failure.
            if generation != token || desiredRadius != radius { refreshImage() }
        }
    }
}
