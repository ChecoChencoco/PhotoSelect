import Foundation
import AppKit
import PhotoSelectCore

@MainActor final class GUIValidation {
    let model:AppModel
    var checks:[[String:Any]]=[]
    init(model:AppModel){self.model=model}
    func check(_ name:String,_ passed:Bool){checks.append(["check":name,"pass":passed]);model.log.add("check",["name":name,"pass":passed])}
    func wait(_ predicate:()->Bool,seconds:Double=20) async -> Bool{
        let start=ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime-start<seconds {
            if predicate(){return true};try? await Task.sleep(nanoseconds:30_000_000)
        };return false
    }
    func run() async {
        guard let samples=argument("--samples"),let output=argument("--validation-output") else{return}
        model.log.add("gui_suite_start")
        var heartbeats:[Double]=[],previous=ProcessInfo.processInfo.systemUptime
        let timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){_ in let now=ProcessInfo.processInfo.systemUptime;heartbeats.append(now-previous);previous=now}
        model.open(URL(fileURLWithPath:samples))
        let opened=await wait{!self.model.isScanning && self.model.folder != nil}
        check("raw_folder_10",opened && model.folder?.items.count==10)
        if opened {
            for i in 0..<(model.folder?.items.count ?? 0){
                model.enter(i)
                let shown=await wait{self.model.frame?.tier == .retina && self.model.frame?.identity == self.model.current?.cacheIdentity}
                check("gui_raw_\(model.current?.name ?? "unknown")",shown)
                try? await Task.sleep(nanoseconds:100_000_000) // Allow a real window presentation cycle.
            }
            model.select(0);model.navigate(-1);check("first_boundary",model.index==0)
            model.select(9);model.navigate(1);check("last_boundary",model.index==9)
            for i in [0,8,9]{
                model.select(i);model.full()
                let shown=await wait{self.model.frame?.tier == .full}
                check("full_raw_\(i)",shown && model.frame?.width == (i==8 ? 5168:7952))
                try? await Task.sleep(nanoseconds:120_000_000)
                model.fit();_ = await wait{self.model.frame?.tier == .retina}
            }
            for step in 0..<100 {
                model.select((step*7+3)%10)
                try? await Task.sleep(nanoseconds:55_000_000)
                if step%10==9 {_ = await wait{self.model.frame?.tier == .retina};model.log.add("rss_switch",["step":step+1])}
                if let frame=model.frame{check("identity_switch_\(step)",frame.identity==model.current?.cacheIdentity)}
            }
            _ = await wait{self.model.frame?.tier == .retina}
            for i in 0..<10{model.home();model.enter();_ = await wait{self.model.frame?.tier == .retina};model.log.add("reopen",["iteration":i+1])}
            model.home();try? await Task.sleep(nanoseconds:500_000_000);model.log.add("rss_after_home")
            let metrics=await model.decoder.metrics();model.log.add("decoder_metrics",metrics)
            check("bounded_cache",(metrics["cache_bytes"] ?? Int.max)<=128*1024*1024)
            check("single_render",metrics["max_concurrent_render"]==1)
        }
        if let fixtures=argument("--fixtures"){
            model.open(URL(fileURLWithPath:fixtures));let ready=await wait{!self.model.isScanning && self.model.folder != nil}
            check("200_plus_folder",ready && (model.folder?.items.count ?? 0)>=200)
            check("subfolders_visible",model.folder?.folders.contains{$0.lastPathComponent=="选片"} == true && model.folder?.folders.contains{$0.lastPathComponent=="追加选片"} == true)
            if ready {
                for name in ["Format.jpg","Format.png","Format.heic","Format.tiff","Orientation6.ARW"] {
                    if let i=model.folder?.items.firstIndex(where:{$0.name==name}){
                        model.enter(i);let shown=await wait{self.model.frame?.tier == .retina}
                        check("format_\(name)",shown)
                        if name=="Orientation6.ARW"{check("orientation6",model.frame?.width==2135 && model.frame?.height==3200)}
                    }else{check("format_\(name)",false)}
                }
                if let i=model.folder?.items.firstIndex(where:{$0.name=="Broken.ARW"}){
                    model.enter(i);let failed=await wait{!self.model.loading && self.model.error != nil};check("broken_media_error",failed)
                    if let good=model.folder?.items.firstIndex(where:{$0.name=="CHC0.jpg"}) {
                        model.select(good)
                        let recovered=await wait{self.model.frame?.tier == .retina && self.model.current?.name == "CHC0.jpg"}
                        check("can_navigate_after_error",recovered && model.error==nil)
                    }
                }
                let child=URL(fileURLWithPath:fixtures).appendingPathComponent("选片")
                model.open(child);let childOK=await wait{!self.model.isScanning && self.model.folder?.url==child};check("enter_selection_folder",childOK)
            }
            model.open(URL(fileURLWithPath:fixtures).appendingPathComponent("missing-folder"));let missing=await wait{!self.model.isScanning && self.model.error != nil};check("missing_folder_error",missing)
        }
        // Exercise the actual NSItemProvider drop callback; Finder drag is checked separately by UI.
        if let provider=NSItemProvider(contentsOf:URL(fileURLWithPath:samples)) {
            let accepted=model.drop([provider])
            let dropped=await wait{!self.model.isScanning && self.model.folder?.url.path==samples}
            check("file_url_drop_provider",accepted && dropped)
        }
        timer.invalidate()
        let displays=model.log.rows.filter{$0["event"] as? String == "display"}
        check("no_stale_display",displays.allSatisfy{$0["file"] as? String == $0["current_file"] as? String})
        let report:[String:Any]=["checks":checks,"failed":checks.filter{($0["pass"] as? Bool) != true}.count,"main_heartbeat_max_seconds":heartbeats.max() ?? 0,"main_heartbeat_samples":heartbeats.count,"display_events":displays.count,"rss_mib":ProcessMemory.rssMiB]
        let url=URL(fileURLWithPath:output).appendingPathComponent("gui-validation.json")
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:url)}
        model.log.add("gui_suite_complete",["failed":checks.filter{($0["pass"] as? Bool) != true}.count])
        model.open(URL(fileURLWithPath:samples));_ = await wait{!self.model.isScanning && self.model.folder != nil};model.enter(0)
    }
}
