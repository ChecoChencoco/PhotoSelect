import Foundation
import CoreImage
import ImageIO
import ProbeCore

public enum PreviewTier:String,Sendable {case thumbnail,quick,retina,full}
public struct PreviewFrame: @unchecked Sendable {
    public let image:CGImage
    public let identity:String
    public let tier:PreviewTier
    public let source:String
    public let orientation:Int
    public let seconds:Double
    public let cacheHit:Bool
    public var width:Int{image.width}
    public var height:Int{image.height}
    public var cost:Int{image.bytesPerRow*image.height}
}
private final class CancelFlag: @unchecked Sendable {
    private let lock=NSLock();private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    func check()throws{lock.lock();let v=value;lock.unlock();if v{throw CancellationError()}}
}
public final class MediaDecoder: @unchecked Sendable {
    private let queue:OperationQueue
    private var cache=CostCache<String,PreviewFrame>(limit:128*1024*1024)
    private var active=0, maximumActive=0
    public init(){queue=OperationQueue();queue.name="PhotoSelect.serial.decode";queue.maxConcurrentOperationCount=1;queue.qualityOfService = .userInitiated}
    public func decode(_ item:MediaItem,tier:PreviewTier) async throws -> PreviewFrame {
        let flag=CancelFlag()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let op=BlockOperation {
                    do {
                        try flag.check()
                        let frame=try autoreleasepool { try self.perform(item,tier:tier,flag:flag) }
                        try flag.check();continuation.resume(returning:frame)
                    } catch {continuation.resume(throwing:error)}
                }
                op.queuePriority=tier == .thumbnail ? .low : .veryHigh
                self.queue.addOperation(op)
            }
        },onCancel:{flag.cancel()})
    }
    public func trim(){queue.addOperation{self.cache.clear()}}
    public func metrics() async -> [String:Int] {
        await withCheckedContinuation{ continuation in queue.addOperation {continuation.resume(returning:["cache_bytes":self.cache.totalCost,"cache_limit":self.cache.limit,"max_concurrent_render":self.maximumActive])}}
    }
    private func perform(_ original:MediaItem,tier:PreviewTier,flag:CancelFlag)throws->PreviewFrame {
        let start=ProcessInfo.processInfo.systemUptime
        // Re-stat even on cache hits: disconnected volumes / replaced files never return stale pixels.
        let item=try MediaItem(url:original.url)
        guard item.cacheIdentity == original.cacheIdentity else {throw MediaError.message("文件已更改，请返回文件夹并刷新列表。")}
        let key=item.cacheIdentity+"|"+tier.rawValue
        if tier != .full,let hit=cache.value(for:key) {
            return PreviewFrame(image:hit.image,identity:item.cacheIdentity,tier:tier,source:hit.source,orientation:hit.orientation,seconds:ProcessInfo.processInfo.systemUptime-start,cacheHit:true)
        }
        try flag.check()
        let image:CGImage,source:String,orientation:Int
        if item.isRAW {
            let container=try TIFFContainer(data:Data(contentsOf:item.url,options:.mappedIfSafe))
            orientation=container.orientation
            guard (1...8).contains(orientation) else {throw MediaError.message("RAW 方向字段无效。")}
            if tier == .quick || tier == .thumbnail {
                let blobs=try container.embeddedJPEGs()
                var chosen:CGImage?, area=0
                for blob in blobs {
                    guard let src=CGImageSourceCreateWithData(blob as CFData,nil),
                          let p=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any],
                          let w=p[kCGImagePropertyPixelWidth as String] as? Int,let h=p[kCGImagePropertyPixelHeight as String] as? Int else {continue}
                    if w*h>area,let cg=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary){chosen=cg;area=w*h}
                }
                guard let chosen else{throw MediaError.message("没有可读取的内嵌 JPEG；正在尝试 RAW 清晰预览。")}
                try flag.check()
                let ci=CIImage(cgImage:chosen).oriented(forExifOrientation:Int32(orientation))
                let scale=tier == .thumbnail ? min(1,240/max(ci.extent.width,ci.extent.height)):1
                image=try render(ci.transformed(by:CGAffineTransform(scaleX:scale,y:scale)))
                source=tier == .thumbnail ? "内嵌 JPEG 缩略图":"内嵌 JPEG"
            } else {
                guard let filter=CIRAWFilter(imageURL:item.url) else{throw MediaError.message("系统无法解码此 RAW；可继续查看内嵌 JPEG。")}
                filter.orientation=CGImagePropertyOrientation(rawValue:UInt32(orientation))!
                filter.isDraftModeEnabled=false
                filter.scaleFactor=tier == .full ? 1:min(1,Float(3200/max(filter.nativeSize.width,filter.nativeSize.height)))
                guard let ci=filter.outputImage else{throw MediaError.message("RAW 解码器没有输出图像。")}
                try flag.check();image=try render(ci)
                source=tier == .full ? "完整 RAW · 100%":"RAW 清晰预览"
            }
        } else {
            guard let src=CGImageSourceCreateWithURL(item.url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let p=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any] else {throw MediaError.message("图片损坏、格式不受支持或无法读取。")}
            orientation=p[kCGImagePropertyOrientation as String] as? Int ?? 1
            let w=p[kCGImagePropertyPixelWidth as String] as? Int ?? 0,h=p[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            guard w>0,h>0,Double(w)*Double(h)<=100_000_000 else {throw MediaError.message("图片尺寸无效或超过本阶段的 1 亿像素上限。")}
            let size=tier == .full ? max(w,h):(tier == .thumbnail ? 240:3200)
            guard let cg=CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:size,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {throw MediaError.message("无法生成图片预览。")}
            image=cg;source=tier == .full ? "原始图片 · 100%":"图片预览"
        }
        try flag.check()
        let frame=PreviewFrame(image:image,identity:item.cacheIdentity,tier:tier,source:source,orientation:orientation,seconds:ProcessInfo.processInfo.systemUptime-start,cacheHit:false)
        if tier != .full {cache.insert(frame,key:key,cost:frame.cost)}
        return frame
    }
    private func render(_ ci:CIImage)throws->CGImage {
        let extent=ci.extent
        guard !extent.isEmpty,!extent.isInfinite,extent.width*extent.height<=100_000_000 else{throw MediaError.message("RAW 输出尺寸无效或超出限制。")}
        active+=1;maximumActive=max(maximumActive,active);defer{active-=1}
        let context=CIContext(options:[.cacheIntermediates:false])
        defer{context.clearCaches()}
        guard let cg=context.createCGImage(ci,from:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB),deferred:false) else {throw MediaError.message("系统图形渲染失败。请检查当前运行环境是否允许图形设备访问。")}
        return cg
    }
}
