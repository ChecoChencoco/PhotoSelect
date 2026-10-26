import SwiftUI
import AppKit
#if !arch(arm64)
#error("PhotoSelect requires Apple Silicon arm64")
#endif
final class AppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification){NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
@main struct PhotoSelectApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model=AppModel()
    var body:some Scene {
        Window("PhotoSelect",id:"main") {RootView(model:model)}
            .defaultSize(width:1160,height:800)
            .commands{
                CommandGroup(replacing:.newItem){Button("打开文件夹…"){model.chooseFolder()}.keyboardShortcut("o",modifiers:.command)}
            }
    }
}
