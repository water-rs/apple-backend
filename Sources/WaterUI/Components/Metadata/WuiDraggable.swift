import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - WuiDraggable

/// Component for Metadata<Draggable>.
///
/// Makes the wrapped view draggable for native drag and drop operations.
/// On macOS, uses NSDragging protocols.
/// On iOS, uses UIDragInteraction.
@MainActor
final class WuiDraggable: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_draggable_id() }
    
    private let contentView: any WuiComponent
    private nonisolated(unsafe) let draggable: WuiDraggable_t
    private let env: WuiEnvironment
    
    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }
    
    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_draggable(anyview)
        
        self.env = env
        self.draggable = metadata.value
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
        
        super.init(frame: .zero)
        
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
        
        #if canImport(UIKit)
        // iOS: Use UIDragInteraction
        let dragInteraction = UIDragInteraction(delegate: self)
        dragInteraction.isEnabled = true
        self.addInteraction(dragInteraction)
        self.isUserInteractionEnabled = true
        #elseif canImport(AppKit)
        // macOS: Register as drag source
        registerForDraggedTypes([.string, .URL])
        #endif
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        var mutableDraggable = draggable
        waterui_drop_draggable(&mutableDraggable)
    }
    
    private func getDragData() -> (tag: WuiDragDataTag, value: String) {
        var mutableDraggable = draggable
        let data = waterui_draggable_get_data(&mutableDraggable)
        let value = WuiStr(data.value).toString()
        return (data.tag, value)
    }
    
    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }
    
    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }
    
    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }

    // MARK: - macOS Drag Source

    private var dragOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }

        let current = event.locationInWindow
        let distance = hypot(current.x - origin.x, current.y - origin.y)

        // Only start drag after moving a minimum distance (3 points)
        guard distance > 3 else { return }

        dragOrigin = nil  // Prevent re-triggering

        let (tag, value) = getDragData()

        let pasteboardItem = NSPasteboardItem()
        if tag == WuiDragDataTag_Url {
            if let url = URL(string: value) {
                pasteboardItem.setString(url.absoluteString, forType: .URL)
            }
        } else {
            pasteboardItem.setString(value, forType: .string)
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            // Flip the context since NSView.isFlipped = true but CGContext is not flipped
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            layer?.render(in: ctx)
        }
        image.unlockFocus()
        return image
    }
    #endif
}

#if canImport(AppKit)
extension WuiDraggable: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move]
    }
}
#endif

#if canImport(UIKit)
extension WuiDraggable: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        let (tag, value) = getDragData()
        
        let itemProvider: NSItemProvider
        if tag == WuiDragDataTag_Url, let url = URL(string: value) {
            itemProvider = NSItemProvider(object: url as NSURL)
        } else {
            itemProvider = NSItemProvider(object: value as NSString)
        }
        
        let dragItem = UIDragItem(itemProvider: itemProvider)
        return [dragItem]
    }
}
#endif

// Swift type alias to avoid conflict with class name
typealias WuiDraggable_t = CWaterUI.WuiDraggable
