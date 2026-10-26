import Foundation
import PhotoSelectCore
import Darwin
setbuf(stdout,nil)

var passed=0,failed=0
func check(_ name:String,_ result:Bool){if result{passed+=1;print("PASS \(name)")}else{failed+=1;print("FAIL \(name)")}}
let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PhotoSelectChecks-\(UUID().uuidString)").resolvingSymlinksInPath()
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:root)}
for name in ["CHC10.jpg","CHC9.jpg","z.ARW","ignore.txt"]{try Data([0]).write(to:root.appendingPathComponent(name))}
for name in ["选片","追加选片"]{try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}
try Data([0]).write(to:root.appendingPathComponent("选片/hidden.jpg"))
try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("alias.jpg"),withDestinationURL:root.appendingPathComponent("CHC9.jpg"))
let snapshot=try MediaScanner.scan(root)
check("natural sort",snapshot.items.map(\.name)==["CHC9.jpg","CHC10.jpg","z.ARW"])
check("nonrecursive and no symlink traversal",snapshot.items.count==3)
check("selection folders are ordinary",Set(snapshot.folders.map(\.lastPathComponent))==Set(["选片","追加选片"]))
check("clamped boundaries",MediaScanner.index(0,delta:-1,count:10)==0 && MediaScanner.index(9,delta:1,count:10)==9)
check("empty list bounds",MediaScanner.index(0,delta:1,count:0)==0)
var cache=CostCache<String,Int>(limit:10)
cache.insert(1,key:"a",cost:4);cache.insert(2,key:"b",cost:4);_ = cache.value(for:"a");cache.insert(3,key:"c",cost:4)
check("LRU eviction",cache.value(for:"b")==nil && cache.value(for:"a")==1 && cache.totalCost==8)
cache.insert(4,key:"tooLarge",cost:11);check("oversized rejected",cache.totalCost==8 && cache.value(for:"tooLarge")==nil)
cache.insert(5,key:"a",cost:2);check("replacement accounting",cache.totalCost==6)
cache.clear();check("cache clear",cache.totalCost==0)
let first=try MediaItem(url:root.appendingPathComponent("CHC9.jpg"));try Data([0,1]).write(to:first.url);let second=try MediaItem(url:first.url)
check("replacement invalidates identity",first.cacheIdentity != second.cacheIdentity)
do{_ = try MediaScanner.scan(root.appendingPathComponent("missing"));check("missing folder rejected",false)}catch{check("missing folder rejected",true)}
do{_ = try MediaScanner.scan(first.url);check("file cannot be opened as folder",false)}catch{check("file cannot be opened as folder",true)}
let denied=root.appendingPathComponent("NoAccess")
try FileManager.default.createDirectory(at:denied,withIntermediateDirectories:true)
try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:denied.path)
do{_ = try MediaScanner.scan(denied);check("permission denied folder rejected",false)}catch{check("permission denied folder rejected",true)}
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:denied.path)
let unreadable=root.appendingPathComponent("Unreadable.ARW")
try Data([73,73,42,0,8,0,0,0]).write(to:unreadable)
let unreadableItem=try MediaItem(url:unreadable)
try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:unreadable.path)
do{_ = try await MediaDecoder().decode(unreadableItem,tier:.quick);check("unreadable image rejected",false)}catch{check("unreadable image rejected",true)}
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:unreadable.path)
let treeRoot=root.appendingPathComponent("Tree")
for i in 0..<120{try FileManager.default.createDirectory(at:treeRoot.appendingPathComponent("Folder\(i)/选片/追加选片"),withIntermediateDirectories:true)}
try FileManager.default.createSymbolicLink(at:treeRoot.appendingPathComponent("loop"),withDestinationURL:treeRoot)
let branches=try DirectoryListing.children(treeRoot)
check("tree lazy one level 120 and no symlink",branches.count==120 && branches[9].lastPathComponent=="Folder9")
check("tree ordinary selection nesting",try DirectoryListing.children(branches[0]).first?.lastPathComponent=="选片")
do{_ = try DirectoryListing.children(root.appendingPathComponent("missing"));check("tree missing error",false)}catch{check("tree missing error",true)}
let groupDir=root.appendingPathComponent("Groups")
try FileManager.default.createDirectory(at:groupDir,withIntermediateDirectories:true)
for name in ["A.ARW","A.JPG","A.XMP","A.MP4","B.JPG","B.JPEG","B.ARW"]{try Data(name.utf8).write(to:groupDir.appendingPathComponent(name))}
let resolved=try GroupResolver.resolve(MediaScanner.scan(groupDir))
let a=resolved.first{$0.lead.name=="A.ARW"}!
check("RAW JPEG XMP grouped and video separate",a.members.count==3 && resolved.contains{$0.lead.name=="A.MP4"} && resolved.count==5)
check("ambiguous JPEG candidates remain separate blocked",resolved.filter{$0.lead.name.hasPrefix("B.")}.allSatisfy{$0.warning != nil && $0.members.count==1})
let dbURL=root.appendingPathComponent("library.sqlite")
let db=try SelectionStore(url:dbURL)
try db.register(resolved,folder:groupDir)
_ = try db.toggle(a)
check("group favorite protects JPEG",try db.isProtected(a.members.first{$0.name=="A.JPG"}!.stableKey))
let reopened=try SelectionStore(url:dbURL)
check("SQLite restart persists favorite",try reopened.favorite(a))
try db.savePosition(folder:groupDir,item:a.lead)
check("SQLite position uses identity",try reopened.lastPosition(groupDir)==a.lead.stableKey)
try db.execute("PRAGMA query_only=ON")
do{_ = try db.toggle(a);check("SQLite failed write throws",false)}catch{check("SQLite failed write throws",true)}
check("failed write preserves favorite",try reopened.favorite(a))
try db.execute("PRAGMA query_only=OFF")
let newURL=groupDir.appendingPathComponent("Renamed.ARW")
try FileManager.default.moveItem(at:a.lead.url,to:newURL)
let renamed=try MediaItem(url:newURL)
check("external rename preserves stable identity",renamed.stableKey==a.lead.stableKey)
let nextGroups=try GroupResolver.resolve(MediaScanner.scan(groupDir));try db.register(nextGroups,folder:groupDir)
check("external rename favorite retained",try db.isProtected(renamed.stableKey))
try FileManager.default.moveItem(at:newURL,to:root.appendingPathComponent("offline.ARW"))
try db.register(GroupResolver.resolve(MediaScanner.scan(groupDir)),folder:groupDir)
check("offline favorite record preserved",try db.offlineFavorites(groupDir)>0)

try Data("isolated generated tests".utf8).write(to:root.appendingPathComponent(".photoselect-isolated-test"))
print("Isolated operations root: \(root.path)")
let opsDB=try SelectionStore(url:root.appendingPathComponent("ops.sqlite"))
let service=ProtectedFileOperationService(store:opsDB,testRoot:root)
func scenario(_ name:String)throws->(URL,[MediaGroup]){
    let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    for file in ["Photo.ARW","Photo.JPG","Photo.XMP"]{try Data((name+file).utf8).write(to:folder.appendingPathComponent(file))}
    let groups=try GroupResolver.resolve(MediaScanner.scan(folder));try opsDB.register(groups,folder:folder);_ = try opsDB.toggle(groups[0]);return (folder,groups)
}
let (source,opGroups)=try scenario("Move")
let protectedJPEG=opGroups[0].members.first{$0.name=="Photo.JPG"}!
do{_ = try service.trash(opGroups[0],current:protectedJPEG,wholeGroup:false);check("operation layer blocks favorite JPEG",false)}catch{check("operation layer blocks favorite JPEG",true)}
let initialPlan=try service.plan(source:source,groups:opGroups,copy:false,name:"选片")
check("plan is read only and first destination",!FileManager.default.fileExists(atPath:initialPlan.batch.destination) && initialPlan.batch.destination.hasSuffix("_选片"))
let result=try service.execute(initialPlan)
check("group move complete verified and favorite cleared",try result.groups[0].state=="committed" && result.groups[0].files.allSatisfy{!FileManager.default.fileExists(atPath:$0.source) && FileManager.default.fileExists(atPath:$0.destination)} && (try !opsDB.favorite(opGroups[0])))
check("group bytes match hashes",try result.groups[0].files.allSatisfy{try FileSafety.digest(URL(fileURLWithPath:$0.destination))==$0.hash})
let secondPath=try DestinationPolicy.destination(source:source,at:Date(timeIntervalSince1970:result.time))
check("second organize sibling numbered",secondPath.deletingLastPathComponent().path==source.path && secondPath.lastPathComponent.hasSuffix("（2）"))
try FileManager.default.createDirectory(at:secondPath,withIntermediateDirectories:false)
check("third organize sibling numbered",try DestinationPolicy.destination(source:source,at:Date(timeIntervalSince1970:result.time)).lastPathComponent.hasSuffix("（3）"))
check("destination records original root",result.collectionRoot==source.path && result.createdDestinationDirectory==true)
try Data("occupant".utf8).write(to:source.appendingPathComponent("Photo.JPG"))
do{_ = try service.undoLatest();check("undo refuses occupied original",false)}catch{check("undo refuses occupied original",true)}
try FileManager.default.moveItem(at:source.appendingPathComponent("Photo.JPG"),to:source.appendingPathComponent("occupant.txt"))
let undone=try service.undoLatest()
check("undo restores all files and favorite",try undone.state=="undone" && (try opsDB.favorite(opGroups[0])) && opGroups[0].members.allSatisfy{FileManager.default.fileExists(atPath:$0.url.path)})
let (failedSource,failedGroups)=try scenario("Failure")
service.injectFailureAfter=1
let failedResult=try service.execute(service.plan(source:failedSource,groups:failedGroups,copy:false,name:"选片"))
check("mid group failure rolls back and keeps favorite",try failedResult.groups[0].state=="failed" && failedGroups[0].members.allSatisfy{FileManager.default.fileExists(atPath:$0.url.path)} && (try opsDB.favorite(failedGroups[0])))
service.injectFailureAfter=nil
let (conflictSource,conflictGroups)=try scenario("Conflict")
service.injectConflictName="photo.jpg"
let conflict=try service.execute(service.plan(source:conflictSource,groups:conflictGroups,copy:false,name:"选片"))
check("case insensitive conflict keeps entire group",try conflict.groups[0].state=="failed" && conflictGroups[0].members.allSatisfy{FileManager.default.fileExists(atPath:$0.url.path)} && (try opsDB.favorite(conflictGroups[0])))
service.injectConflictName=nil
let (copySource,copyGroups)=try scenario("Copy")
let copied=try service.execute(service.plan(source:copySource,groups:copyGroups,copy:true,name:"选片"))
check("copy verifies bytes retains source clears favorite",try copied.groups[0].state=="committed" && copyGroups[0].members.allSatisfy{FileManager.default.fileExists(atPath:$0.url.path)} && (try !opsDB.favorite(copyGroups[0])) && (try copied.groups[0].files.allSatisfy{try FileSafety.digest(URL(fileURLWithPath:$0.destination))==$0.hash}))
// V0.2.2 targeted scenarios; all writes remain in the UUID test root.
let fm=FileManager.default
check("T04 first undo removes created empty directory",undone.directoryCleanup=="removed" && !fm.fileExists(atPath:result.destination))
check("T08 failure rollback cleans own empty destination",failedResult.directoryCleanup=="removed" && !fm.fileExists(atPath:failedResult.destination))
check("T08 conflict preserves nonempty destination",fm.fileExists(atPath:conflict.destination+"/photo.jpg") && conflict.directoryCleanup=="not_empty")
let copyUndo=try service.undoLatest()
check("T07 copy undo preserves original bytes and favorites removes empty output",try copyUndo.state=="undone" && copyUndo.directoryCleanup=="removed" && !fm.fileExists(atPath:copied.destination) && (try opsDB.favorite(copyGroups[0])) && (try copied.groups[0].files.allSatisfy{try FileSafety.digest(URL(fileURLWithPath:$0.source))==$0.hash}))
let (deltaSource,deltaGroups)=try scenario("Delta")
let fixed=Date(timeIntervalSince1970:1791804240)
let plan=try service.plan(source:deltaSource,groups:deltaGroups,copy:false,name:"ignored-old-preference")
let beforeCancel=try fm.contentsOfDirectory(atPath:deltaSource.path).sorted()
check("T11 unexecuted plan has no writes or favorite changes",try beforeCancel==fm.contentsOfDirectory(atPath:deltaSource.path).sorted() && (try opsDB.favorite(deltaGroups[0])) && !fm.fileExists(atPath:plan.batch.destination))
let existing=try DestinationPolicy.destination(source:deltaSource,at:fixed)
try fm.createDirectory(at:existing,withIntermediateDirectories:false)
try Data("third party".utf8).write(to:existing.appendingPathComponent("keep.txt"))
let firstDelta=try service.execute(plan,confirmedAt:fixed)
check("T01 T05 confirmation timestamp collision numbered sibling",firstDelta.destination==existing.path+"（2）" && firstDelta.time==fixed.timeIntervalSince1970 && !fm.fileExists(atPath:deltaSource.appendingPathComponent("选片").path))
check("T05 preexisting bytes untouched",try Data(contentsOf:existing.appendingPathComponent("keep.txt"))==Data("third party".utf8))
try Data("extra bytes".utf8).write(to:deltaSource.appendingPathComponent("Extra.JPG"))
let extraGroups=try GroupResolver.resolve(MediaScanner.scan(deltaSource));try opsDB.register(extraGroups,folder:deltaSource);try opsDB.setFavorite(extraGroups[0],true)
let secondDelta=try service.execute(service.plan(source:deltaSource,groups:extraGroups,copy:false,name:""),confirmedAt:fixed)
check("T02 same root new sibling first batch unchanged",try secondDelta.destination==existing.path+"（3）" && (try firstDelta.groups[0].files.allSatisfy{try FileSafety.digest(URL(fileURLWithPath:$0.destination))==$0.hash}))
let firstFolder=URL(fileURLWithPath:firstDelta.destination)
let reselected=try GroupResolver.resolve(MediaScanner.scan(firstFolder));try opsDB.register(reselected,folder:firstFolder);try opsDB.setFavorite(reselected[0],true)
// Reopen database/service: persisted provenance, not in-memory state.
let restarted=ProtectedFileOperationService(store:try SelectionStore(url:root.appendingPathComponent("ops.sqlite")),testRoot:root)
let thirdDelta=try restarted.execute(restarted.plan(source:firstFolder,groups:reselected,copy:false,name:""),confirmedAt:fixed)
check("T03 persisted root yields sibling and exact direct sources",thirdDelta.collectionRoot==deltaSource.path && thirdDelta.destination==existing.path+"（4）" && thirdDelta.groups[0].files.allSatisfy{FileSafety.canonical(URL(fileURLWithPath:$0.source).deletingLastPathComponent()).path==FileSafety.canonical(firstFolder).path})
let thirdUndo=try restarted.undoLatest()
check("T04 T09 reselect undo exact paths hashes favorites and directory cleanup",try !fm.fileExists(atPath:thirdDelta.destination) && fm.fileExists(atPath:firstDelta.destination) && fm.fileExists(atPath:secondDelta.destination) && (try opsDB.favorite(reselected[0])) && (try thirdUndo.groups[0].files.allSatisfy{try FileSafety.digest(URL(fileURLWithPath:$0.source))==$0.hash}))
try Data("keep new content".utf8).write(to:URL(fileURLWithPath:secondDelta.destination).appendingPathComponent("user.txt"))
let secondUndo=try restarted.undoLatest()
check("T06 undo restores file keeps third-party contents and older output",try secondUndo.state=="undone" && secondUndo.directoryCleanup=="not_empty" && Data(contentsOf:URL(fileURLWithPath:secondDelta.destination).appendingPathComponent("user.txt"))==Data("keep new content".utf8) && (try opsDB.favorite(extraGroups[0])) && fm.fileExists(atPath:firstDelta.destination))
let (legacySource,legacyGroups)=try scenario("Legacy")
let legacyDirectory=legacySource.appendingPathComponent("选片");try fm.createDirectory(at:legacyDirectory,withIntermediateDirectories:false)
try Data("legacy untouched".utf8).write(to:legacyDirectory.appendingPathComponent("old.JPG"))
let legacyItems=try GroupResolver.resolve(MediaScanner.scan(legacyDirectory));try opsDB.register(legacyItems,folder:legacyDirectory);try opsDB.setFavorite(legacyItems[0],true)
do{_ = try service.plan(source:legacyDirectory,groups:legacyItems,copy:false,name:"");check("T10 unknown legacy root blocked",false)}catch{check("T10 unknown legacy root blocked",true)}
check("T10 legacy bytes unchanged",try Data(contentsOf:legacyDirectory.appendingPathComponent("old.JPG"))==Data("legacy untouched".utf8))
// Legacy payloads decode with absent provenance; preexisting directories are never cleaned.
let legacyJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(firstDelta)) as! [String:Any]
var oldJSON=legacyJSON
for key in ["collectionRoot","collectionRootID","sourceDirectoryID","createdDestinationDirectory","destinationDirectoryID","directoryCleanup"]{oldJSON.removeValue(forKey:key)}
let oldBatch=try JSONDecoder().decode(OperationBatch.self,from:JSONSerialization.data(withJSONObject:oldJSON))
check("T10 old journal remains decodable without directory ownership",oldBatch.createdDestinationDirectory==nil && oldBatch.collectionRoot==nil)
let (zeroSource,zeroGroups)=try scenario("Zero")
try opsDB.setFavorite(zeroGroups[0],false)
do{_ = try service.plan(source:zeroSource,groups:zeroGroups,copy:false,name:"");check("T11 zero favorites refused without directory",false)}catch{check("T11 zero favorites refused without directory",try fm.contentsOfDirectory(atPath:zeroSource.path).count==3)}
// Changed target content must block undo without changing either copy.
let (changedSource,changedGroups)=try scenario("Changed")
let changed=try service.execute(service.plan(source:changedSource,groups:changedGroups,copy:false,name:""))
try Data("externally changed".utf8).write(to:URL(fileURLWithPath:changed.groups[0].files[0].destination))
do{_ = try service.undoLatest();check("T08 modified target refuses undo",false)}catch{check("T08 modified target refuses undo",fm.fileExists(atPath:changed.destination) && !fm.fileExists(atPath:changed.groups[0].files[0].source))}
print("Delta evidence: first=\(URL(fileURLWithPath:firstDelta.destination).lastPathComponent), second=\(URL(fileURLWithPath:secondDelta.destination).lastPathComponent), reselect=\(URL(fileURLWithPath:thirdDelta.destination).lastPathComponent); reselectUndo=\(thirdUndo.directoryCleanup ?? ""), extraFileUndo=\(secondUndo.directoryCleanup ?? "")")
let crash=OperationBatch(source:copySource.path,destination:"unfinished",mode:"move",groups:[],bytes:0)
try opsDB.recordOperation(id:crash.id,state:"in_progress",payload:JSONEncoder().encode(crash))
let crashRestart=try SelectionStore(url:root.appendingPathComponent("ops.sqlite"))
check("unfinished journal survives restart",try crashRestart.unfinished().count==1)
do{_ = try service.plan(source:source,groups:opGroups,copy:false,name:"选片");check("unfinished journal blocks more writes",false)}catch{check("unfinished journal blocks more writes",true)}
try opsDB.recordOperation(id:crash.id,state:"failed",payload:JSONEncoder().encode(crash))
do{_ = try service.plan(source:root.deletingLastPathComponent(),groups:[],copy:false,name:"选片");check("test isolation rejects outside root",false)}catch{check("test isolation rejects outside root",true)}
let symlink=root.appendingPathComponent("escape");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:source)
do{_ = try DestinationPolicy.destination(source:symlink);check("symlink operation path refused",false)}catch{check("symlink operation path refused",true)}
print("Result: \(passed) passed, \(failed) failed")
exit(failed==0 ? 0:1)
