import Foundation
import SQLite3
import CryptoKit

public extension MediaItem {
    var isVideo:Bool{["mp4","mov"].contains(url.pathExtension.lowercased())}

}
public struct MediaGroup:Identifiable,Sendable {
    public let id:String
    public let members:[MediaItem]
    public let warning:String?
    public var lead:MediaItem{members.first{$0.isRAW} ?? members.first{$0.url.pathExtension.lowercased() != "xmp"}!}
    public var media:[MediaItem]{members.filter{$0.url.pathExtension.lowercased() != "xmp"}}
}
public enum GroupResolver {
    public static func resolve(_ snapshot:FolderSnapshot,automatic:Bool=true)throws->[MediaGroup]{
        let extras=try FileManager.default.contentsOfDirectory(at:snapshot.url,includingPropertiesForKeys:nil).filter{$0.pathExtension.lowercased()=="xmp"}.compactMap{try? MediaItem(url:$0)}
        let buckets=Dictionary(grouping:snapshot.items+extras){$0.url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()}
        var groups:[MediaGroup]=[]
        func make(_ members:[MediaItem],_ warning:String?=nil){guard let lead=members.first(where:{$0.isRAW}) ?? members.first(where:{$0.url.pathExtension.lowercased() != "xmp"}) else{return};groups.append(MediaGroup(id:lead.stableKey,members:members,warning:warning))}
        for items in buckets.values {
            let videos=items.filter(\.isVideo);for v in videos{make([v])}
            let photos=items.filter{!$0.isVideo && $0.url.pathExtension.lowercased() != "xmp"}
            let xmp=items.filter{$0.url.pathExtension.lowercased()=="xmp"}
            let raw=photos.filter(\.isRAW),jpeg=photos.filter{["jpg","jpeg"].contains($0.url.pathExtension.lowercased())}
            let ambiguous=raw.count>1 || jpeg.count>1 || xmp.count>1 || photos.count>raw.count+jpeg.count && photos.count>1
            if ambiguous || (!automatic && photos.count>1 && !xmp.isEmpty){for p in photos{make([p],"分组存在歧义：请调整同名文件或启用 RAW+JPEG 分组；整理和删除已暂停。")}}
            else if automatic && raw.count==1 && jpeg.count==1{make(raw+jpeg+xmp)}
            else{for p in photos{make([p]+(photos.count==1 ? xmp:[]))}}
        }
        return groups.sorted{MediaScanner.naturalLess($0.lead.name,$1.lead.name)}
    }
}

/// All access serialized, with FULL durability. Failed writes throw before the UI changes.
public final class SelectionStore:@unchecked Sendable {
    private var db:OpaquePointer?
    private let lock=NSRecursiveLock()
    public let url:URL
    public init(url:URL)throws {
        self.url=url
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else{throw MediaError.message("收藏数据库无法打开")}
        sqlite3_busy_timeout(db,3000)
        try execute("PRAGMA journal_mode=WAL");try execute("PRAGMA synchronous=FULL");try execute("PRAGMA foreign_keys=ON")
        let version=Int(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
        guard version<=1 else{throw MediaError.message("数据库版本较新，不能降级打开")}
        try transaction{
            try execute("CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY,path TEXT NOT NULL,folder TEXT NOT NULL,favorite INTEGER NOT NULL DEFAULT 0,available INTEGER NOT NULL DEFAULT 1)")
            try execute("CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY,folder TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS members(group_id TEXT NOT NULL,file_id TEXT NOT NULL,PRIMARY KEY(group_id,file_id))")
            try execute("CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY,bookmark TEXT,last_media TEXT,last_opened REAL NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE IF NOT EXISTS visited(folder TEXT,file_id TEXT,PRIMARY KEY(folder,file_id))")
            try execute("CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,state TEXT NOT NULL,payload TEXT NOT NULL,updated REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS roles(path TEXT PRIMARY KEY,role TEXT NOT NULL)")
            try execute("PRAGMA user_version=1")
        }
    }
    deinit{sqlite3_close(db)}
    private func statement(_ sql:String,_ args:[String])throws->OpaquePointer{
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,let stmt else{throw failure()}
        for (i,arg) in args.enumerated(){sqlite3_bind_text(stmt,Int32(i+1),arg,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        return stmt
    }
    private func failure()->Error{MediaError.message("数据库操作失败：\(String(cString:sqlite3_errmsg(db)))。状态未提交，请检查磁盘或权限。")}
    public func execute(_ sql:String,_ args:[String]=[])throws{
        lock.lock();defer{lock.unlock()};let s=try statement(sql,args);defer{sqlite3_finalize(s)}
        let code=sqlite3_step(s);guard code==SQLITE_DONE || code==SQLITE_ROW else{throw failure()}
    }
    public func rows(_ sql:String,_ args:[String]=[])throws->[[String]]{
        lock.lock();defer{lock.unlock()};let s=try statement(sql,args);defer{sqlite3_finalize(s)};var result:[[String]]=[]
        while true{let code=sqlite3_step(s);if code==SQLITE_DONE{return result};guard code==SQLITE_ROW else{throw failure()};result.append((0..<sqlite3_column_count(s)).map{sqlite3_column_text(s,$0).map{String(cString:$0)} ?? ""})}
    }
    public func transaction<T>(_ body:()throws->T)throws->T{
        lock.lock();defer{lock.unlock()};try execute("BEGIN IMMEDIATE")
        do{let result=try body();try execute("COMMIT");return result}catch{try? execute("ROLLBACK");throw error}
    }
    public func register(_ groups:[MediaGroup],folder:URL,bookmark:Data?=nil)throws {
        try transaction{
            try execute("UPDATE files SET available=0 WHERE folder=?",[folder.path])
            for group in groups {
                var protected=false
                for item in group.members{if try isProtected(item.stableKey){protected=true}}
                try execute("INSERT OR REPLACE INTO groups(id,folder) VALUES(?,?)",[group.id,folder.path])
                for item in group.members {
                    try execute("INSERT INTO files(id,path,folder,available) VALUES(?,?,?,1) ON CONFLICT(id) DO UPDATE SET path=excluded.path,folder=excluded.folder,available=1",[item.stableKey,item.url.path,folder.path])
                    try execute("INSERT OR IGNORE INTO members VALUES(?,?)",[group.id,item.stableKey])
                }
                if protected{try setFavorite(group,true)}
            }
            try execute("INSERT INTO folders(path,bookmark,last_opened) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET bookmark=COALESCE(NULLIF(excluded.bookmark,''),folders.bookmark),last_opened=excluded.last_opened",[folder.path,bookmark?.base64EncodedString() ?? "",String(Date().timeIntervalSince1970)])
        }
    }
    public func isProtected(_ fileID:String)throws->Bool{
        // Historical membership is retained: a missing RAW still protects its JPEG.
        try rows("SELECT 1 FROM files WHERE favorite=1 AND (id=? OR id IN (SELECT file_id FROM members WHERE group_id IN (SELECT group_id FROM members WHERE file_id=?))) LIMIT 1",[fileID,fileID]).isEmpty == false
    }
    public func favorite(_ group:MediaGroup)throws->Bool{for m in group.members{if try isProtected(m.stableKey){return true}};return false}
    public func setFavorite(_ group:MediaGroup,_ value:Bool)throws{
        // Caller may already be inside an operation transaction.
        for m in group.members{try execute("UPDATE files SET favorite=? WHERE id=? OR id IN (SELECT file_id FROM members WHERE group_id IN (SELECT group_id FROM members WHERE file_id=?))",[value ? "1":"0",m.stableKey,m.stableKey])}
    }
    public func toggle(_ group:MediaGroup)throws->Bool{try transaction{guard try unfinished().isEmpty else{throw MediaError.message("未完成操作需要先核对，收藏状态暂时保留。")};let value = try !favorite(group);try setFavorite(group,value);return value}}
    public func savePosition(folder:URL,item:MediaItem)throws{try transaction{try execute("UPDATE folders SET last_media=? WHERE path=?",[item.stableKey,folder.path]);try execute("INSERT OR IGNORE INTO visited VALUES(?,?)",[folder.path,item.stableKey])}}
    public func lastPosition(_ folder:URL)throws->String?{try rows("SELECT last_media FROM folders WHERE path=?",[folder.path]).first?.first}
    public func offlineFavorites(_ folder:URL)throws->Int{Int(try rows("SELECT count(*) FROM files WHERE folder=? AND favorite=1 AND available=0",[folder.path]).first?.first ?? "0") ?? 0}
    public func visitedCount(_ folder:URL)throws->Int{Int(try rows("SELECT count(*) FROM visited WHERE folder=?",[folder.path]).first?.first ?? "0") ?? 0}
    public func recordOperation(id:String,state:String,payload:Data)throws{try execute("INSERT INTO operations VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,payload=excluded.payload,updated=excluded.updated",[id,state,String(decoding:payload,as:UTF8.self),String(Date().timeIntervalSince1970)])}
    public func unfinished()throws->[[String]]{try rows("SELECT id,state,payload FROM operations WHERE state IN ('planned','in_progress','needs_recovery','undoing') ORDER BY updated")}
}
