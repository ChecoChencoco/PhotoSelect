import Foundation
import Darwin
public enum DirectoryListing {
    private static func isDirectory(_ url:URL)->Bool{
        var info=stat()
        return url.path.withCString{Darwin.lstat($0,&info)}==0 && info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR)
    }
    /// One level only. Never follows links or probes media/EXIF.
    public static func children(_ url:URL)throws->[URL]{
        let fm=FileManager.default
        guard isDirectory(url) else{throw MediaError.message("目录不可用")}
        return try fm.contentsOfDirectory(atPath:url.path).filter{!$0.hasPrefix(".")}.compactMap{ name in
            let child=url.appendingPathComponent(name,isDirectory:true)
            guard isDirectory(child) else{return nil}
            return child
        }.sorted{MediaScanner.naturalLess($0.lastPathComponent,$1.lastPathComponent)}
    }
}
