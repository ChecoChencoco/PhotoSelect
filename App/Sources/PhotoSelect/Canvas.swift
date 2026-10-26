import SwiftUI
import AppKit
import PhotoSelectCore

final class PixelCanvas:NSView {
    var image:CGImage?
    var full=false
    var imageRect=NSRect.zero
    private var dragStart:NSPoint?,originStart:NSPoint?
    override var isFlipped:Bool{true}
    override func draw(_ dirtyRect:NSRect){
        NSColor.windowBackgroundColor.setFill();bounds.fill()
        guard let image else{return}
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)).draw(in:imageRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
    override func resetCursorRects(){if full{addCursorRect(bounds,cursor:.openHand)}}
    override func mouseDown(with event:NSEvent){guard full,let clip=superview as? NSClipView else{return};dragStart=event.locationInWindow;originStart=clip.bounds.origin;NSCursor.closedHand.push()}
    override func mouseDragged(with event:NSEvent){guard let start=dragStart,let origin=originStart,let clip=superview as? NSClipView else{return};let p=event.locationInWindow;let x=max(0,min(frame.width-clip.bounds.width,origin.x-(p.x-start.x)));let y=max(0,min(frame.height-clip.bounds.height,origin.y+(p.y-start.y)));clip.scroll(to:NSPoint(x:x,y:y));enclosingScrollView?.reflectScrolledClipView(clip)}
    override func mouseUp(with event:NSEvent){if dragStart != nil{NSCursor.pop()};dragStart=nil;originStart=nil}
}
final class ImageScrollView:NSScrollView {
    let canvas=PixelCanvas()
    var current:CGImage?
    var full=false
    var resetPosition=false
    override init(frame:NSRect){super.init(frame:frame);documentView=canvas;drawsBackground=true;backgroundColor = .windowBackgroundColor;autohidesScrollers=true;scrollerStyle = .overlay;hasHorizontalScroller=true;hasVerticalScroller=true}
    required init?(coder:NSCoder){fatalError()}
    override func layout(){super.layout();arrange()}
    override func viewDidChangeBackingProperties(){super.viewDidChangeBackingProperties();arrange()}
    func arrange(){
        guard let current else{return}
        let viewport=contentView.bounds.size
        guard viewport.width>0,viewport.height>0 else{return}
        let scale=full ? 1/(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2):min(viewport.width/CGFloat(current.width),viewport.height/CGFloat(current.height))
        let size=NSSize(width:CGFloat(current.width)*scale,height:CGFloat(current.height)*scale)
        let doc=NSSize(width:max(viewport.width,size.width),height:max(viewport.height,size.height))
        canvas.frame=NSRect(origin:.zero,size:doc)
        canvas.imageRect=NSRect(x:(doc.width-size.width)/2,y:(doc.height-size.height)/2,width:size.width,height:size.height)
        canvas.image=current;canvas.full=full;canvas.needsDisplay=true
        if resetPosition{contentView.scroll(to:NSPoint(x:max(0,(doc.width-viewport.width)/2),y:max(0,(doc.height-viewport.height)/2)));reflectScrolledClipView(contentView);resetPosition=false}
    }
}
struct PhotoCanvas:NSViewRepresentable {
    let frame:PreviewFrame
    func makeNSView(context:Context)->ImageScrollView{ImageScrollView()}
    func updateNSView(_ view:ImageScrollView,context:Context){
        let changed=view.current !== frame.image || view.full != (frame.tier == .full)
        view.current=frame.image;view.full=frame.tier == .full;view.resetPosition=changed;view.arrange()
        view.setAccessibilityLabel("\(frame.source)，\(frame.width)乘\(frame.height)像素")
    }
}
struct KeyboardCapture:NSViewRepresentable {
    @ObservedObject var model:AppModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSView {let v=NSView();context.coordinator.view=v;context.coordinator.start();return v}
    func updateNSView(_ view:NSView,context:Context){}
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator){coordinator.stop()}
    @MainActor final class Coordinator {
        weak var view:NSView?
        let model:AppModel
        var monitor:Any?
        init(_ model:AppModel){self.model=model}
        func start(){monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            guard let self,self.model.isPreview,event.window==self.view?.window,!(event.window?.firstResponder is NSTextView),event.modifierFlags.intersection([.control,.option]).isEmpty else{return event}
            if event.modifierFlags.contains(.command) && event.keyCode != 51 && event.keyCode != 117{return event}
            guard !self.model.operationBusy,self.model.deleteGroup==nil,!self.model.showOrganize,!self.model.settingsOpen,self.model.notice==nil else{return event}
            switch event.keyCode{
                case 51,117:self.model.requestDelete();return nil
                case 46:model.toggleFavorite();return nil
            case 123:self.model.navigate(-1)
            case 124:self.model.navigate(1)
            case 53:self.model.home()
            default:
                switch event.charactersIgnoringModifiers?.lowercased(){case "f":self.model.fit();case "z":self.model.full();default:return event}
            };return nil
        }}
        func stop(){if let monitor{NSEvent.removeMonitor(monitor)};monitor=nil}
    }
}
