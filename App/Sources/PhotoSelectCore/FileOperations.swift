import Foundation
import CryptoKit
import Darwin

// Darwin's exclusive rename is an atomic no-overwrite operation, unlike rename().
@_silgen_name("renamex_np") private func exclusiveRename(_ from:UnsafePointer<CChar>,_ to:UnsafePointer<CChar>,_ flags:UInt32)->Int32
public enum FileSafety {
    public static func canonical(_ url:URL)->URL{
        var base=url.standardizedFileURL,parts:[String]=[]
        while !FileManager.default.fileExists(atPath:base.path),base.path != "/"{parts.insert(base.lastPathComponent,at:0);base.deleteLastPathComponent()}
        var result=base.resolvingSymlinksInPath()
        for part in parts{result.appendPathComponent(part)}
        // Foundation may retain the system /var spelling depending on existence.
        if result.path.hasPrefix("/var/"){return URL(fileURLWithPath:"/private"+result.path)}
        if result.path.hasPrefix("/tmp/"){return URL(fileURLWithPath:"/private"+result.path)}
        return result
    }
    public static func digest(_ url:URL)throws->String{
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
        while let data=try file.read(upToCount:1024*1024),!data.isEmpty{hash.update(data:data)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    public static func noLinks(_ url:URL)throws{
        var p=url.standardizedFileURL
        // macOS public /var and /tmp aliases are fixed system paths; user links remain rejected.
        if p.path.hasPrefix("/var/"){p=URL(fileURLWithPath:"/private"+p.path)}
        if p.path.hasPrefix("/tmp/"){p=URL(fileURLWithPath:"/private"+p.path)}
        while p.path != "/" {
            var info=stat()
            let result=p.path.withCString{Darwin.lstat($0,&info)}
            if result==0,info.st_mode & mode_t(S_IFMT)==mode_t(S_IFLNK){throw MediaError.message("拒绝通过符号链接执行文件操作：\(p.lastPathComponent)")}
            if result != 0 && errno != ENOENT{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
            p.deleteLastPathComponent()
        }
    }
    public static func moveExclusive(_ from:URL,_ to:URL)throws{
        try noLinks(from);try noLinks(to)
        let result=from.path.withCString{f in to.path.withCString{t in exclusiveRename(f,t,4)}}
        guard result==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    }
    public static func unchanged(_ url:URL,id:String,hash:String?=nil)throws{
        try noLinks(url)
        guard try MediaItem(url:url).stableKey==id else{throw MediaError.message("文件已改变，请刷新后重试：\(url.lastPathComponent)")}
        if let hash,try digest(url) != hash{throw MediaError.message("文件字节已改变，已拒绝操作：\(url.lastPathComponent)")}
    }
}
public struct OperationFile:Codable,Sendable {
    public var source:String,destination:String,sourceID:String
    public var hash:String="",targetID:String="",state:String="planned",temporary:String="",trash:String="",error:String=""
}
public struct OperationGroup:Codable,Sendable {
    public var id:String,files:[OperationFile],state:String="planned",error:String=""
}
public struct OperationBatch:Codable,Identifiable,Sendable {
    public var id=UUID().uuidString
    public var source:String,destination:String,mode:String,groups:[OperationGroup],state:String="planned"
    public var collectionRoot:String?,collectionRootID:String?,sourceDirectoryID:String?
    public var createdDestinationDirectory:Bool?,destinationDirectoryID:String?,directoryCleanup:String?
    public var bytes:Int
    public var time=Date().timeIntervalSince1970
    public init(source:String,destination:String,mode:String,groups:[OperationGroup],bytes:Int){self.source=source;self.destination=destination;self.mode=mode;self.groups=groups;self.bytes=bytes}
    public var filesCount:Int{groups.reduce(0){$0+$1.files.count}}
}
public struct OrganizePlan:Sendable {
    public let batch:OperationBatch
    public let groups:[MediaGroup]
    public let warnings:[String]
}
public enum DestinationPolicy {
    public static func directoryID(_ url:URL)throws->String{
        try FileSafety.noLinks(url)
        var info=stat()
        guard url.path.withCString({Darwin.lstat($0,&info)})==0,
              info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR) else{throw MediaError.message("目录离线或身份无法确认")}
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    public static func destination(source:URL,name:String="选片",historicalSelection:Bool=false,at date:Date=Date())throws->URL{
        guard !["/","/Users","/Volumes"].contains(source.path) else{throw MediaError.message("请选择具体媒体目录")}
        _ = try directoryID(source)
        let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.calendar=Calendar(identifier:.gregorian);format.timeZone = .current;format.dateFormat="MM月dd日_HH时mm分"
        let stem=format.string(from:date)+"_选片"
        let names=Set(try FileManager.default.contentsOfDirectory(atPath:source.path).map{$0.precomposedStringWithCanonicalMapping.lowercased()})
        for i in 1...99999 {
            let name=stem+(i==1 ? "":"（\(i)）")
            if !names.contains(name.lowercased()){return source.appendingPathComponent(name,isDirectory:true)}
        }
        throw MediaError.message("选片目录编号已耗尽")
    }
}
public final class ProtectedFileOperationService:@unchecked Sendable {
    public let store:SelectionStore
    private let lock=NSRecursiveLock()
    private let fm=FileManager.default
    private let testRoot:URL?
    public var injectConflictName:String?
    public var injectFailureAfter:Int? // Only set by isolated core checks, never by application UI.
    public init(store:SelectionStore,testRoot:URL?=nil){self.store=store;self.testRoot=testRoot.map{FileSafety.canonical($0)}}
    private func isolated(_ url:URL)throws{
        if let testRoot {
            guard fm.fileExists(atPath:testRoot.appendingPathComponent(".photoselect-isolated-test").path),FileSafety.canonical(url).path.hasPrefix(testRoot.path+"/") else{throw MediaError.message("测试安全拦截：路径不在新建隔离测试目录内")}
        }
    }
    private func ready()throws{guard try store.unfinished().isEmpty else{throw MediaError.message("存在未完成操作。请先核对文件位置；已暂停新的写操作，诊断记录已保留。")}}
    private func save(_ batch:OperationBatch)throws{try store.recordOperation(id:batch.id,state:batch.state,payload:JSONEncoder().encode(batch))}
    private func freshGroup(_ group:MediaGroup,source:URL)throws{
        guard group.warning==nil else{throw MediaError.message(group.warning!)}
        let fresh=try GroupResolver.resolve(MediaScanner.scan(source),automatic:group.media.count>1)
        guard let match=fresh.first(where:{$0.members.contains{$0.stableKey==group.lead.stableKey}}),Set(match.members.map(\.stableKey))==Set(group.members.map(\.stableKey)),match.warning==nil else{throw MediaError.message("媒体组成员已改变，请刷新目录后重试。")}
        for item in group.members{try isolated(item.url);try FileSafety.unchanged(item.url,id:item.stableKey)}
    }
    private func collectionRoot(for source:URL)throws->URL {
        _ = try DestinationPolicy.directoryID(source)
        for row in try store.rows("SELECT payload FROM operations ORDER BY updated DESC") {
            let batch=try JSONDecoder().decode(OperationBatch.self,from:Data(row[0].utf8))
            guard batch.mode != "trash",FileSafety.canonical(URL(fileURLWithPath:batch.destination))==FileSafety.canonical(source) else{continue}
            guard let root=batch.collectionRoot,let rootID=batch.collectionRootID,let targetID=batch.destinationDirectoryID,
                  try DestinationPolicy.directoryID(source)==targetID else{throw MediaError.message("无法确认此选片目录的原照片文件夹，已停止整理。请从原照片文件夹开始。")}
            let url=URL(fileURLWithPath:root)
            guard try DestinationPolicy.directoryID(url)==rootID else{throw MediaError.message("原照片文件夹离线或已改变，请重新连接原目录。")}
            return url
        }
        let legacy=try !store.rows("SELECT 1 FROM roles WHERE path=? AND role='selection'",[source.path]).isEmpty
        // Legacy names are only a conservative refusal, never evidence for guessing a parent.
        if legacy || source.lastPathComponent=="选片" || source.lastPathComponent.hasPrefix("追加选片") {
            throw MediaError.message("旧选片目录缺少可确认的来源记录，已停止整理。请从原照片文件夹开始。")
        }
        return source
    }
    private func cleanupDirectory(_ batch:inout OperationBatch){
        guard batch.createdDestinationDirectory==true,let identity=batch.destinationDirectoryID else{batch.directoryCleanup="unproven";return}
        let target=URL(fileURLWithPath:batch.destination)
        do {
            try isolated(target)
            guard try DestinationPolicy.directoryID(target)==identity else{batch.directoryCleanup="identity_changed";return}
            guard try fm.contentsOfDirectory(atPath:target.path).isEmpty else{batch.directoryCleanup="not_empty";return}
            // rmdir is nonrecursive and refuses a directory made nonempty concurrently.
            guard target.path.withCString({Darwin.rmdir($0)})==0 else{batch.directoryCleanup="retained";return}
            batch.directoryCleanup="removed"
        }catch{batch.directoryCleanup="retained"}
    }
    public func plan(source:URL,groups:[MediaGroup],copy:Bool,name:String)throws->OrganizePlan{
        lock.lock();defer{lock.unlock()};try ready();try isolated(source)
        let root=try collectionRoot(for:source)
        let destination=try DestinationPolicy.destination(source:root)
        try isolated(destination);try FileSafety.noLinks(destination)
        var warnings:[String]=[],records:[OperationGroup]=[],bytes=0
        for group in groups {
            guard try store.favorite(group) else{continue}
            var record=OperationGroup(id:group.id,files:group.members.map{OperationFile(source:$0.url.path,destination:destination.appendingPathComponent($0.name).path,sourceID:$0.stableKey)})
            do{try freshGroup(group,source:source)}catch{record.state="skipped";record.error=error.localizedDescription;warnings.append("\(group.lead.name)：\(record.error)")}
            records.append(record);bytes+=group.members.reduce(0){$0+$1.bytes}
        }
        guard !records.isEmpty else{throw MediaError.message("当前目录没有可整理的收藏")}
        // Also treat case-only duplicate output names as conflicts, including cross-group conflicts.
        var names:[String:Int]=[:]
        for (i,g) in records.enumerated(){for file in g.files {
            let key=URL(fileURLWithPath:file.destination).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            if let prior=names[key],prior != i {records[prior].state="skipped";records[i].state="skipped";records[prior].error="目标同名冲突，整组跳过";records[i].error="目标同名冲突，整组跳过";warnings.append("目标同名冲突：\(key)")};names[key]=i
        }}
        let parent=destination.deletingLastPathComponent()
        if !copy {
            let sourceVolume=try source.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
            let destinationVolume=try parent.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
            guard let sourceVolume,sourceVolume==destinationVolume else{throw MediaError.message("本轮仅开放同卷移动；跨卷移动留待专项验证。可选择复制模式保留源文件。")}
        }
        guard fm.isWritableFile(atPath:parent.path) else{throw MediaError.message("目标父目录不可写")}
        if copy,let free=(try? fm.attributesOfFileSystem(forPath:parent.path)[.systemFreeSize]) as? NSNumber,free.int64Value<Int64(bytes){throw MediaError.message("目标空间不足")}
        var batch=OperationBatch(source:source.path,destination:destination.path,mode:copy ? "copy":"move",groups:records,bytes:bytes)
        batch.collectionRoot=root.path;batch.collectionRootID=try DestinationPolicy.directoryID(root);batch.sourceDirectoryID=try DestinationPolicy.directoryID(source)
        return OrganizePlan(batch:batch,groups:groups,warnings:warnings)
    }
    public func execute(_ plan:OrganizePlan,confirmedAt:Date=Date())throws->OperationBatch{
        lock.lock();defer{lock.unlock()};try ready()
        var batch=plan.batch
        let source=URL(fileURLWithPath:batch.source)
        let root=try collectionRoot(for:source)
        guard root.path==batch.collectionRoot,try DestinationPolicy.directoryID(root)==batch.collectionRootID,
              try DestinationPolicy.directoryID(source)==batch.sourceDirectoryID else{throw MediaError.message("来源目录已改变，请重新生成计划。")}
        try isolated(source)
        guard batch.groups.contains(where:{$0.state=="planned"}) else{batch.state="failed";try save(batch);return batch}
        var target:URL
        while true {
            target=try DestinationPolicy.destination(source:root,at:confirmedAt)
            try isolated(target);try FileSafety.noLinks(target)
            batch.destination=target.path;batch.time=confirmedAt.timeIntervalSince1970
            for i in batch.groups.indices{for j in batch.groups[i].files.indices{
                batch.groups[i].files[j].destination=target.appendingPathComponent(URL(fileURLWithPath:batch.groups[i].files[j].source).lastPathComponent).path
            }}
            // Persist intent before exclusive mkdir. An interruption blocks later writes.
            try save(batch)
            if target.path.withCString({Darwin.mkdir($0,0o755)})==0{break}
            let code=errno
            if code==EEXIST{continue}
            batch.state="failed";try save(batch);throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
        batch.createdDestinationDirectory=true;batch.destinationDirectoryID=try DestinationPolicy.directoryID(target)
        batch.state="in_progress";try save(batch)
        if testRoot != nil,let name=injectConflictName,!name.contains("/"){try Data("isolated conflict".utf8).write(to:target.appendingPathComponent(name),options:.withoutOverwriting)}
        var transferred=0
        for i in batch.groups.indices {
            if batch.groups[i].state=="skipped"{continue}
            guard let group=plan.groups.first(where:{$0.id==batch.groups[i].id}) else{continue}
            do {
                try freshGroup(group,source:source)
                guard try store.favorite(group) else{throw MediaError.message("收藏状态已变化，已跳过")}
                let existing=Set(try fm.contentsOfDirectory(atPath:target.path).map{$0.precomposedStringWithCanonicalMapping.lowercased()})
                guard !group.members.contains(where:{existing.contains($0.name.precomposedStringWithCanonicalMapping.lowercased())}) else{throw MediaError.message("目标同名冲突，整组跳过")}
                for j in batch.groups[i].files.indices {
                    var file=batch.groups[i].files[j]
                    let from=URL(fileURLWithPath:file.source),to=URL(fileURLWithPath:file.destination)
                    try FileSafety.unchanged(from,id:file.sourceID)
                    file.hash=try FileSafety.digest(from);file.state="intent";batch.groups[i].files[j]=file;try save(batch)
                    if testRoot != nil,let count=injectFailureAfter,transferred>=count{throw MediaError.message("隔离测试注入的中途失败")}
                    if batch.mode=="copy"{try copyVerified(from:from,to:to,file:&file,batch:&batch,group:i,member:j)}
                    else {
                        // Do not fall back to a cross-volume source deletion in this prototype.
                        try FileSafety.moveExclusive(from,to)
                    }
                    file.targetID=try MediaItem(url:to).stableKey
                    guard try FileSafety.digest(to)==file.hash else{throw MediaError.message("目标完整性验证失败")}
                    file.state="verified";batch.groups[i].files[j]=file;transferred+=1;try save(batch)
                }
                batch.groups[i].state="committed"
                try store.transaction {
                    try store.setFavorite(group,false)
                    if batch.mode=="move" {for f in batch.groups[i].files{try store.execute("UPDATE files SET path=?,folder=? WHERE id=?",[f.destination,target.path,f.sourceID])}}
                    try save(batch)
                }
            }catch {
                batch.groups[i].error=error.localizedDescription
                let clean=rollback(groupIndex:i,batch:&batch)
                batch.groups[i].state=clean ? "failed":"needs_recovery"
                try save(batch)
                if !clean{break}
            }
        }
        batch.state=batch.groups.contains{$0.state=="needs_recovery"} ? "needs_recovery":"completed"
        if batch.groups.contains(where:{$0.state=="committed"}) {
            try store.execute("INSERT OR REPLACE INTO roles VALUES(?,'selection')",[target.path])
        }else if batch.state != "needs_recovery"{cleanupDirectory(&batch)}
        try save(batch);return batch
    }
    private func copyVerified(from:URL,to:URL,file:inout OperationFile,batch:inout OperationBatch,group:Int,member:Int)throws {
        let temporary=to.deletingLastPathComponent().appendingPathComponent(".photoselect-\(UUID().uuidString).partial")
        file.temporary=temporary.path;file.state="copying";batch.groups[group].files[member]=file;try save(batch)
        try fm.copyItem(at:from,to:temporary)
        guard try FileSafety.digest(temporary)==file.hash else{throw MediaError.message("复制校验失败，源文件保留")}
        try FileSafety.unchanged(from,id:file.sourceID,hash:file.hash)
        try FileSafety.moveExclusive(temporary,to)
        file.temporary="";file.targetID=try MediaItem(url:to).stableKey;file.state="copy_verified";batch.groups[group].files[member]=file;try save(batch)
    }
    private func rollback(groupIndex:Int,batch:inout OperationBatch)->Bool{
        var clean=true
        for j in batch.groups[groupIndex].files.indices.reversed(){
            var file=batch.groups[groupIndex].files[j]
            if file.state=="planned"{continue}
            do {
                let from=URL(fileURLWithPath:file.source),to=URL(fileURLWithPath:file.destination)
                if fm.fileExists(atPath:to.path) {
                    let expected=file.targetID.isEmpty ? file.sourceID:file.targetID
                    try FileSafety.unchanged(to,id:expected,hash:file.hash)
                    file.state="rollback_intent";batch.groups[groupIndex].files[j]=file;try save(batch)
                    if batch.mode=="move" && !fm.fileExists(atPath:from.path){try FileSafety.moveExclusive(to,from)}
                    else if batch.mode=="copy" {try FileSafety.unchanged(from,id:file.sourceID,hash:file.hash);var result:NSURL?;try fm.trashItem(at:to,resultingItemURL:&result);file.trash=result?.path ?? ""}
                    else{throw MediaError.message("原路径被占用，需人工核对")}
                }
                if !file.temporary.isEmpty && fm.fileExists(atPath:file.temporary){throw MediaError.message("存在未完成副本，需检查操作日志")}
                file.state="rolled_back"
            }catch{clean=false;file.error=error.localizedDescription;file.state="needs_recovery"}
            batch.groups[groupIndex].files[j]=file
        }
        return clean
    }
    public func checkDelete(_ group:MediaGroup)throws{
        try ready();try freshGroup(group,source:group.lead.url.deletingLastPathComponent())
        for member in group.members{if try store.isProtected(member.stableKey){throw MediaError.message("已收藏，先取消收藏")}}
    }
    /// Called only by the confirmation sheet's explicit action. No alternate delete entry point.
    public func trash(_ group:MediaGroup,current:MediaItem,wholeGroup:Bool)throws->OperationBatch{
        lock.lock();defer{lock.unlock()};try checkDelete(group)
        let items=wholeGroup ? group.members:[current]
        guard items.allSatisfy({i in group.members.contains{$0.stableKey==i.stableKey}}) else{throw MediaError.message("删除项目不属于当前组")}
        var batch=OperationBatch(source:group.lead.url.deletingLastPathComponent().path,destination:"macOS Trash",mode:"trash",groups:[OperationGroup(id:group.id,files:items.map{OperationFile(source:$0.url.path,destination:"macOS Trash",sourceID:$0.stableKey)})],bytes:items.reduce(0){$0+$1.bytes})
        try save(batch);batch.state="in_progress";try save(batch)
        for i in items.indices{
            do{
                // Re-query all group members at the last boundary, independent of UI heart state.
                for m in group.members{guard try !store.isProtected(m.stableKey) else{throw MediaError.message("已收藏，先取消收藏")}}
                let item=items[i];try isolated(item.url);try FileSafety.unchanged(item.url,id:item.stableKey)
                batch.groups[0].files[i].state="trash_intent";try save(batch)
                var result:NSURL?;try fm.trashItem(at:item.url,resultingItemURL:&result)
                batch.groups[0].files[i].trash=result?.path ?? "";batch.groups[0].files[i].state="trashed"
            }catch{batch.groups[0].files[i].state="failed";batch.groups[0].files[i].error=error.localizedDescription}
            try save(batch)
        }
        batch.groups[0].state=batch.groups[0].files.allSatisfy{$0.state=="trashed"} ? "committed":"failed"
        batch.state="completed";try save(batch);return batch
    }
    public func latestUndo()throws->OperationBatch?{
        for row in try store.rows("SELECT payload FROM operations WHERE state IN ('completed','undone') ORDER BY updated DESC"){
            let batch=try JSONDecoder().decode(OperationBatch.self,from:Data(row[0].utf8))
            if batch.mode != "trash",batch.state=="completed",batch.groups.contains(where:{$0.state=="committed"}){return batch}
        };return nil
    }
    public func undoLatest()throws->OperationBatch{
        lock.lock();defer{lock.unlock()};try ready()
        guard var batch=try latestUndo() else{throw MediaError.message("没有可撤销的最近整理")}
        // New batches require unchanged directory identities; legacy batches never clean directories.
        if let identity=batch.destinationDirectoryID {
            guard try DestinationPolicy.directoryID(URL(fileURLWithPath:batch.destination))==identity else{throw MediaError.message("选片目录已改变，已停止撤销。")}
        }
        if let identity=batch.sourceDirectoryID {
            guard try DestinationPolicy.directoryID(URL(fileURLWithPath:batch.source))==identity else{throw MediaError.message("原目录已改变，已停止撤销。")}
        }
        // Full-batch preflight happens before any mutation.
        for group in batch.groups where group.state=="committed" {for file in group.files {
            let from=URL(fileURLWithPath:file.source),to=URL(fileURLWithPath:file.destination)
            try isolated(from);try isolated(to);try FileSafety.unchanged(to,id:file.targetID,hash:file.hash)
            guard fm.isWritableFile(atPath:from.deletingLastPathComponent().path) else{throw MediaError.message("原目录不可写")}
            if batch.mode=="move"{guard !fm.fileExists(atPath:from.path) else{throw MediaError.message("原路径已被占用，拒绝覆盖：\(from.lastPathComponent)")}}
            else{try FileSafety.unchanged(from,id:file.sourceID,hash:file.hash)}
            if try store.isProtected(file.targetID){throw MediaError.message("目标已被重新收藏，先取消目标收藏再撤销")}
        }}
        batch.state="undoing";try save(batch)
        do {
            for i in batch.groups.indices where batch.groups[i].state=="committed" {
                for j in batch.groups[i].files.indices {
                    let file=batch.groups[i].files[j],from=URL(fileURLWithPath:batch.groups[i].files[j].source),to=URL(fileURLWithPath:batch.groups[i].files[j].destination)
                    try FileSafety.unchanged(to,id:file.targetID,hash:file.hash)
                    batch.groups[i].files[j].state="undo_intent";try save(batch)
                    if batch.mode=="move"{try FileSafety.moveExclusive(to,from)}
                    else{var result:NSURL?;try fm.trashItem(at:to,resultingItemURL:&result);batch.groups[i].files[j].trash=result?.path ?? ""}
                    batch.groups[i].files[j].state="undone";try save(batch)
                }
                try store.transaction{
                    for file in batch.groups[i].files{try store.execute("UPDATE files SET favorite=1,path=?,folder=?,available=1 WHERE id=?",[file.source,batch.source,file.sourceID])}
                    batch.groups[i].state="undone";try save(batch)
                }
            }
            batch.state="undone"
            if batch.groups.allSatisfy({$0.state=="undone"}){cleanupDirectory(&batch)}else{batch.directoryCleanup="partial_batch"}
            try save(batch);return batch
        }catch{batch.state="needs_recovery";try save(batch);throw error}
    }
}
