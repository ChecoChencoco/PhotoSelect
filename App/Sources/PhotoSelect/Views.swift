import SwiftUI
import AppKit
import PhotoSelectCore

struct Thumbnail:View {
    let item:MediaItem
    let decoder:MediaDecoder
    @State private var image:CGImage?
    @State private var failed=false
    var body:some View{
        ZStack{
            RoundedRectangle(cornerRadius:7).fill(.quaternary)
            if let image{Image(decorative:image,scale:1).resizable().aspectRatio(contentMode:.fit).padding(2)}
            else{Image(systemName:failed ? "exclamationmark.triangle":"photo").foregroundStyle(.secondary)}
        }
        .task(id:item.cacheIdentity){
            image=nil;failed=false
            do{let result=try await decoder.decode(item,tier:.thumbnail);guard !Task.isCancelled else{return};image=result.image}
            catch{if !Task.isCancelled{failed=true}}
        }
        .onDisappear{image=nil}
    }
}
struct RootView:View {
    @ObservedObject var model:AppModel
    @State private var started=false
    var body:some View{
        VStack(spacing:0){
            HStack{
                if model.isPreview{Button{model.home()}label:{Label("返回文件夹",systemImage:"chevron.left")}.disabled(model.operationBusy)}
                else if !model.isHome{Button("添加文件夹"){model.chooseFolder()}.disabled(model.operationBusy)}
                Spacer()
                Button{model.goHome()}label:{Image(systemName:"house").frame(width:26,height:24)}.accessibilityLabel("返回主页").help("返回主页").disabled(model.operationBusy || model.savingSelection)
                Button{model.settingsOpen=true}label:{Image(systemName:"gearshape").frame(width:26,height:24)}.accessibilityLabel("设置").help("设置").disabled(model.operationBusy)
            }.buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,8)
            Divider()
            Group{if model.isHome{LandingView(model:model)}else if model.isPreview{PreviewView(model:model)}else{BrowserView(model:model)}}
        }
        .frame(minWidth:900,minHeight:650)
        .overlay(alignment:.bottom){if model.operationBusy{Label("正在执行文件操作，请稍候…",systemImage:"hourglass").padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding()}}
        .background(KeyboardCapture(model:model).frame(width:0,height:0))
        .onDrop(of:["public.file-url"],isTargeted:$model.dragged,perform:model.drop)
        .overlay{if model.dragged{RoundedRectangle(cornerRadius:12).stroke(Color.accentColor,lineWidth:4).padding(6).allowsHitTesting(false)}}
        .sheet(item:$model.deleteGroup){group in DeleteSheet(model:model,group:group)}
        .sheet(isPresented:$model.showOrganize,onDismiss:{model.cancelOrganize()}){OrganizeSheet(model:model)}
        .sheet(isPresented:$model.settingsOpen){SettingsView(model:model)}
        .alert("提示",isPresented:Binding(get:{model.notice != nil},set:{if !$0{model.notice=nil}})){Button("好"){model.notice=nil}}message:{Text(model.notice ?? "")}
        .task{
            guard !started else{return};started=true
            if hasArgument("--self-test"){await GUIValidation(model:model).run()}
            else if let path=argument("--folder"){model.open(URL(fileURLWithPath:path))}
        }
    }
}
struct LandingView:View {
    @ObservedObject var model:AppModel
    var body:some View{
        VStack(spacing:20){Text("选择一个文件夹以开始").font(.title2);Button("添加文件夹"){model.chooseFolder()}.buttonStyle(.borderedProminent).controlSize(.large)}.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct BrowserView:View {
    @ObservedObject var model:AppModel
    var body:some View{
        HSplitView{
            VStack(alignment:.leading,spacing:8){
                HStack{Text("文件夹").font(.headline);Spacer();Button{model.tree.refresh()}label:{Image(systemName:"arrow.clockwise")}.help("刷新目录树")}.padding(.horizontal,12).padding(.top,12)
                DirectoryTreeView(store:model.tree,onSelect:model.open).frame(maxWidth:.infinity,maxHeight:.infinity)
                if let message=model.tree.message{Text(message).font(.caption).foregroundStyle(.orange).padding(8)}
                Divider()
                Text("最近打开").font(.caption).foregroundStyle(.secondary).padding(.horizontal,12)
                ForEach(model.recent.prefix(5)){r in
                    Button{model.openRecent(r)}label:{Label(r.name,systemImage:"clock").lineLimit(1)}.buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,3).help(r.path)
                }
            }.padding(.bottom,12).frame(minWidth:210,idealWidth:260,maxWidth:360).frame(maxHeight:.infinity)
            VStack(spacing:0){
                if let error=model.error{Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).padding().frame(maxWidth:.infinity,alignment:.leading).background(.orange.opacity(0.07))}
                if model.isScanning{Spacer();ProgressView("正在读取文件夹…");Spacer()}
                else if let folder=model.folder{
                    VStack(alignment:.leading,spacing:12){
                        HStack{
                            VStack(alignment:.leading,spacing:4){Text(folder.url.lastPathComponent).font(.title2.weight(.semibold)).lineLimit(1);Text(folder.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)}
                            Spacer(minLength:8)
                            Button{model.open(folder.url)}label:{Image(systemName:"arrow.clockwise")}.help("刷新文件夹").disabled(model.operationBusy)
                        }
                        HStack(spacing:12){
                            Button("完成选片"){model.prepareOrganize()}.buttonStyle(.borderedProminent).fixedSize().disabled(model.organizeDisabledReason != nil).help(model.organizeDisabledReason ?? "完成当前目录的选片")
                            Spacer(minLength:8)
                            Button("开始浏览"){model.enter()}.disabled(folder.items.isEmpty || model.operationBusy)
                            Menu("更多"){Button("撤销最近一次整理"){model.undoOrganize()}}.fixedSize().disabled(model.operationBusy)
                        }
                        if let reason=model.organizeDisabledReason{Text(reason).font(.caption).foregroundStyle(.secondary)}
                    }.padding(20)
                    HStack{Text("已收藏 \(model.favoriteCount) / 媒体组 \(model.groups.count) · 已浏览 \(min(model.viewedCount,model.groups.count)) · \(model.offlineCount) 个脱机收藏文件");Spacer();Text("按文件名排序")}.font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.bottom,12)
                    Divider()
                    ScrollView{
                        VStack(alignment:.leading,spacing:20){
                            if !folder.folders.isEmpty{
                                Text("子文件夹").font(.headline)
                                LazyVGrid(columns:[GridItem(.adaptive(minimum:175))],alignment:.leading,spacing:10){ForEach(folder.folders,id:\.path){url in
                                    Button{model.open(url)}label:{Label(url.lastPathComponent,systemImage:"folder.fill").frame(maxWidth:.infinity,alignment:.leading).padding(10)}.buttonStyle(.bordered)
                                }}
                            }
                            if folder.items.isEmpty{ContentUnavailableView("这个文件夹没有图片",systemImage:"photo",description:Text("可进入子文件夹，或打开另一个照片文件夹。"))}
                            else{
                                LazyVGrid(columns:[GridItem(.adaptive(minimum:160,maximum:240))],spacing:18){ForEach(Array(folder.items.enumerated()),id:\.element.id){i,item in
                                    Button{model.enter(i)}label:{VStack(alignment:.leading,spacing:7){Thumbnail(item:item,decoder:model.decoder).frame(height:115);HStack{Text(item.name).lineLimit(1);Spacer();Text(item.isRAW ? "RAW":item.url.pathExtension.uppercased()).font(.caption2).foregroundStyle(.secondary)}}}.buttonStyle(.plain)
                                }}
                            }
                        }.padding(24)
                    }
                }else{
                    Spacer()
                    Image(systemName:"photo.stack").font(.system(size:56,weight:.ultraLight)).foregroundStyle(.secondary)
                    Text("从一个文件夹开始").font(.title2.weight(.medium)).padding(.top,20)
                    Text("打开或拖入照片文件夹，用左右方向键轻松浏览。\n支持 Sony RAW、JPEG、PNG、HEIC 和 TIFF。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5).padding(.top,8)
                    Button("打开文件夹"){model.chooseFolder()}.buttonStyle(.borderedProminent).controlSize(.large).padding(.top,22)
                    Spacer()
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct PreviewView:View {
    @ObservedObject var model:AppModel
    var body:some View{
        VStack(spacing:0){
            HStack(spacing:16){
                VStack(alignment:.leading,spacing:4){Text(model.current?.name ?? "").font(.headline).lineLimit(1);Text(model.counter).font(.caption.monospacedDigit()).foregroundStyle(.secondary)}
                Spacer()
                if model.loading{ProgressView().controlSize(.small);Text(model.wantsFull ? "正在读取完整像素…":"正在加载…").font(.caption).foregroundStyle(.secondary)}
                Button("适应窗口  F"){model.fit()}.buttonStyle(.bordered).tint(!model.wantsFull ? .accentColor:nil)
                Button("100%  Z"){model.full()}.buttonStyle(.bordered).tint(model.wantsFull ? .accentColor:nil)
            }.padding(.horizontal,22).padding(.vertical,14)
            if let warning=model.currentGroup?.warning{Text(warning).font(.caption).foregroundStyle(.orange).padding(6)}
            Divider()
            ZStack{
                Color(nsColor:.windowBackgroundColor)
                if let frame=model.frame{
                    PhotoCanvas(frame:frame).id(model.current?.id)
                }else if model.loading{ProgressView(model.wantsFull ? "解码完整 RAW 像素":"正在打开图片")}
                else if model.favoritesOnly && model.current==nil{Text("还没有收藏，取消筛选后继续浏览。").foregroundStyle(.secondary)}
                else{Image(systemName:"photo.badge.exclamationmark").font(.system(size:42)).foregroundStyle(.secondary)}
                if let error=model.error{
                    VStack{Spacer();Label(error,systemImage:"exclamationmark.triangle").font(.callout).padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding(20)}
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack{
                if let frame=model.frame{Text("\(frame.source) · \(frame.width) × \(frame.height)").accessibilityIdentifier("sourceLabel")}
                else{Text(model.error != nil ? "预览不可用" : (model.wantsFull ? "等待完整像素，尚未进入 100%":"正在准备预览"))}
                Spacer()
                Text(model.frame?.tier == .full ? "1 图像像素 = 1 屏幕像素 · 拖动平移":"← → 翻页 · F 适应窗口 · Z 100%")
                Button{model.navigate(-1)}label:{Image(systemName:"chevron.left")}.disabled(model.index==0).help("上一张")
                Button{model.navigate(1)}label:{Image(systemName:"chevron.right")}.disabled(model.index >= (model.folder?.items.count ?? 0)-1).help("下一张")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,9)
            HStack(spacing:16){
                Button{model.toggleFavorite()}label:{Label("选片",systemImage:model.currentFavorite ? "heart.fill":"heart")}.buttonStyle(.bordered).tint(model.currentFavorite ? .pink:nil).disabled(model.current==nil || model.savingSelection || model.operationBusy).help("选片 / 取消选片 · M").accessibilityValue(model.currentFavorite ? "已选中":"未选中")
                Button{model.requestDelete()}label:{Label("删除",systemImage:"trash")}.buttonStyle(.bordered).disabled(model.deleteDisabledReason != nil).help(model.deleteDisabledReason ?? "确认后移入废纸篓 · Delete / ⌘Delete")
                if let reason=model.deleteDisabledReason{Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
                Spacer(minLength:8)
                Toggle("仅显示收藏",isOn:$model.favoritesOnly).toggleStyle(.checkbox).onChange(of:model.favoritesOnly){_,_ in model.applyFilter()}
            }.padding(.horizontal,20).padding(.vertical,10)
            Divider()
            ScrollViewReader{proxy in
                ScrollView(.horizontal){
                    LazyHStack(spacing:9){ForEach(Array((model.folder?.items ?? []).enumerated()),id:\.element.id){i,item in
                        Button{model.select(i)}label:{VStack(spacing:4){Thumbnail(item:item,decoder:model.decoder).frame(width:98,height:65);Text((model.groups.first(where:{$0.lead.id==item.id}).map{model.favoriteIDs.contains($0.id)} == true ? "♥ ":"")+item.name).font(.system(size:10)).lineLimit(1).frame(width:100)}}
                            .buttonStyle(.plain).padding(5).background(i==model.index ? Color.accentColor.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:9))
                            .overlay(RoundedRectangle(cornerRadius:9).stroke(i==model.index ? Color.accentColor:.clear,lineWidth:2)).id(item.id)
                    }}.padding(.horizontal,14).padding(.vertical,10)
                }.frame(height:112)
                .onChange(of:model.index){_,_ in if let id=model.current?.id{proxy.scrollTo(id,anchor:.center)}}
                .onAppear{if let id=model.current?.id{proxy.scrollTo(id,anchor:.center)}}
            }
        }
    }
}

struct SettingsView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            Text("PhotoSelect 设置").font(.title2)
            Toggle("同目录 RAW + JPEG 自动分组",isOn:$model.automaticGrouping)
            Toggle("完成选片时复制（关闭则移动）",isOn:$model.organizeCopy)
            Text("收藏后停留当前项 · 胶片栏常显 · 自然排序 · 仅当前目录\n分组关系不明确时会暂停删除和整理；收藏保存在本机数据库。").font(.caption).foregroundStyle(.secondary)
            HStack{Spacer();Button("保存"){model.saveSettings()}.buttonStyle(.borderedProminent)}
        }.padding(24).frame(width:480)
    }
}

struct DeleteSheet:View {
    @ObservedObject var model:AppModel
    let group:MediaGroup
    var body:some View{VStack(alignment:.leading,spacing:16){
        Text("移入 macOS 废纸篓？").font(.title2)
        Text("照片将移入废纸篓。已选片的照片不可删除。")
        Text(group.members.map(\.name).joined(separator:"\n")).font(.callout.monospaced())
        Text("当前文件：\(model.current?.name ?? "")。仅删当前文件不会带走 XMP。").font(.caption).foregroundStyle(.secondary)
        HStack{Button("取消"){model.deleteGroup=nil}.keyboardShortcut(.cancelAction);Spacer();Button("删除当前文件",role:.destructive){model.confirmDelete(wholeGroup:false)};if group.members.count>1{Button("删除整组",role:.destructive){model.confirmDelete(wholeGroup:true)}}}
    }.padding(24).frame(width:570)}
}
struct OrganizeSheet:View {
    @ObservedObject var model:AppModel
    var body:some View{VStack(alignment:.leading,spacing:16){
        Text("是否完成选片？").font(.title2)
        if let plan=model.organizePlan{
            Text("\(plan.batch.groups.count) 个媒体组 · \(plan.batch.filesCount) 个文件 · \(ByteCountFormatter.string(fromByteCount:Int64(plan.batch.bytes),countStyle:.file))")
            Text("将在“\(URL(fileURLWithPath:plan.batch.collectionRoot ?? plan.batch.source).lastPathComponent)”内新建本次选片文件夹。名称以确认时的时间为准。").foregroundStyle(.secondary)
            Text("模式：\(plan.batch.mode=="copy" ? "复制（保留来源文件）":"移动（成功后来源文件离开当前目录）")").font(.headline)
            if !plan.warnings.isEmpty{Text("部分分组存在冲突，将保留在原处。").foregroundStyle(.orange)}
            HStack{Button("否"){model.cancelOrganize()}.keyboardShortcut(.cancelAction);Spacer();Button("是"){model.confirmOrganize()}.buttonStyle(.borderedProminent)}
        }
    }.padding(24).frame(width:640)}
}
