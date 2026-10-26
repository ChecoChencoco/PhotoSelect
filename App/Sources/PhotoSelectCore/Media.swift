import Foundation
import Darwin
import CryptoKit

public struct MediaItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let bytes: Int
    public let modified: Double
    public let fileIdentifier: String
    public let stableKey:String
    public var id: String { url.standardizedFileURL.path }
    public var name: String { url.lastPathComponent }
    public var isRAW: Bool { url.pathExtension.lowercased() == "arw" }
    public var cacheIdentity: String { "\(id)|\(bytes)|\(modified)|\(fileIdentifier)|AppleRAW8-orient-v1" }
    public init(url: URL) throws {
        var fresh=url
        fresh.removeAllCachedResourceValues()
        let v = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .isRegularFileKey, .isSymbolicLinkKey,.volumeUUIDStringKey,.creationDateKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true else { throw MediaError.message("这不是可读取的普通图片文件。") }
        self.url=fresh; bytes=v.fileSize ?? 0; modified=v.contentModificationDate?.timeIntervalSince1970 ?? 0
        fileIdentifier=String(describing:v.fileResourceIdentifier)
        let identity=v.fileResourceIdentifier.map{String(describing:$0)} ?? fresh.standardizedFileURL.path
        stableKey=SHA256.hash(data:Data("\(v.volumeUUIDString ?? "")|\(identity)|\(v.creationDate?.timeIntervalSince1970 ?? 0)|\(bytes)|\(modified)".utf8)).map{String(format:"%02x",$0)}.joined()
    }
}
public enum MediaError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let s): return s } }
}
public struct FolderSnapshot: Sendable {
    public let url: URL
    public let items: [MediaItem]
    public let folders: [URL]
    public let ignoredCount: Int
    public let elapsed: Double
    public init(url:URL,items:[MediaItem],folders:[URL],ignoredCount:Int,elapsed:Double){self.url=url;self.items=items;self.folders=folders;self.ignoredCount=ignoredCount;self.elapsed=elapsed}
}
public enum MediaScanner {
    public static let extensions: Set<String> = ["arw","jpg","jpeg","png","heic","heif","tif","tiff","mp4","mov"]
    public static func scan(_ url: URL) throws -> FolderSnapshot {
        let start=ProcessInfo.processInfo.systemUptime
        let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw MediaError.message("请选择一个实际文件夹。") }
        let entries=try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey],options:[.skipsHiddenFiles])
        var items:[MediaItem]=[],folders:[URL]=[],ignored=0
        for child in entries {
            let v=try child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            if v.isSymbolicLink == true { ignored+=1;continue } // No silent traversal outside a selected folder.
            if v.isDirectory == true { folders.append(child) }
            else if extensions.contains(child.pathExtension.lowercased()) {
                if let item=try? MediaItem(url:child) { items.append(item) } else { ignored+=1 }
            } else { ignored+=1 }
        }
        items.sort { naturalLess($0.name,$1.name) }
        folders.sort { naturalLess($0.lastPathComponent,$1.lastPathComponent) }
        return FolderSnapshot(url:url,items:items,folders:folders,ignoredCount:ignored,elapsed:ProcessInfo.processInfo.systemUptime-start)
    }
    public static func naturalLess(_ a:String,_ b:String)->Bool {
        let c=a.localizedStandardCompare(b)
        return c == .orderedSame ? a < b : c == .orderedAscending
    }
    public static func index(_ current:Int,delta:Int,count:Int)->Int { max(0,min(max(0,count-1),current+delta)) }
}

/// Small bounded LRU; access only from the decoder's serial queue.
public struct CostCache<Key:Hashable,Value> {
    private var entries:[Key:(Value,Int)]=[:]
    private var order:[Key]=[]
    public private(set) var totalCost=0
    public let limit:Int
    public init(limit:Int) { self.limit=limit }
    public mutating func value(for key:Key)->Value? {
        guard let entry=entries[key] else { return nil }
        order.removeAll{$0==key};order.append(key);return entry.0
    }
    public mutating func insert(_ value:Value,key:Key,cost:Int) {
        if let old=entries.removeValue(forKey:key) {totalCost-=old.1;order.removeAll{$0==key}}
        guard cost<=limit else{return}
        while totalCost+cost>limit, let first=order.first {
            order.removeFirst();if let old=entries.removeValue(forKey:first){totalCost-=old.1}
        }
        entries[key]=(value,cost);order.append(key);totalCost+=cost
    }
    public mutating func clear(){entries.removeAll();order.removeAll();totalCost=0}
}
public enum ProcessMemory {
    /// Instantaneous resident bytes of this long-lived process. Not total GPU/unified allocation.
    public static var rssMiB:Double {
        var info=mach_task_basic_info()
        var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let result=withUnsafeMutablePointer(to:&info) {
            $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size)/1048576 : -1
    }
}
