import SwiftUI
import AppKit
import PhotoSelectCore

struct RecentFolder:Codable,Identifiable {
    var path:String
    var bookmark:Data?
    var id:String{path}
    var name:String{URL(fileURLWithPath:path).lastPathComponent}
}
final class FolderLease: @unchecked Sendable {
    let url:URL
    private let scoped:Bool
    init(_ url:URL){self.url=url;scoped=url.startAccessingSecurityScopedResource()}
    deinit{if scoped{url.stopAccessingSecurityScopedResource()}}
}
@MainActor final class EventLog {
    private var file:FileHandle?
    private(set) var rows:[[String:Any]]=[]
    init(){if let path=argument("--validation-output"){
        let url=URL(fileURLWithPath:path,isDirectory:true)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        let log=url.appendingPathComponent("gui-events.jsonl")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        file=try? FileHandle(forWritingTo:log)
    }}
    func add(_ event:String,_ fields:[String:Any]=[:]) {
        guard file != nil else{return}
        var row=fields;row["event"]=event;row["uptime"]=ProcessInfo.processInfo.systemUptime;row["rss_mib"]=ProcessMemory.rssMiB
        rows.append(row)
        if let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys){try? file?.write(contentsOf:data+Data([10]))}
    }
}
func argument(_ name:String)->String? {
    if let i=CommandLine.arguments.firstIndex(of:name),i+1<CommandLine.arguments.count{return CommandLine.arguments[i+1]}
    guard ["local.photoselect.next.validation","local.photoselect.ui.validation"].contains(Bundle.main.bundleIdentifier ?? ""),let url=Bundle.main.url(forResource:"Validation",withExtension:"json"),let data=try? Data(contentsOf:url),let config=try? JSONDecoder().decode([String:String].self,from:data) else{return nil}
    return config[name]
}
func hasArgument(_ name:String)->Bool{CommandLine.arguments.contains(name) || argument(name)=="true"}

@MainActor final class AppModel:ObservableObject {
    @Published var folder:FolderSnapshot?
    @Published var index=0
    @Published var isPreview=false
    @Published var isHome=true
    @Published var pendingRecovery=false
    @Published var isScanning=false
    @Published var frame:PreviewFrame?
    @Published var loading=false
    @Published var wantsFull=false
    @Published var error:String?
    @Published var recent:[RecentFolder]=[]
    @Published var dragged=false
    @Published var groups:[MediaGroup]=[]
    @Published var favoriteIDs:Set<String>=[]
    @Published var favoritesOnly=false
    @Published var savingSelection=false
    @Published var notice:String?
    @Published var offlineCount=0
    @Published var viewedCount=0
    @Published var settingsOpen=false
    @Published var operationBusy=false
    @Published var deleteGroup:MediaGroup?
    @Published var organizePlan:OrganizePlan?
    @Published var showOrganize=false
    var operations:ProtectedFileOperationService?
    @Published var automaticGrouping=true
    @Published var organizeCopy=false
    @Published var selectionName="选片"
    var store:SelectionStore?
    private var originalSnapshot:FolderSnapshot?
    var currentGroup:MediaGroup?{guard let current else{return nil};return groups.first{$0.lead.id==current.id}}
    var favoriteCount:Int{groups.filter{favoriteIDs.contains($0.id)}.count}
    var currentFavorite:Bool{currentGroup.map{favoriteIDs.contains($0.id)} ?? false}
    let tree:DirectoryTreeStore
    let decoder=MediaDecoder()
    let log=EventLog()
    private var request:Task<Void,Never>?
    private var scanTask:Task<Void,Never>?
    private var generation=0,folderGeneration=0
    private var lease:FolderLease?
    private var positions:[String:String]=[:]
    private let defaults:UserDefaults
    private var pressure:DispatchSourceMemoryPressure?
    var current:MediaItem? {guard let folder,folder.items.indices.contains(index) else{return nil};return folder.items[index]}
    var counter:String {"\(folder?.items.isEmpty == false ? index+1 : 0) / \(folder?.items.count ?? 0)"}
    init(){
        defaults=UserDefaults(suiteName:hasArgument("--self-test") || hasArgument("--validation-preferences") ? "PhotoSelect.UI.Validation":"PhotoSelect.Phase1")!
        tree=DirectoryTreeStore(defaults:defaults)
        automaticGrouping=defaults.object(forKey:"automaticGrouping") as? Bool ?? true
        organizeCopy=defaults.bool(forKey:"organizeCopy")
        selectionName=defaults.string(forKey:"selectionName") ?? "选片"
        do {
            let dbURL=argument("--database").map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(hasArgument("--validation-preferences") || hasArgument("--self-test") ? "PhotoSelectValidation/library.sqlite":"PhotoSelect/library.sqlite")
            store=try SelectionStore(url:dbURL)
            if let store{operations=ProtectedFileOperationService(store:store)}
            if let rows=try store?.rows("SELECT path,bookmark FROM folders ORDER BY last_opened DESC LIMIT 8"),!rows.isEmpty{recent=rows.map{RecentFolder(path:$0[0],bookmark:Data(base64Encoded:$0[1]))}}
            if try store?.unfinished().isEmpty == false{pendingRecovery=true;notice="检测到未完成的文件操作，已保留日志和收藏。请先核对照片位置，暂停对相关文件继续整理。"}
        }catch{notice=error.localizedDescription}

        if recent.isEmpty,let data=defaults.data(forKey:"recent"),let saved=try? JSONDecoder().decode([RecentFolder].self,from:data){recent=saved}
        let source=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:.main)
        source.setEventHandler{[weak self] in guard let self else{return};self.decoder.trim();if self.wantsFull{self.fit()};self.log.add("memory_pressure")}
        source.resume();pressure=source
        log.add("model_ready")
    }
    var organizeDisabledReason:String? {
        if operationBusy || savingSelection{return "正在保存或执行操作"}
        if store==nil{return "收藏数据库不可用"}
        if pendingRecovery{return "有未完成操作，请先核对照片位置，诊断记录已保留"}
        guard let folder else{return "请先选择文件夹"}
        if favoriteCount==0{return "当前文件夹没有已收藏文件"}
        if groups.contains(where:{favoriteIDs.contains($0.id) && $0.warning != nil}){return "选片分组存在歧义，请先处理同名文件"}
        if ["/","/Users","/Volumes"].contains(folder.url.path){return "请选择具体媒体目录"}
        if !FileManager.default.isWritableFile(atPath:folder.url.path){return "当前目录离线或没有写权限"}
        return nil
    }
    var deleteDisabledReason:String? {
        if currentFavorite{return "已收藏，先取消收藏"}
        if pendingRecovery{return "有未完成操作，请先核对记录"}
        if operationBusy || savingSelection{return "正在保存或执行操作"}
        if current==nil{return "没有可删除的媒体"}
        return currentGroup?.warning
    }
    func cancelOrganize(){guard !operationBusy else{return};showOrganize=false;organizePlan=nil;log.add("organize_cancel")}
    func requestDelete(){
        guard !operationBusy,let group=currentGroup,let operations else{return}
        if currentFavorite{notice="已收藏，先取消收藏";return}
        Task{do{try await Task.detached{try operations.checkDelete(group)}.value;guard currentGroup?.id==group.id,isPreview,!isHome else{return};deleteGroup=group}catch{operationError(error)}}
    }
    func confirmDelete(wholeGroup:Bool){
        guard let group=deleteGroup,let current,let operations else{return}
        deleteGroup=nil;operationBusy=true
        let oldIndex=index,url=folder?.url
        Task{
            do{let result=try await Task.detached{try operations.trash(group,current:current,wholeGroup:wholeGroup)}.value
                notice=feedback(result)
            }catch{operationError(error)}
            operationBusy=false
            if let url{open(url);while isScanning{try? await Task.sleep(nanoseconds:30_000_000)};if folder?.items.isEmpty==false{enter(min(oldIndex,(folder?.items.count ?? 1)-1))}}
        }
    }
    func prepareOrganize(){
        guard organizeDisabledReason==nil,!isHome,let url=folder?.url,let operations else{return};operationBusy=true
        let selected=groups.filter{favoriteIDs.contains($0.id)},copy=organizeCopy,name=selectionName
        Task{defer{operationBusy=false};do{organizePlan=try await Task.detached{try operations.plan(source:url,groups:selected,copy:copy,name:name)}.value;showOrganize=true}catch{operationError(error)}}
    }
    func confirmOrganize(){
        guard let plan=organizePlan,let operations,!operationBusy else{return}
        let confirmedAt=Date()
        showOrganize=false;operationBusy=true;cancelPreview();log.add("organize_confirm_yes")
        Task{do{let result=try await Task.detached{try operations.execute(plan,confirmedAt:confirmedAt)}.value;notice=feedback(result)}catch{operationError(error)}
            operationBusy=false;pendingRecovery=(try? store?.unfinished().isEmpty)==false;organizePlan=nil;open(URL(fileURLWithPath:plan.batch.source));tree.refresh()
        }
    }
    func undoOrganize(){
        guard !operationBusy,let operations else{return};operationBusy=true
        Task{do{let result=try await Task.detached{try operations.undoLatest()}.value;notice=feedback(result);operationBusy=false;open(URL(fileURLWithPath:result.source));tree.refresh()}catch{operationBusy=false;operationError(error)}}
    }
    func feedback(_ batch:OperationBatch)->String{
        if batch.state=="needs_recovery"{return "操作未完成，请先核对照片位置；诊断记录已保留。"}
        if batch.state=="undone"{
            return batch.directoryCleanup=="removed" ? "已撤销上次选片":"已恢复照片；选片文件夹已保留，请检查其中内容。"
        }
        if batch.mode=="trash"{return batch.groups.allSatisfy{$0.state=="committed"} ? "已移入废纸篓":"部分照片未能删除，请检查磁盘状态。"}
        let count=batch.groups.filter{$0.state=="committed"}.count
        return count==batch.groups.count ? "已完成选片（\(count) 组）":"部分照片未能整理，请检查同名文件或磁盘状态。"
    }
    func operationError(_ error:Error){
        let message=error.localizedDescription
        // Keep diagnostic details locally, outside the normal user flow.
        let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PhotoSelect")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("operation-errors.log")
        if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil)}
        if let file=try? FileHandle(forWritingTo:url){defer{try? file.close()};_ = try? file.seekToEnd();try? file.write(contentsOf:Data("\(Date()): \(message)\n".utf8))}
        if message.contains("来源记录") || message.contains("无法确认此选片目录") {notice="无法确认原照片文件夹，已停止整理。请从原照片文件夹开始。"}
        else if message.contains("没有可撤销"){notice="没有可撤销的最近整理"}
        else if message.contains("重新收藏"){notice="请先取消目标照片的选片标记，再撤销。"}
        else{notice="操作未完成，请检查同名文件、原目录和磁盘状态；诊断记录已保留。"}
        pendingRecovery=(try? store?.unfinished().isEmpty)==false
    }
    func chooseFolder(){
        let panel=NSOpenPanel();panel.title="打开照片文件夹";panel.prompt="打开文件夹";panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.begin { [weak self] result in if result == .OK,let url=panel.url {Task{@MainActor in self?.open(url)}} }
    }
    func openRecent(_ item:RecentFolder){
        if let data=item.bookmark {
            var stale=false
            if let url=try? URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale){open(url);return}
        }
        open(URL(fileURLWithPath:item.path))
    }
    func open(_ url:URL){
        guard !operationBusy else{return}
        rememberPosition();cancelPreview();scanTask?.cancel();folderGeneration+=1
        let token=folderGeneration
        let access=FolderLease(url)
        isPreview=false;isScanning=true;error=nil;folder=nil;lease=nil;groups=[];favoriteIDs=[];favoritesOnly=false
        let grouping=automaticGrouping, database=store
        scanTask=Task {
            do {
                let payload=try await Task.detached(priority:.userInitiated){
                    _ = access
                    let result=try MediaScanner.scan(url),resolved=try GroupResolver.resolve(result,automatic:grouping)
                    let bookmark=try? url.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
                    if let database{try database.register(resolved,folder:url,bookmark:bookmark)}
                    var favorites=Set<String>()
                    for g in resolved{if try database?.favorite(g)==true{favorites.insert(g.id)}}
                    return (result,resolved,favorites,try database?.lastPosition(url),try database?.offlineFavorites(url) ?? 0,try database?.visitedCount(url) ?? 0)
                }.value
                let result=payload.0
                guard !Task.isCancelled,token==folderGeneration else{return}
                self.lease=access;isHome=false;originalSnapshot=result;groups=payload.1;favoriteIDs=payload.2;offlineCount=payload.4;viewedCount=payload.5
                folder=FolderSnapshot(url:result.url,items:groups.map(\.lead),folders:result.folders,ignoredCount:result.ignoredCount,elapsed:result.elapsed)
                isScanning=false;tree.reveal(url)
                index=payload.3.flatMap{id in folder?.items.firstIndex{$0.stableKey==id}} ?? 0
                let bookmark=try? url.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
                recent.removeAll{$0.path==url.path};recent.insert(RecentFolder(path:url.path,bookmark:bookmark),at:0);recent=Array(recent.prefix(8))
                if let data=try? JSONEncoder().encode(recent){defaults.set(data,forKey:"recent")}
                log.add("folder_open",["name":url.lastPathComponent,"count":result.items.count,"folders":result.folders.map{$0.lastPathComponent},"seconds":result.elapsed])
            } catch {
                guard token==folderGeneration else{return}
                isScanning=false;if isHome{notice="无法打开文件夹：\(error.localizedDescription)"};self.error="无法打开文件夹：\(error.localizedDescription)。目录可能离线或权限不足；请重新选择。"
                log.add("folder_error",["name":url.lastPathComponent,"code":(error as NSError).code])
            }
        }
    }
    func drop(_ providers:[NSItemProvider])->Bool {
        guard let provider=providers.first(where:{$0.hasItemConformingToTypeIdentifier("public.file-url")}) else{return false}
        provider.loadItem(forTypeIdentifier:"public.file-url",options:nil){[weak self] item,_ in
            let url=(item as? URL) ?? (item as? Data).flatMap{URL(dataRepresentation:$0,relativeTo:nil)}
            Task{@MainActor in
                guard let self else{return}
                guard let url, (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true else {self.error="请拖入文件夹，图片文件请从所在文件夹打开。";if self.isHome{self.notice=self.error};return}
                self.open(url)
            }
        };return true
    }
    func enter(_ newIndex:Int?=nil){guard !operationBusy,!isHome,let folder,!folder.items.isEmpty else{return};isPreview=true;select(newIndex ?? index)}
    func select(_ newIndex:Int){
        guard let folder,folder.items.indices.contains(newIndex) else{return}
        index=newIndex;wantsFull=false;rememberPosition();startPreview()
    }
    func navigate(_ delta:Int){guard let folder else{return};let next=MediaScanner.index(index,delta:delta,count:folder.items.count);if next != index{select(next)}}
    func goHome(){
        guard !operationBusy,!savingSelection else{return}
        rememberPosition();cancelPreview();scanTask?.cancel();folderGeneration+=1;isScanning=false;isPreview=false;isHome=true;error=nil;log.add("landing_home")
    }
    func home(){guard !operationBusy else{return};isHome=false;rememberPosition();cancelPreview();isPreview=false;wantsFull=false;error=nil;log.add("home")}
    func fit(){wantsFull=false;startPreview()}
    func full(){guard current != nil else{return};wantsFull=true;startPreview()}
    func cancelPreview(){generation+=1;request?.cancel();request=nil;frame=nil;loading=false}
    private func rememberPosition(){if let item=current,let folder{positions[folder.url.path]=item.id
        let db=store
        Task{do{try await Task.detached{try db?.savePosition(folder:folder.url,item:item)}.value;viewedCount=(try? db?.visitedCount(folder.url)) ?? viewedCount}catch{notice=error.localizedDescription}}
    }}
    func toggleFavorite(){
        guard !operationBusy,!savingSelection,let group=currentGroup,let store else{if self.store==nil{notice="数据库不可用，无法保存收藏。"};return}
        savingSelection=true
        Task{defer{savingSelection=false}
            do{let allGroups=groups
                let result=try await Task.detached{let value=try store.toggle(group);var ids=Set<String>();for g in allGroups{if try store.favorite(g){ids.insert(g.id)}};return (value,ids)}.value
                let value=result.0;favoriteIDs=result.1
                log.add("favorite",["group":group.lead.name,"value":value])
                if favoritesOnly{applyFilter()}
            }catch{notice=error.localizedDescription}
        }
    }
    func applyFilter(){
        guard let originalSnapshot else{return}
        let id=current?.id,oldIndex=index
        let visible=groups.filter{!favoritesOnly || favoriteIDs.contains($0.id)}.map(\.lead)
        folder=FolderSnapshot(url:originalSnapshot.url,items:visible,folders:originalSnapshot.folders,ignoredCount:originalSnapshot.ignoredCount,elapsed:originalSnapshot.elapsed)
        index=id.flatMap{x in visible.firstIndex{$0.id==x}} ?? min(oldIndex,max(0,visible.count-1))
        if visible.isEmpty{cancelPreview()}else if isPreview{startPreview()}
    }
    func saveSettings(){
        defaults.set(automaticGrouping,forKey:"automaticGrouping");defaults.set(organizeCopy,forKey:"organizeCopy")
        settingsOpen=false
        if !isHome,let url=folder?.url{open(url)}
    }
    private func startPreview(){
        cancelPreview();error=nil
        guard let item=current else{return}
        if item.isVideo{loading=false;error="视频已作为独立媒体纳入收藏和整理。本轮尚未提供视频播放。";return}
        let token=generation,full=wantsFull,access=lease
        loading=true;log.add("request",["file":item.name,"generation":token,"full":full])
        request=Task {
            _=access // Keep the directory access scope alive until the request has finished.
            defer {if generation==token{loading=false}}
            do {
                if full {
                    let output=try await decoder.decode(item,tier:.full)
                    apply(output,item:item,token:token)
                } else {
                    if item.isRAW {
                        do{let quick=try await decoder.decode(item,tier:.quick);apply(quick,item:item,token:token)}catch is CancellationError{throw CancellationError()}catch{log.add("quick_unavailable",["file":item.name])}
                        try await Task.sleep(nanoseconds:240_000_000)
                        try Task.checkCancellation()
                    }
                    let output=try await decoder.decode(item,tier:.retina)
                    apply(output,item:item,token:token)
                }
            } catch is CancellationError {log.add("cancelled",["file":item.name,"generation":token])}
            catch {
                guard generation==token,current?.id==item.id else{return}
                self.error=full ? "完整像素读取失败，未进入 100%。按 F 返回适应窗口。\n\(friendly(error))":friendly(error)
                log.add("preview_error",["file":item.name,"generation":token,"full":full])
            }
        }
    }
    private func apply(_ output:PreviewFrame,item:MediaItem,token:Int){
        guard token==generation,current?.id==item.id,isPreview else{log.add("stale_discard",["file":item.name,"generation":token]);return}
        guard output.identity==item.cacheIdentity else{log.add("identity_mismatch");return}
        frame=output
        log.add("display",["file":item.name,"tier":output.tier.rawValue,"source":output.source,"width":output.width,"height":output.height,"seconds":output.seconds,"cache_hit":output.cacheHit,"generation":token,"current_file":current?.name ?? ""])
    }
    private func friendly(_ error:Error)->String {
        if let e=error as? MediaError{return e.localizedDescription}
        return "无法读取这张图片。文件可能损坏、已离线或不受当前解码器支持；你可以继续翻页。"
    }
}
