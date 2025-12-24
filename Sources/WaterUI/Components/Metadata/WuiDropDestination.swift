import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - WuiDropDestination

/// Component for Metadata<DropDestination>.
///
/// Makes the wrapped view a drop destination for drag and drop operations.
/// On macOS, uses NSDraggingDestination protocol.
/// On iOS, uses UIDropInteraction.
@MainActor
final class WuiDropDestination: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_drop_destination_id() }
    
    private let contentView: any WuiComponent
    private nonisolated(unsafe) let dropDest: WuiDropDestination_t
    private let env: WuiEnvironment
    
    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }
    
    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_drop_destination(anyview)
        
        self.env = env
        self.dropDest = metadata.value
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
        
        super.init(frame: .zero)
        
        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)
        
        #if canImport(UIKit)
        // iOS: Use UIDropInteraction
        let dropInteraction = UIDropInteraction(delegate: self)
        self.addInteraction(dropInteraction)
        self.isUserInteractionEnabled = true
        #elseif canImport(AppKit)
        // macOS: Register as drop destination
        registerForDraggedTypes([.string, .URL])
        #endif
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        var mutableDest = dropDest
        waterui_drop_drop_destination(&mutableDest)
    }
    
    private func callDropHandler(tag: WuiDragDataTag, value: String) {
        var mutableDest = dropDest
        value.withCString { cString in
            waterui_call_drop_handler(&mutableDest, env.inner, tag, cString)
        }
    }

    private func callEnterHandler() {
        var mutableDest = dropDest
        waterui_call_drop_enter_handler(&mutableDest, env.inner)
    }

    private func callExitHandler() {
        var mutableDest = dropDest
        waterui_call_drop_exit_handler(&mutableDest, env.inner)
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
    
    // MARK: - macOS Drop Destination
    
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        callEnterHandler()
        return .copy
    }
    
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        callExitHandler()
    }
    
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        
        // Try URL first
        if let url = pasteboard.string(forType: .URL) {
            callDropHandler(tag: WuiDragDataTag_Url, value: url)
            return true
        }
        
        // Fall back to string
        if let string = pasteboard.string(forType: .string) {
            callDropHandler(tag: WuiDragDataTag_Text, value: string)
            return true
        }
        
        return false
    }
    #endif
}

#if canImport(UIKit)
extension WuiDropDestination: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        return session.canLoadObjects(ofClass: NSString.self) || session.canLoadObjects(ofClass: NSURL.self)
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        return UIDropProposal(operation: .copy)
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        callEnterHandler()
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        callExitHandler()
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        // Try to load URL first
        if session.canLoadObjects(ofClass: NSURL.self) {
            _ = session.loadObjects(ofClass: NSURL.self) { [weak self] objects in
                if let url = objects.first as? URL {
                    self?.callDropHandler(tag: WuiDragDataTag_Url, value: url.absoluteString)
                }
            }
            return
        }
        
        // Fall back to string
        if session.canLoadObjects(ofClass: NSString.self) {
            _ = session.loadObjects(ofClass: NSString.self) { [weak self] objects in
                if let string = objects.first as? String {
                    self?.callDropHandler(tag: WuiDragDataTag_Text, value: string)
                }
            }
        }
    }
}
#endif

// Swift type alias to avoid conflict with class name
typealias WuiDropDestination_t = CWaterUI.WuiDropDestination
