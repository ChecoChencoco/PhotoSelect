import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin
import ProbeCore

#if !arch(arm64)
#error("RAWDecoderProbe supports Apple Silicon arm64 only")
#endif

func clockTime() -> Double { ProcessInfo.processInfo.systemUptime }
func peakMiB() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1048576 // Darwin reports bytes.
}
func dimensions(_ image: CGImage) -> [Int] { [image.width,image.height] }
func pixelEvidence(_ image: CGImage) throws -> [String:Any] {
    guard let data=image.dataProvider?.data, let bytes=CFDataGetBytePtr(data) else {
        throw ProbeError.invalid("Rendered CGImage pixel data unavailable")
    }
    let count=CFDataGetLength(data), stride=max(4,(count/4096/4)*4)
    var minimum=255,maximum=0,sum=0,samples=0
    for offset in Swift.stride(from:0,to:max(0,count-3),by:stride) {
        for channel in 0..<3 {
            let value=Int(bytes[offset+channel]);minimum=min(minimum,value);maximum=max(maximum,value);sum+=value;samples+=1
        }
    }
    return ["buffer_bytes":count,"sample_count":samples,"sample_min":minimum,"sample_max":maximum,"sample_sum":sum]
}
func emit(_ value: [String:Any]) {
    let data = try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    print(String(decoding:data,as:UTF8.self))
}
func saveJPEG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil) else {
        throw ProbeError.invalid("Cannot create preview destination")
    }
    // Rendered pixels already oriented; do not copy metadata from the original.
    CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ProbeError.invalid("JPEG write failed") }
}

func probe(url: URL, previewFolder: URL?) -> [String:Any] {
    var result: [String:Any] = ["file":url.lastPathComponent,"color_review":"待人工确认"]
    var failures: [String] = []
    func stage(_ name: String, _ action: () throws -> [String:Any]) {
        let start = clockTime()
        do {
            var value = try autoreleasepool(invoking:action)
            value["seconds"] = clockTime()-start; value["status"] = "pass"
            value["process_peak_rss_mib"] = peakMiB(); result[name] = value
        } catch {
            // Error domains/codes only for Foundation errors: no arbitrary EXIF or paths in logs.
            let message = (error as? ProbeError)?.description ?? "\((error as NSError).domain) code \((error as NSError).code)"
            result[name] = ["status":"fail","error":message,"seconds":clockTime()-start,"process_peak_rss_mib":peakMiB()]
            failures.append(name)
        }
    }
    var container: TIFFContainer?
    stage("container") {
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        let parsed = try TIFFContainer(data:data); container = parsed
        guard let raw = parsed.rawDirectory, let w=raw.tags[256]?.first, let h=raw.tags[257]?.first else {
            throw ProbeError.invalid("No Bayer RAW SubIFD found")
        }
        let compression = raw.tags[259]?.first ?? -1
        return ["bytes":data.count,"raw_dimensions":[w,h],"bits_per_sample":raw.tags[258] ?? [],
                "compression":compression,"storage":compression == 1 ? "uncompressed TIFF Bayer" : "other / unclassified",
                "raw_ifd_offset":raw.offset,"orientation":parsed.orientation]
    }
    stage("imageio_metadata") {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any] else {
            throw ProbeError.invalid("ImageIO could not read image properties")
        }
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        return ["camera":tiff[kCGImagePropertyTIFFModel as String] ?? "unavailable",
                "firmware":tiff[kCGImagePropertyTIFFSoftware as String] ?? "unavailable",
                "imageio_dimensions":[p[kCGImagePropertyPixelWidth as String] as? Int ?? 0,p[kCGImagePropertyPixelHeight as String] as? Int ?? 0],
                "orientation":p[kCGImagePropertyOrientation as String] ?? 0]
    }
    stage("embedded_jpeg") {
        let extractionStart=clockTime()
        guard let container else { throw ProbeError.invalid("TIFF parse unavailable") }
        let jpegs = try container.embeddedJPEGs()
        var candidates: [(Data,CGImage)] = []
        for data in jpegs {
            if let src=CGImageSourceCreateWithData(data as CFData,nil),
               let img=CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) {
                candidates.append((data,img))
            }
        }
        guard let best = candidates.max(by: { $0.1.width*$0.1.height < $1.1.width*$1.1.height }) else {
            throw ProbeError.invalid("No decodable embedded JPEG")
        }
        var value: [String:Any] = ["source":"TIFF JPEGInterchangeFormat byte range, no RAW decode",
            "dimensions":dimensions(best.1),"jpeg_bytes":best.0.count,"all_dimensions":candidates.map { dimensions($0.1) }]
        // Core TIFF byte extraction + JPEG decode time is recorded separately from optional export.
        value["extraction_decode_seconds"] = clockTime()-extractionStart
        if let previewFolder {
            let ci = CIImage(cgImage:best.1).oriented(forExifOrientation:Int32(container.orientation))
            let context=CIContext(options:[.cacheIntermediates:false])
            guard let img=context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB),deferred:false) else {
                throw ProbeError.invalid("Embedded orientation render failed")
            }
            let name=url.deletingPathExtension().lastPathComponent+"-embedded.jpg"
            try saveJPEG(img,to:previewFolder.appendingPathComponent(name)); value["preview_file"]=name
        }
        return value
    }
    stage("imageio_thumbnail") {
        guard let src=CGImageSourceCreateWithURL(url as CFURL,nil),
              let img=CGImageSourceCreateThumbnailAtIndex(src,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:false,
                kCGImageSourceCreateThumbnailFromImageIfAbsent:false,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:1616,
                kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
            throw ProbeError.invalid("ImageIO existing-thumbnail-only request returned nil")
        }
        return ["dimensions":dimensions(img),"source":"ImageIO existing-thumbnail-only; internal source not independently guaranteed"]
    }
    // Each render owns/releases its context, filter and CGImage. One file per process in batch runner.
    for (name, screen) in [("retina_raw",true),("full_raw",false)] {
        stage(name) {
            guard let filter=CIRAWFilter(imageURL:url) else { throw ProbeError.invalid("CIRAWFilter initialization returned nil") }
            let native=filter.nativeSize
            let decoderOrientation=filter.orientation.rawValue
            if let container {
                guard let orientation=CGImagePropertyOrientation(rawValue:UInt32(container.orientation)) else {
                    throw ProbeError.invalid("Invalid TIFF Orientation; expected 1...8")
                }
                // Explicit setter replaces decoder orientation, rather than rotating its output twice.
                filter.orientation=orientation
            }
            filter.isDraftModeEnabled=false
            filter.scaleFactor=screen ? min(1,Float(3200/max(native.width,native.height))) : 1
            guard let image=filter.outputImage else { throw ProbeError.invalid("CIRAWFilter outputImage returned nil") }
            guard !image.extent.isEmpty, !image.extent.isInfinite,
                  image.extent.width*image.extent.height <= 100_000_000 else { throw ProbeError.invalid("Invalid RAW output extent") }
            let context=CIContext(options:[.cacheIntermediates:false])
            let renderStart=clockTime()
            guard let rendered=context.createCGImage(image,from:image.extent,format:.RGBA8,
                colorSpace:CGColorSpace(name:CGColorSpace.sRGB),deferred:false) else {
                throw ProbeError.invalid("CIRAWFilter actual render returned nil")
            }
            var value: [String:Any] = ["source":"CIRAWFilter sensor RAW, draft=false",
                "native_dimensions":[Int(native.width),Int(native.height)],"dimensions":dimensions(rendered),
                "scale_factor":filter.scaleFactor,"orientation":filter.orientation.rawValue,
                "decoder_initial_orientation":decoderOrientation,"orientation_source":"explicit TIFF root Orientation",
                "render_seconds":clockTime()-renderStart,"color_space":"sRGB RGBA8",
                "decoder":String(describing:filter.decoderVersion),"deferred":false]
            value["pixel_evidence"] = try pixelEvidence(rendered)
            if screen, let previewFolder {
                let name=url.deletingPathExtension().lastPathComponent+"-retina.jpg"
                try saveJPEG(rendered,to:previewFolder.appendingPathComponent(name)); value["preview_file"]=name
            }
            context.clearCaches(); return value
        }
    }
    result["process_peak_rss_mib"] = peakMiB()
    result["status"] = failures.isEmpty ? "pass" : "fail"
    result["failed_stages"] = failures
    return result
}

let args=Array(CommandLine.arguments.dropFirst())
guard args.count == 1 || args.count == 3 && args[1] == "--previews" else {
    fputs("Usage: RAWDecoderProbe file.ARW [--previews directory]\n",stderr); exit(2)
}
let url=URL(fileURLWithPath:args[0])
let folder=args.count == 3 ? URL(fileURLWithPath:args[2],isDirectory:true) : nil
if let folder {
    do { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
    catch { fputs("Cannot create previews directory\n",stderr); exit(2) }
}
let result=autoreleasepool { probe(url:url,previewFolder:folder) }
emit(result); exit(result["status"] as? String == "pass" ? 0 : 1)
