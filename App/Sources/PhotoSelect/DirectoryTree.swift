import SwiftUI
import AppKit
import PhotoSelectCore

final class DirectoryNode:NSObject {
    let url:URL
    var children:[DirectoryNode]=[]
    var loaded=false, loading=false
    var failure:String?
    init(_ url:URL){self.url=url.standardizedFileURL}
}
@MainActor final class DirectoryTreeStore:ObservableObject {
    @Published var revision=0
    @Published var message:String?
    let roots=[DirectoryNode(URL(fileURLWithPath:"/Volumes")),DirectoryNode(URL(fileURLWithPath:"/Users"))]
    var expanded:Set<String>=[]
    var selected:String?
    let defaults:UserDefaults
    private var observers:[NSObjectProtocol]=[]
    init(defaults:UserDefaults){
        self.defaults=defaults
        expanded=Set((defaults.stringArray(forKey:"tree.expanded") ?? []).prefix(64))
        for name in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.refresh()}})
        }
        Task{for root in roots where expanded.contains(root.url.path){await load(root);await restore(root)}}
    }
    func restore(_ node:DirectoryNode) async {
        for child in node.children where expanded.contains(child.url.path){await load(child);await restore(child)}
    }
    func save(){defaults.set(Array(expanded.sorted().prefix(64)),forKey:"tree.expanded")}
    func load(_ node:DirectoryNode) async {
        while node.loading{try? await Task.sleep(nanoseconds:10_000_000)}
        guard !node.loaded else{return}
        node.loading=true;revision+=1
        let url=node.url
        do {
            let urls=try await Task.detached(priority:.userInitiated){try DirectoryListing.children(url)}.value
            node.children=urls.map(DirectoryNode.init);node.loaded=true;node.failure=nil
        }catch{node.children=[];node.failure="无法读取 \(url.lastPathComponent)：权限不足或目录已离线。请用打开文件夹重新选择。";message=node.failure;node.loaded=true}
        node.loading=false;revision+=1
    }
    func refresh(){
        Task{
            func invalidate(_ node:DirectoryNode){node.loaded=false;for child in node.children{invalidate(child)}}
            for root in roots{invalidate(root);if expanded.contains(root.url.path){await load(root);await restore(root)}}
            revision+=1
        }
    }
    func reveal(_ url:URL) {
        let path=url.standardizedFileURL.path;selected=path
        Task{
            guard var node=roots.first(where:{path==$0.url.path || path.hasPrefix($0.url.path+"/")}) else{revision+=1;return}
            while node.url.path != path {
                expanded.insert(node.url.path);await load(node)
                guard let next=node.children.first(where:{path==$0.url.path || path.hasPrefix($0.url.path+"/")}) else{break}
                node=next
            }
            save();revision+=1
        }
    }
}
struct DirectoryTreeView:NSViewRepresentable {
    @ObservedObject var store:DirectoryTreeStore
    var onSelect:(URL)->Void
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        let outline=NSOutlineView();let col=NSTableColumn(identifier:.init("directory"));col.title="目录";outline.addTableColumn(col);outline.outlineTableColumn=col
        outline.headerView=nil;outline.rowHeight=27;outline.indentationPerLevel=17;outline.style = .sourceList
        outline.dataSource=context.coordinator;outline.delegate=context.coordinator;outline.allowsEmptySelection=true
        scroll.documentView=outline;context.coordinator.outline=outline
        return scroll
    }
    func updateNSView(_ nsView:NSScrollView,context:Context){context.coordinator.parent=self;context.coordinator.sync()}
    @MainActor final class Coordinator:NSObject,NSOutlineViewDataSource,NSOutlineViewDelegate {
        var parent:DirectoryTreeView
        weak var outline:NSOutlineView?
        var syncing=false
        var lastSelected:String?
        init(_ parent:DirectoryTreeView){self.parent=parent}
        func outlineView(_ v:NSOutlineView,numberOfChildrenOfItem item:Any?)->Int{(item as? DirectoryNode)?.children.count ?? parent.store.roots.count}
        func outlineView(_ v:NSOutlineView,child index:Int,ofItem item:Any?)->Any{(item as? DirectoryNode)?.children[index] ?? parent.store.roots[index]}
        func outlineView(_ v:NSOutlineView,isItemExpandable item:Any)->Bool{guard let n=item as? DirectoryNode else{return false};return !n.loaded || !n.children.isEmpty}
        func outlineView(_ v:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any)->NSView? {
            guard let n=item as? DirectoryNode else{return nil}
            let cell=NSTableCellView();let icon=NSImageView();icon.image=NSImage(systemSymbolName:"folder.fill",accessibilityDescription:"文件夹");icon.contentTintColor = .secondaryLabelColor
            let text=NSTextField(labelWithString:n.url.lastPathComponent+(n.loading ? " …":""));text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(icon);cell.addSubview(text);icon.translatesAutoresizingMaskIntoConstraints=false;text.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:2),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:18),icon.heightAnchor.constraint(equalToConstant:18),text.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:6),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            cell.textField=text;cell.imageView=icon;cell.toolTip=n.failure ?? n.url.path
            return cell
        }
        func outlineViewItemWillExpand(_ notification:Notification){
            guard !syncing,let n=notification.userInfo?["NSObject"] as? DirectoryNode else{return}
            parent.store.expanded.insert(n.url.path);parent.store.save()
            Task{await parent.store.load(n)}
        }
        func outlineViewItemDidCollapse(_ notification:Notification){guard !syncing,let n=notification.userInfo?["NSObject"] as? DirectoryNode else{return};parent.store.expanded.remove(n.url.path);parent.store.save()}
        func outlineViewSelectionDidChange(_ notification:Notification){
            guard !syncing,let v=outline,let n=v.item(atRow:v.selectedRow) as? DirectoryNode else{return}
            parent.store.selected=n.url.path;parent.onSelect(n.url)
        }
        func sync(){
            guard let v=outline else{return};syncing=true;defer{syncing=false}
            let origin=v.enclosingScrollView?.contentView.bounds.origin
            v.reloadData()
            func expand(_ n:DirectoryNode){if parent.store.expanded.contains(n.url.path){v.expandItem(n);for c in n.children{expand(c)}}}
            for n in parent.store.roots{expand(n)}
            for i in 0..<v.numberOfRows{if let n=v.item(atRow:i) as? DirectoryNode,n.url.path==parent.store.selected{v.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false);break}}
            if lastSelected != parent.store.selected,let selectedNode=v.item(atRow:v.selectedRow) as? DirectoryNode,selectedNode.url.path==parent.store.selected {lastSelected=parent.store.selected;v.scrollRowToVisible(v.selectedRow)}
            else if let origin{v.enclosingScrollView?.contentView.scroll(to:NSPoint(x:origin.x,y:max(0,min(origin.y,v.bounds.height-(v.enclosingScrollView?.contentView.bounds.height ?? 0)))))}
        }
    }
}
